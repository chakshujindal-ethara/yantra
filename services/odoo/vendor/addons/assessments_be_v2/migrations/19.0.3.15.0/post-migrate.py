# -*- coding: utf-8 -*-
"""assessments_be_v2 19.0.3.15.0 post-migration: cron priority, spacing, stagger.

WHY THIS EXISTS AT ALL. `data/cron.xml` is wrapped in `<data noupdate="1">`, so
Odoo writes those records ONCE, at install, and never touches them again. Editing
the XML therefore changes fresh installs and does NOTHING to the database anyone
is actually running - the file and the live rows silently drift apart. This
script is what makes the change real, and it must stay in step with the XML.

POST-migrate, not pre: it rewrites rows that the (unchanged) `ir_cron` schema
already holds, so nothing here depends on the new registry, and running after
the module data has loaded means a fresh install has already got these values
from the XML and this script is a no-op on them.

WHAT IT FIXES

1. PRIORITY. Odoo picks ready jobs with `ORDER BY failure_count, priority, id`
   (base/models/ir_cron.py, `_get_all_ready_jobs`). All 13 of our records carried
   the default priority 5, so the tie broke on `id` - and ids follow declaration
   order, which put the four Vertex-bound scoring shards AHEAD of
   `ir_cron_expire_stale_attempts`, the job that settles a candidate's paper.

   Measured on the local rig: one `Auto-score submitted candidates` tick ran
   33.6 s, against a median of 0.010 s across 8,168 ticks. With
   `max_cron_threads = 1` - the deployed value, on a thread shared with ~49
   crons from greythr, essl_server, kensei2, iris, lynceus and others - a
   candidate past their deadline waited behind that. That is a fairness defect,
   not a latency one.

2. SPACING. The four authoring jobs (image render, label detect, SOP generation,
   tag extraction) each make a Vertex or imaging call and are the ticks that can
   hold the single thread for tens of seconds. Nothing candidate-facing depends
   on their latency, so they move to 5 minutes and hold the thread 5x less often.

3. STAGGER. 11 of the 13 shared an IDENTICAL `nextcall`, so every minute eleven
   jobs woke in the same second, each taking an advisory lock, most finding
   nothing to do. Spreading them across the interval removes that herd. This is
   the smallest of the three effects - an idle tick is ~10 ms - but it is free.

WHAT IT DELIBERATELY DOES NOT DO

* It does not enable or disable anything. `active` is untouched, because an
  operator who turned a job off did so for a reason and a migration silently
  re-enabling it is exactly the kind of surprise `noupdate="1"` exists to
  prevent. (The corollary, worth knowing: an upgrade will NOT re-enable a cron
  left `active = false`. Check that separately - `runbook/preflight.sql` query 7.)
* It does not delete or merge any cron. The count looks alarming and is not the
  cost: 2 of 8,168 ticks exceeded 1 second, and those two were 34% of all cron
  time. Removing ten idle jobs would save single-digit milliseconds a minute.
* It does not touch `interval_number` on the jobs that need 1-minute latency:
  expire_stale_attempts (settles papers), recompute_subjective_results (also
  drains `score_outlier_stale` and `cohort_close_stale`, both raised by a
  settlement), send_invitations, and the scoring shards.

Every statement is guarded on the row existing and is idempotent, so this is
safe to re-run and a no-op where the values already match.
"""
import logging

_logger = logging.getLogger(__name__)

# xmlid -> (priority, interval_number or None to leave alone)
#
# Keep in step with data/cron.xml. The scale, in order of who is waiting:
#   0  a candidate's paper is being settled
#   3  candidate-visible and fast
#   7  the 33.6 s scoring job
#   8  authoring; nobody waits on these mid-exam
#   9  daily housekeeping
CRON_PLAN = {
    "ir_cron_expire_stale_attempts":        (0, None),
    "ir_cron_recompute_subjective_results": (3, None),
    "ir_cron_send_pending_invitations":     (3, None),
    "ir_cron_llm_auto_score":               (7, None),
    "ir_cron_llm_auto_score_shard_1":       (7, None),
    "ir_cron_llm_auto_score_shard_2":       (7, None),
    "ir_cron_llm_auto_score_shard_3":       (7, None),
    "ir_cron_render_pending_images":        (8, 5),
    "ir_cron_detect_image_labels":          (8, 5),
    "ir_cron_generate_from_sop":            (8, 5),
    "ir_cron_extract_tags":                 (8, 5),
    "ir_cron_poll_video_ops":               (8, None),
    "ir_cron_purge_expired_pii":            (9, None),
}

