# -*- coding: utf-8 -*-
"""Tag extraction must stay OFF the web request.

Generator tag-extraction lifecycle: queueing, statusbar, re-run signal, failure.
Ported from `etp_assessment_pro` at the fork point - `_queue_tag_extract`,
`_cron_extract_tags` and `_finalize_tag_extract_state` live in models/prompt.py
here now and arrived with ZERO coverage.

THE PRODUCTION DEFECT. Extract Tags died with
``psycopg2.errors.SerializationFailure: could not serialize access due to
concurrent update`` and left the badge stuck on "Generating" forever.

Extraction ran INLINE in the web request. Odoo serves requests at REPEATABLE
READ, so the snapshot is fixed at the first query - and the inline path then
wrote the SAME prompt row from TWO connections:

  1. ``_commit_tag_extract_status`` opened an independent cursor and committed
     ``tag_extract_state`` immediately, so a 'failed' status could outlive the
     rollback Odoo performs on UserError;
  2. ~20s later, once Vertex answered, the request wrote the tags through the
     ORM on its own cursor - against a snapshot that was now stale.

The request was losing a race against ITSELF, which an advisory lock cannot fix:
it serialises one request against another, never a connection against a second
connection opened by the same request. The fix queues the work and triggers
``ir_cron_extract_tags``, which owns its transaction and may legitimately commit
its own progress. Guards in ``TestExtractTagsStaysOffTheRequest``, especially
``test_request_never_opens_a_second_cursor`` - the actual root cause.

Extraction is still MANUAL-ONLY: the cron never selects a generator by itself.

Older lifecycle bugs also covered here:
  * NOTHING ever wrote ``state = 'skills_ready'``, so that statusbar step was a
    decorative label. The cron finalizer advances it.
  * A re-run starts and ends on ``tag_extract_state = 'done'``, so the button
    felt dead - hence ``tag_extract_last_run``.
  * A failed extraction must leave a terminal, visible 'failed' status rather
    than reverting to the previous value.
"""
import json
import logging
from contextlib import ExitStack
from unittest.mock import patch

from psycopg2.errors import SerializationFailure

from odoo.tests.common import TransactionCase

from odoo.addons.assessments_be_v2.services import vertex
from odoo.tools import mute_logger

CRON_XMLID = "assessments_be_v2.ir_cron_extract_tags"


class _TagFlowBase(TransactionCase):
    def setUp(self):
        super().setUp()
        self.Prompt = self.env["assessments.be.prompt"]

    def _prompt(self, **vals):
        base = {"name": "Gen", "source_text": "A SOP body worth tagging."}
        base.update(vals)
        return self.Prompt.create(base)

    def _drain(self, names=("alpha", "beta"), fail_with=None):
        """Run the drainer cron exactly as the scheduler would.

        Odoo's test cursor raises on commit/rollback, and the cron commits its
        own progress on purpose, so both are redirected at the transaction the
        test already owns - the same technique test_sop_gen_directive_bugs.py
        uses to drive this cron.
        """
        cr = self.env.cr
        if fail_with is not None:
            vertex_patch = patch.object(vertex, "extract_tags_from_sop",
                                        side_effect=fail_with)
        else:
            vertex_patch = patch.object(vertex, "extract_tags_from_sop",
                                        return_value=(list(names), "{}"))
        with vertex_patch, \
                patch.object(self.Prompt.__class__, "_auto_rank_after_mapping",
                             lambda self, **kw: None), \
                patch.object(cr, "commit", cr.flush), \
                patch.object(cr, "rollback", cr.clear):
            self.Prompt._cron_extract_tags()

    def _extract(self, prompt, names=("alpha", "beta")):
        """Press Extract Tags, then let the queued work drain."""
        result = prompt.action_extract_tags()
        self._drain(names)
        prompt.invalidate_recordset()
        return result


