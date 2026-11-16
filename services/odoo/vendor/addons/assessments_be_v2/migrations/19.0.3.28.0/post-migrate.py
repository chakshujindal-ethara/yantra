# -*- coding: utf-8 -*-
"""assessments_be_v2 19.0.3.28.0 post-migration: AI violations apart (R5), one
quit password per paper (R3), the answer key shown by default (R6).

1. Each paper's AI limit and mode start as copies of its regular pair. -u fills
   the field defaults (5, Log only) into every existing row, which would
   quietly change the policy of a paper configured otherwise. Only rows still
   at those defaults are copied onto, so a rerun keeps an AI policy chosen
   after the upgrade.
2. "AI: " entries move out of `violation_log` into `ai_violation_log`, order
   kept, and `violation_count` gives them back. A count larger than its log
   (counted before the log existed) or an erased `[]` log keeps its unlogged
   history as regular: it cannot be classified. An attempt already
   auto-submitted for violations under the old shared cap keeps its combined
   count and log: they are what that verdict, and any appeal, rests on. So
   does one whose combined count already reached its paper's limit (shown as
   "Violation Limit Breached", Log only included, where nothing ended): a
   split would take that label away. Only logs still holding an AI entry are
   touched.
3. A `seb_quit_password` shared by several papers (-u filled the column's
   default into every existing row as ONE value) is replaced per paper, so
   one leaked password no longer quits every exam. A running SEB paper is
   skipped and logged: its candidates' .seb holds the old hash. Only
   passwords still shared are touched.
4. A transcription key holding a digit (0-9 or Devanagari) is listed in a
   WARNING, never changed: numbers are words now, so such a key reads a
   correct words answer as a difference until a person rewrites it.
5. A NULL `results_show_answers` becomes shown. A paper inserted by code that
   did not know the column (a pod still on the old code) before `init()` gave
   it a TRUE default holds NULL, which reads as hidden. A chosen Off stays.

Idempotent: a second run finds nothing left to change.
"""
import json
import logging
import re

from odoo.addons.assessments_be_v2.services import seb

_logger = logging.getLogger(__name__)

VERSION = "19.0.3.28.0"
AI_LIKE = "AI: %"
DIGIT = re.compile("[0-9\u0966-\u096f]")


def migrate(cr, version):
    # Falsy on a fresh install: no row predates the new columns.
    if not version:
        return
    cr.execute("""
        UPDATE assessments_be
           SET ai_max_violations = max_violations,
               ai_violation_action = violation_action
         WHERE ai_max_violations = 5 AND ai_violation_action = 'log_only'
           AND (max_violations, violation_action)
               IS DISTINCT FROM (5, 'log_only')""")
    policies = cr.rowcount

    # The CASE keeps a JSON null (or any non-array) out of
    # jsonb_array_elements, which raises on one.
    cr.execute("""
        WITH split AS (
            SELECT e.id,
                   COUNT(*) FILTER (WHERE v.elem->>'reason' LIKE %(ai)s)
                       AS n_ai,
                   jsonb_agg(v.elem ORDER BY v.ord)
                       FILTER (WHERE v.elem->>'reason' LIKE %(ai)s) AS ai_log,
                   COALESCE(jsonb_agg(v.elem ORDER BY v.ord) FILTER (
                       WHERE (v.elem->>'reason' LIKE %(ai)s) IS NOT TRUE),
                       '[]'::jsonb) AS regular_log
              FROM assessments_be_evaluator e
             CROSS JOIN LATERAL jsonb_array_elements(
                   CASE WHEN jsonb_typeof(e.violation_log) = 'array'
                        THEN e.violation_log ELSE '[]'::jsonb END)
                   WITH ORDINALITY AS v(elem, ord)
             GROUP BY e.id
        )
        UPDATE assessments_be_evaluator e
           SET violation_log = s.regular_log,
               ai_violation_log = s.ai_log
                   || COALESCE(e.ai_violation_log, '[]'::jsonb),
               violation_count = GREATEST(
                   COALESCE(e.violation_count, 0) - s.n_ai, 0),
               ai_violation_count = COALESCE(e.ai_violation_count, 0) + s.n_ai
          FROM split s
         WHERE e.id = s.id AND s.n_ai > 0
           AND e.auto_submit_reason IS DISTINCT FROM 'violation'
           -- `_compute_violation_limit_breached` on the combined count: a
           -- cap of 0 (or below) is the first violation under Auto-submit
           -- and no limit under Log only.
           AND NOT EXISTS (
               SELECT 1 FROM assessments_be a
                WHERE a.id = e.assessment_id
                  AND COALESCE(e.violation_count, 0) >= CASE
                      WHEN COALESCE(a.max_violations, 0) > 0
                           THEN a.max_violations
                      WHEN a.violation_action = 'auto_submit' THEN 1
                      ELSE NULL END)""",
               {"ai": AI_LIKE})
    split = cr.rowcount

    cr.execute("""
        SELECT id, rule_require_seb IS TRUE AND state = 'in_progress'
          FROM assessments_be
         WHERE seb_quit_password IN (
               SELECT seb_quit_password FROM assessments_be
                WHERE COALESCE(seb_quit_password, '') <> ''
                GROUP BY seb_quit_password HAVING COUNT(*) > 1)
         ORDER BY id""")
    rows = cr.fetchall()
    skipped = [paper_id for paper_id, running in rows if running]
    renewed = 0
    for paper_id, running in rows:
        if not running:
            cr.execute(
                "UPDATE assessments_be SET seb_quit_password = %s "
                "WHERE id = %s", (seb.new_quit_password(), paper_id))
            renewed += 1
    if skipped:
        _logger.warning(
            "assessments_be_v2 %s: kept the shared SEB quit password on "
            "running SEB paper(s) %s; regenerate it there between sittings.",
            VERSION, skipped)

    cr.execute("SELECT id, solution_json FROM assessments_be_question "
               "WHERE question_type = 'transcription' ORDER BY id")
    with_digits = [qid for qid, raw in cr.fetchall()
                   if DIGIT.search(_transcription(raw))]
    if with_digits:
        _logger.warning(
            "assessments_be_v2 %s: transcription question(s) %s hold a digit "
            "in their key; write each number as words, or a correct answer "
            "reads as a difference.", VERSION, with_digits)
    cr.execute("UPDATE assessments_be SET results_show_answers = TRUE "
               "WHERE results_show_answers IS NULL")
    shown = cr.rowcount
    _logger.info(
        "assessments_be_v2 %s: AI policy copied to %d paper(s); %d attempt "
        "log(s) split; %d quit password(s) regenerated; answer key shown on "
        "%d paper(s) that held no setting.",
        VERSION, policies, split, renewed, shown)


def _transcription(raw):
    """The key text of a transcription question's `solution_json`, or ""."""
    try:
        solution = json.loads(raw or "{}")
    except (ValueError, TypeError):
        return ""
    text = solution.get("transcription") if isinstance(solution, dict) else ""
    return text if isinstance(text, str) else ""