# Seconds added to `nextcall` per job, to break the same-second herd. Ordered so
# the jobs a candidate waits on keep the earliest slots.
STAGGER_ORDER = [
    "ir_cron_expire_stale_attempts",
    "ir_cron_recompute_subjective_results",
    "ir_cron_send_pending_invitations",
    "ir_cron_llm_auto_score",
    "ir_cron_llm_auto_score_shard_1",
    "ir_cron_llm_auto_score_shard_2",
    "ir_cron_llm_auto_score_shard_3",
    "ir_cron_render_pending_images",
    "ir_cron_detect_image_labels",
    "ir_cron_generate_from_sop",
    "ir_cron_extract_tags",
    "ir_cron_poll_video_ops",
]
STAGGER_STEP_SECONDS = 4


def _cron_ids(cr):
    """xmlid -> res_id for our cron records that actually exist."""
    cr.execute("""
        SELECT name, res_id FROM ir_model_data
         WHERE module = 'assessments_be_v2'
           AND model = 'ir.cron'
    """)
    return dict(cr.fetchall())


def migrate(cr, version):
    if not version:
        # Fresh install: data/cron.xml has already written these values.
        return

    cr.execute("""
        SELECT 1 FROM information_schema.columns
         WHERE table_name = 'ir_cron' AND column_name = 'priority'
    """)
    if not cr.fetchone():
        _logger.warning(
            "ir_cron has no `priority` column on this Odoo build; skipping the "
            "cron priority migration. Ordering stays on id, so a scoring tick "
            "can still delay auto-submit.")
        return

    ids = _cron_ids(cr)
    if not ids:
        _logger.info("No assessments_be_v2 cron records found; nothing to do.")
        return

    touched = 0
    for xmlid, (priority, interval) in CRON_PLAN.items():
        res_id = ids.get(xmlid)
        if not res_id:
            # A record an operator deleted, or one this version never shipped.
            continue
        if interval is None:
            cr.execute(
                "UPDATE ir_cron SET priority = %s WHERE id = %s "
                "AND priority IS DISTINCT FROM %s",
                (priority, res_id, priority))
        else:
            # `interval_type` is asserted as well as `interval_number`: setting
            # 5 against a row someone had switched to hours would turn a
            # 5-minute job into a 5-hour one.
            # The `IS DISTINCT FROM` pair is not just tidiness: without it
            # `cr.rowcount` counts a no-op rewrite as a change, and the summary
            # log then claims work on a re-run that did nothing. A migration that
            # over-reports is a migration nobody trusts.
            cr.execute(
                "UPDATE ir_cron SET priority = %s, interval_number = %s "
                " WHERE id = %s AND interval_type = 'minutes' "
                "   AND (priority IS DISTINCT FROM %s "
                "        OR interval_number IS DISTINCT FROM %s)",
                (priority, interval, res_id, priority, interval))
        touched += cr.rowcount

    # THE STAGGER. Only ever moves `nextcall` FORWARD by a few seconds, and only
    # for jobs due now or in the past - never delays a job an operator has
    # deliberately scheduled far ahead, and never pulls one earlier.
    for offset, xmlid in enumerate(STAGGER_ORDER):
        res_id = ids.get(xmlid)
        if not res_id:
            continue
        cr.execute(
            "UPDATE ir_cron "
            "   SET nextcall = nextcall + (%s * INTERVAL '1 second') "
            " WHERE id = %s AND nextcall <= (now() at time zone 'UTC')",
            (offset * STAGGER_STEP_SECONDS, res_id))

    _logger.info(
        "assessments_be_v2: cron fleet re-prioritised (%d rows changed). "
        "expire_stale_attempts is now priority 0 so a candidate's settlement "
        "cannot queue behind a 33 s scoring tick; the four authoring jobs moved "
        "to 5-minute intervals; nextcall staggered %d s apart.",
        touched, STAGGER_STEP_SECONDS)