class TestExtractTagsStaysOffTheRequest(_TagFlowBase):
    """THE BUG: the request must not do the slow work, and must not write the
    prompt row from a second connection."""

    def setUp(self):
        super().setUp()
        # Ships active (data/cron.xml); local and staging copies switch it off.
        self.env.ref(CRON_XMLID).sudo().active = True

    def test_request_never_opens_a_second_cursor(self):
        """The root cause of the 40001, guarded directly.

        An independent-cursor write to a row the SAME request will later write
        through the ORM is unfixable by locking: it always races the request's
        own snapshot. No second cursor may be opened while serving the button.
        """
        prompt = self._prompt()
        with patch.object(type(self.env.registry), "cursor") as spy:
            prompt.action_extract_tags()
        self.assertEqual(
            spy.call_count, 0,
            "action_extract_tags opened an independent cursor; writing the "
            "prompt row from a second connection is what produced the 40001")

    def test_button_does_not_call_vertex_in_the_request(self):
        """A ~20s LLM call inside the request is what held the stale snapshot
        open long enough to lose the race (and blocked an HTTP worker)."""
        prompt = self._prompt()
        with patch.object(vertex, "extract_tags_from_sop") as called:
            prompt.action_extract_tags()
        called.assert_not_called()

    def test_button_queues_the_generator(self):
        prompt = self._prompt()
        prompt.action_extract_tags()
        self.assertEqual(prompt.tag_extract_state, "queued")
        self.assertFalse(prompt.tag_extract_error)

    def test_the_click_alone_advances_nothing(self):
        """The click is a request, not a result.

        Advancing the statusbar (or showing tags) before the cron has read
        anything would claim work that has not happened, and a later failure
        would then have to walk it back.
        """
        prompt = self._prompt()
        prompt.action_extract_tags()
        prompt.invalidate_recordset()
        self.assertEqual(prompt.tag_extract_state, "queued")
        self.assertEqual(prompt.state, "draft")
        self.assertFalse(prompt.tag_ids)

    def test_button_triggers_the_cron_for_an_immediate_start(self):
        """Without _trigger the admin waits for the next tick; the queue would
        still drain, just not promptly."""
        cron = self.env.ref(CRON_XMLID)
        # Must be active for this to mean anything: Odoo's _trigger_list drops
        # a trigger due now when the cron is inactive ("skip triggers that
        # would be ignored"), so an inactive cron would make the assertion
        # below fail for a reason that has nothing to do with queueing.
        self.assertTrue(cron.active, "the drainer cron must ship active")
        Trigger = self.env["ir.cron.trigger"]
        before = Trigger.search_count([("cron_id", "=", cron.id)])
        self._prompt().action_extract_tags()
        self.assertEqual(
            Trigger.search_count([("cron_id", "=", cron.id)]), before + 1,
            "queueing must wake the drainer, or the admin waits a full tick")

    def test_the_drainer_cron_exists_and_points_at_the_drain(self):
        """Exists, active, and wired to THIS addon's drain.

        This fleet runs alongside `etp_assessment_pro`'s. That is safe because
        the two search different tables and hold different advisory locks - but
        it only works if this record points at OUR model and OUR method. A cron
        that exists but is misrouted drains nothing, and the symptom is
        identical to having no cron at all: rows sit on "Queued" forever.
        """
        cron = self.env.ref(CRON_XMLID, raise_if_not_found=False)
        self.assertTrue(cron, "queued extractions would never be processed")
        self.assertTrue(cron.active)
        self.assertIn("_cron_extract_tags", cron.code)
        self.assertEqual(cron.model_id.model, "assessments.be.prompt")

    def test_cron_never_picks_up_an_unqueued_generator(self):
        """Extraction stays MANUAL-ONLY: the drainer only takes what an admin
        explicitly queued, never a generator sitting idle."""
        idle = self._prompt()
        self.assertEqual(idle.tag_extract_state, "idle")
        self._drain()
        idle.invalidate_recordset()
        self.assertEqual(idle.tag_extract_state, "idle")
        self.assertFalse(idle.tag_ids)

    def test_button_refuses_a_generator_with_nothing_to_read(self):
        from odoo.exceptions import UserError
        prompt = self._prompt(source_text="")
        with self.assertRaises(UserError):
            prompt.action_extract_tags()


class TestTagExtractAdvancesStatusbar(_TagFlowBase):
    def test_extraction_lights_the_tags_extracted_step(self):
        prompt = self._prompt()
        self.assertEqual(prompt.state, "draft")
        self._extract(prompt)
        self.assertEqual(
            prompt.state, "skills_ready",
            "a successful extraction must advance the statusbar")
        self.assertEqual(prompt.tag_extract_state, "done")

    def test_skills_ready_is_a_reachable_state(self):
        # Guards the regression class: a Selection value no code path writes
        # is a decorative label, not a state.
        prompt = self._prompt()
        self._extract(prompt)
        codes = dict(
            self.Prompt._fields["state"]._description_selection(self.env))
        self.assertIn("skills_ready", codes)
        self.assertEqual(codes["skills_ready"], "Tags Extracted")
        self.assertEqual(prompt.state, "skills_ready")

    def test_rerun_never_drags_a_later_state_backwards(self):
        """A generator mid-generation must not regress to 'Tags Extracted'."""
        for later in ("generating", "done"):
            prompt = self._prompt()
            prompt.write({"state": later})
            self._extract(prompt)
            self.assertEqual(
                prompt.state, later,
                "re-extracting tags must not move %r backwards" % later)

    @mute_logger("odoo.addons.assessments_be_v2.models.prompt")
    def test_failed_extraction_does_not_advance_state(self):
        prompt = self._prompt()
        prompt.action_extract_tags()
        self._drain(fail_with=RuntimeError("boom"))
        prompt.invalidate_recordset()
        self.assertEqual(prompt.state, "draft",
                         "a failed run must not claim tags were extracted")


class TestTagExtractRerunIsVisible(_TagFlowBase):
    def test_first_run_records_a_timestamp(self):
        prompt = self._prompt()
        self.assertFalse(prompt.tag_extract_last_run)
        prompt.action_extract_tags()
        prompt.invalidate_recordset()
        self.assertFalse(
            prompt.tag_extract_last_run,
            "queuing is not a run - the timestamp must mark completion")
        self._drain()
        prompt.invalidate_recordset()
        self.assertTrue(
            prompt.tag_extract_last_run,
            "without a timestamp a re-run leaves the screen identical")

    def test_first_run_toast(self):
        prompt = self._prompt()
        res = prompt.action_extract_tags()
        self.assertEqual(res["params"]["title"], "Extracting Tags")
        # The toast is the only thing the admin gets back, so it has to say the
        # work is still coming - otherwise 'Extracting Tags' over an unchanged
        # screen reads as a button that did nothing.
        self.assertIn("background", res["params"]["message"])

    def test_rerun_is_labelled_as_a_rerun(self):
        prompt = self._prompt()
        self._extract(prompt)
        res = prompt.action_extract_tags()
        self.assertEqual(res["params"]["title"], "Re-extracting Tags")

    def test_rerun_shows_a_busy_state_to_poll_on(self):
        """A re-run must change something the auto-refresh widget can see.

        The tags already on screen stay there until the new set replaces them,
        so 'queued' is the only visible change when the button is pressed a
        second time - and it is exactly what be_auto_refresh polls on.
        """
        prompt = self._prompt()
        self._extract(prompt, names=("alpha", "beta"))
        self.assertEqual(prompt.tag_extract_state, "done")
        prompt.action_extract_tags()
        prompt.invalidate_recordset()
        self.assertEqual(prompt.tag_extract_state, "queued")
        self.assertEqual(len(prompt.tag_ids), 2,
                         "the previous tags stay visible while the cron works")

    def test_rerun_replaces_the_tag_set(self):
        prompt = self._prompt()
        self._extract(prompt, names=("alpha", "beta"))
        self.assertEqual(len(prompt.tag_ids), 2)
        self._extract(prompt, names=("gamma",))
        self.assertEqual(len(prompt.tag_ids), 1,
                         "a re-run replaces the tag set, never appends to it")

    def test_the_toast_reloads_the_form_so_the_badge_can_start(self):
        """swe-odoo-ui-1: the toast must reload the form.

        The badge reads the record the FORM holds, and a
        `display_notification` with no `next` reloads nothing - so the form
        keeps the pre-click terminal value (`idle`/`done`) and the badge never
        polls, although `queued` is a busy state.

        The reload hands the already-mounted badge the now-busy record, and
        `onWillUpdateProps` starts the poll from there. Nothing races: the
        reload is a read, and the widget's own timer is reset by it."""
        prompt = self._prompt()
        res = prompt.action_extract_tags()
        self.assertEqual(res["params"]["next"],
                         {"type": "ir.actions.act_window_close"})
        self.assertEqual(prompt.tag_extract_state, "queued")


class TestTagExtractFailureIsRecorded(_TagFlowBase):
    """Failure must leave a visible, actionable status.

    This no longer needs an independent cursor. The cron owns its transaction,
    so it records 'failed' and commits it directly - there is no request left
    to roll the status back.
    """

    def _fail(self, prompt, exc):
        prompt.action_extract_tags()
        self._drain(fail_with=exc)
        prompt.invalidate_recordset()

    @mute_logger("odoo.addons.assessments_be_v2.models.prompt")
    def test_failure_sets_state_and_error(self):
        prompt = self._prompt()
        self._fail(prompt, RuntimeError("Vertex exploded"))
        self.assertEqual(prompt.tag_extract_state, "failed")
        self.assertIn("Vertex exploded", prompt.tag_extract_error or "")
        self.assertFalse(prompt.tag_ids,
                         "a run that failed must not leave a partial tag set")

    @mute_logger("odoo.addons.assessments_be_v2.models.prompt")
    def test_failure_is_terminal_never_stuck_queued(self):
        """A row left on 'queued'/'generating' is picked up again forever and
        the badge spins for good - the visible symptom of the old defect."""
        prompt = self._prompt()
        self._fail(prompt, RuntimeError("boom"))
        self.assertNotIn(prompt.tag_extract_state, ("queued", "generating"))

    def test_quota_failure_requeues_for_the_next_tick(self):
        """429 is transient, so it is re-queued rather than marked failed."""
        prompt = self._prompt()
        self._fail(prompt, vertex.VertexQuotaError("429"))
        self.assertEqual(prompt.tag_extract_state, "queued")
        self.assertFalse(prompt.tag_extract_error,
                         "a transient 429 must not leave an error on the badge")
        self.assertFalse(prompt.tag_extract_error)

    @mute_logger("odoo.addons.assessments_be_v2.models.prompt")
    def test_failure_is_flushed_to_the_database(self):
        prompt = self._prompt()
        self._fail(prompt, RuntimeError("boom"))
        self.env.cr.execute(
            "SELECT tag_extract_state FROM assessments_be_prompt "
            "WHERE id = %s", (prompt.id,))
        self.assertEqual(self.env.cr.fetchone()[0], "failed")

    @mute_logger("odoo.addons.assessments_be_v2.models.prompt")
    def test_success_after_failure_clears_the_error(self):
        prompt = self._prompt()
        self._fail(prompt, RuntimeError("boom"))
        self.assertEqual(prompt.tag_extract_state, "failed")
        self._extract(prompt)
        self.assertEqual(prompt.tag_extract_state, "done")
        self.assertFalse(prompt.tag_extract_error,
                         "a successful re-run must clear the stale error")

# TestTagExtractViewSurfacesRun (etp_assessment_pro) was not ported: its two
# tests read the prompt form arch for the timestamp and the statusbar step.
# This addon's generator form shows both (views/prompt_views.xml); this file
# does not assert on that arch.


class TestAPaidReplyIsNeverBoughtTwice(_TagFlowBase):
    """The Vertex reply is kept the moment it arrives, so a finalize that loses
    every retry (re-queued as a lost race) is finished on the next tick from
    the kept reply instead of paying for the call again."""

    REPLY = json.dumps({"tags": [
        {"key": "task:spot-flaws", "display": "Spot Flaws"},
        {"key": "domain:image-annotation", "display": "Image Annotation"}]})

    def _tick(self, finalize_loses=False):
        # The cron takes ANY two waiting generators; a database copy can hold
        # someone else's, which would make the paid-call count lie.
        self.Prompt.search([
            ("tag_extract_state", "in", ("queued", "generating")),
            ("create_date", "<", self.env.cr.now()),   # not this test's
        ]).write({"tag_extract_state": "idle"})
        cr = self.env.cr
        with ExitStack() as stack:
            paid = stack.enter_context(patch.object(
                vertex, "_tag_reply", return_value=self.REPLY))
            stack.enter_context(self.enter_registry_test_mode())
            stack.enter_context(patch.object(
                self.Prompt.__class__, "_auto_rank_after_mapping",
                lambda self, **kw: None))
            stack.enter_context(patch.object(cr, "commit", cr.flush))
            stack.enter_context(patch.object(cr, "rollback", cr.clear))
            if finalize_loses:
                stack.enter_context(patch.object(
                    self.Prompt.__class__, "_finalize_tag_extract_state",
                    side_effect=SerializationFailure(
                        "could not serialize access")))
                stack.enter_context(self.assertLogs(
                    "odoo.addons.assessments_be_v2.models",
                    level=logging.WARNING))
            self.Prompt._cron_extract_tags()
        return paid.call_count

    def test_a_lost_finalize_is_finished_from_the_kept_reply(self):
        prompt = self._prompt()
        prompt.action_extract_tags()

        self.assertEqual(self._tick(finalize_loses=True), 1)
        prompt.invalidate_recordset()
        self.assertEqual(prompt.tag_extract_state, "queued")
        self.assertEqual(prompt.tag_extract_reply, self.REPLY)

        self.assertEqual(self._tick(), 0, "the kept reply was paid for again")
        prompt.invalidate_recordset()
        self.assertEqual(prompt.tag_extract_state, "done")
        self.assertFalse(prompt.tag_extract_reply)
        self.assertEqual(sorted(prompt.tag_ids.mapped("name")),
                         ["domain:image-annotation", "task:spot-flaws"])

    def test_a_new_press_is_a_new_read(self):
        prompt = self._prompt()
        prompt.tag_extract_reply = self.REPLY

        prompt.action_extract_tags()

        self.assertFalse(prompt.tag_extract_reply)
