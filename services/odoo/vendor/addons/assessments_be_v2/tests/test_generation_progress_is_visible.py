# -*- coding: utf-8 -*-
"""The generator screen can watch a run the way the Assessment page watches
scoring (plan §4.9, owner-approved option A, 2026-09-29).

THE GAP. A run could sit "Queued" for up to 5 minutes, author for several more
and then render images 2 drafts per 5 minutes, and the screen said nothing in
between: no phase, no model calls, no elapsed time, no reason when a cron was
off. Draft 85 went to `failed` with no retry in the app.

What is pinned here:
  * `/api/v1/generators/<id>/progress` - every phase, the latest run's drafts
    only, run stats from the ledger since `sop_gen_started_at`, run cost only
    for operators, and a stalled reason when a cron with work is off or late
    (a tick still running is not late).
  * `/drafts/<id>/retry_images` and `/generators/<id>/retry_failed_images` -
    refused with nothing failed; otherwise failed -> pending, attempts reset,
    already-rendered images kept (they were paid for).
  * The SOP cron stamps `sop_gen_started_at` when it starts a run and
    `sop_gen_finished_at` on every terminal state.

Nothing here calls Vertex.
"""
import json
import logging
from contextlib import contextmanager
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.sql_db import db_connect
from odoo.tests.common import HttpCase, TransactionCase, tagged
from odoo.tools import mute_logger

from ..constants import (
    ADVISORY_LOCK_IMAGE_RENDER, GROUP_MANAGER, GROUP_MANAGER_RESTRICTED,
    IMAGE_RENDER_BATCH,
)
from ..controllers.api.admin import _gen_step, _generation_progress
from ..controllers.api.common import is_operator
from ..services import vertex

_JSON = {"Content-Type": "application/json"}
_CRONS = ("ir_cron_generate_from_sop", "ir_cron_render_pending_images",
          "ir_cron_poll_video_ops")


@contextmanager
def _cron_tick_is_running(env, lock):
    """Hold ``lock`` on a connection of its own, as a cron mid-tick does."""
    with db_connect(env.cr.dbname).cursor() as other:
        try:
            other.execute("SELECT pg_try_advisory_lock(%s)", [lock])
            assert other.fetchone()[0], "a real cron holds lock %s" % lock
            yield
        finally:
            other.execute("SELECT pg_advisory_unlock_all()")


class _Fixture:

    def setUp(self):
        super().setUp()
        # The TRANSACTION's clock: `create_date` is stamped from it, and a
        # TransactionCase class runs in one transaction. Whole seconds, like
        # the `fields.Datetime.now()` the cron stamps a run with.
        self.now = self.env.cr.now().replace(microsecond=0)
        self.Prompt = self.env["assessments.be.prompt"]
        self.Draft = self.env["assessments.be.prompt.question"]
        self.Usage = self.env["assessments.be.llm.usage"]
        self.generator = self.Prompt.create(
            {"name": "Progress %s" % uuid4().hex[:6]})
        # A healthy baseline, whatever the copied database's crons look like.
        self.crons = {x: self.env.ref("assessments_be_v2.%s" % x).sudo()
                      for x in _CRONS}
        for cron in self.crons.values():
            cron.write({"active": True, "nextcall":
                        fields.Datetime.now() + timedelta(minutes=10)})

    def _draft(self, generator=None, **vals):
        return self.Draft.create(dict({
            "prompt_id": (generator or self.generator).id,
            "name": "Draft %s" % uuid4().hex[:6],
            "question_type": "mcq",
        }, **vals))

    def _backdate(self, record, when):
        self.env.flush_all()
        self.env.cr.execute(
            'UPDATE "%s" SET create_date = %%s WHERE id = %%s' % record._table,
            [when, record.id])
        record.invalidate_recordset(["create_date"])

    def _progress(self, show_cost=True, can_retry=True):
        return _generation_progress(
            self.generator, show_cost=show_cost, can_retry=can_retry)


@tagged("-at_install", "post_install")
class TestGenerationProgressIsVisible(_Fixture, TransactionCase):

    # ── phase ──────────────────────────────────────────────────────────────

    def test_every_run_state_maps_to_its_phase(self):
        for state, phase, active in (
                ("queued", "queued", True),
                ("generating", "authoring", True),
                ("finalizing", "finalizing", True),
                ("failed", "failed", False),
                ("cancelled", "cancelled", False)):
            with self.subTest(state=state):
                self.generator.sop_gen_state = state
                data = self._progress()
                self.assertEqual(data["phase"], phase)
                self.assertIs(data["active"], active)

    def test_a_finished_run_is_media_while_anything_still_renders(self):
        self.generator.sop_gen_state = "done"
        self.assertEqual(self._progress()["phase"], "idle",
                         "no drafts at all is idle, not ready")

        self._draft(image_state="rendered")
        self.assertEqual(self._progress()["phase"], "ready")

        pending = self._draft(image_state="pending")
        data = self._progress()
        self.assertEqual(data["phase"], "media")
        self.assertTrue(data["active"])

        pending.image_state = "rendered"
        self._draft(video_state="generating")
        self.assertEqual(self._progress()["phase"], "media",
                         "a Veo op in flight is still pending work")

    def test_idle_generator_says_nothing(self):
        data = self._progress()
        self.assertEqual((data["phase"], data["active"], data["summary"]),
                         ("idle", False, ""))
        self.assertIsNone(data["run"]["started_at"])
        self.assertEqual(data["run"]["llm_calls"], 0)

    # ── the latest run's drafts ────────────────────────────────────────────

    def test_only_the_latest_runs_drafts_are_counted(self):
        old = self._draft(state="approved", image_state="failed")
        self._backdate(old, self.now - timedelta(hours=2))
        self._draft()
        self._draft(state="approved", image_state="rendered")
        self._draft(state="denied", image_state="uploaded")
        failed = self._draft(image_state="failed")
        self._draft(video_state="rendered")
        self._draft(video_state="partial")
        self._draft(image_state="cancelled", video_state="cancelled")
        self._draft(generator=self.Prompt.create({"name": "Other"}),
                    image_state="failed")
        self.generator.write({"sop_gen_state": "done",
                              "sop_gen_started_at":
                                  self.now - timedelta(minutes=10),
                              "sop_gen_finished_at": self.now})

        data = self._progress()

        self.assertEqual(data["drafts"], {"total": 7, "pending": 5,
                                          "approved": 1, "denied": 1})
        self.assertEqual(data["images"], {
            "total": 4, "pending": 0, "rendered": 1, "uploaded": 1,
            "failed": 1, "cancelled": 1})
        self.assertEqual(data["videos"], {
            "total": 3, "pending": 0, "ready": 1, "failed": 1,
            "cancelled": 1})
        self.assertEqual(data["failed_images"],
                         [{"id": failed.id, "name": failed.name}],
                         "the previous run's failure is not this run's")
        self.assertTrue(data["can_retry_images"])
        self.assertFalse(self._progress(can_retry=False)["can_retry_images"])

    def test_a_run_from_before_the_timestamps_counts_every_draft(self):
        old = self._draft()
        self._backdate(old, self.now - timedelta(days=30))
        self._draft()
        self.generator.sop_gen_state = "done"
        self.assertEqual(self._progress()["drafts"]["total"], 2)

    # ── run stats from the ledger ──────────────────────────────────────────

    def _ledger(self, cost, operation="generate_questions", note="",
                generator=None):
        return self.Usage.create({
            "operation": operation, "cost_usd": cost, "note": note,
            "prompt_id": (generator or self.generator).id})

    def test_run_stats_come_from_this_runs_ledger_rows(self):
        before = self._ledger(5.0, note=self.generator.name)
        self._backdate(before, self.now - timedelta(hours=1))
        self._ledger(9.0, generator=self.Prompt.create({"name": "Other"}))
        self._ledger(0.5, note=self.generator.name)
        self._ledger(0.25, note="critique")
        self.generator.write({
            "sop_gen_state": "generating",
            "sop_gen_started_at": self.now - timedelta(minutes=5)})

        run = self._progress()["run"]

        self.assertEqual(run["llm_calls"], 2)
        self.assertAlmostEqual(run["cost_usd"], 0.75)
        self.assertEqual(run["last_step"], "critique")
        self.assertTrue(run["last_step_at"].endswith("Z"))
        self.assertGreaterEqual(run["elapsed_s"], 300)
        self.assertIsNone(run["finished_at"])

    def test_elapsed_stops_at_the_finish(self):
        self.generator.write({
            "sop_gen_state": "done",
            "sop_gen_started_at": self.now - timedelta(minutes=5),
            "sop_gen_finished_at": self.now - timedelta(minutes=2)})
        self._draft()
        data = self._progress()
        self.assertEqual(data["run"]["elapsed_s"], 180)
        self.assertIn("took 3 min", data["summary"])

    def test_the_step_label_follows_the_ledger_note(self):
        Row = self.Usage.new
        for operation, note, label in (
                ("generate_questions", "My SOP", "main"),
                ("generate_questions", "My SOP (retry)", "retry"),
                ("generate_questions", "topup", "top-up"),
                ("generate_questions", "quota [fallback:x]", "top-up"),
                ("generate_questions", "critique", "critique"),
                ("generate_questions", "backfill_solutions", "answer keys"),
                ("generate_image", "Draft 1", "image"),
                ("submit_video_op", "clip", "video"),
                ("assign_question_skills", "", "assign question skills")):
            with self.subTest(note=note):
                self.assertEqual(
                    _gen_step(Row({"operation": operation, "note": note})),
                    label)

    # ── cost: operators only ───────────────────────────────────────────────

    def test_cost_is_shown_to_an_operator_only(self):
        self._ledger(1.234, note="critique")
        self.generator.write({
            "sop_gen_state": "generating",
            "sop_gen_started_at": self.now - timedelta(minutes=1)})

        hidden = self._progress(show_cost=False)
        self.assertIsNone(hidden["run"]["cost_usd"])
        self.assertFalse(hidden["show_cost"])
        self.assertNotIn("$", hidden["summary"])

        shown = self._progress(show_cost=True)
        self.assertAlmostEqual(shown["run"]["cost_usd"], 1.234)
        self.assertTrue(shown["show_cost"])
        self.assertIn("$1.23", shown["summary"])

    def test_the_cost_gate_is_the_ledger_routes_gate(self):
        def user(*groups):
            return self.env["res.users"].sudo().with_context(
                no_reset_password=True, mail_create_nolog=True,
                tracking_disable=True).create({
                    "name": "Cost %s" % uuid4().hex[:6],
                    "login": "cost_%s@example.com" % uuid4().hex[:8],
                    "group_ids": [(6, 0, [self.env.ref(g).id
                                          for g in groups])]})
        self.assertFalse(is_operator(user("base.group_user")))
        self.assertTrue(is_operator(user(GROUP_MANAGER_RESTRICTED)))
        self.assertTrue(is_operator(user(GROUP_MANAGER)),
                        "Admin implies Manager")

    # ── summary per phase ──────────────────────────────────────────────────

    def test_each_phase_has_its_one_line_summary(self):
        self.generator.sop_gen_state = "queued"
        self.assertIn("Queued · starts at the next generation run (~",
                      self._progress()["summary"])
        self.assertIn(" IST)", self._progress()["summary"])

        self.generator.write({
            "sop_gen_state": "generating",
            "sop_gen_started_at": self.now - timedelta(minutes=4)})
        self._ledger(0.1, note="topup")
        self.assertRegex(
            self._progress(show_cost=False)["summary"],
            r"^Writing questions · step top-up · 1 model call · \d+ min "
            r"elapsed$")

        self.generator.write({"sop_gen_state": "done",
                              "sop_gen_finished_at": self.now})
        self._draft(image_state="rendered")
        self._draft(image_state="failed")
        self._draft(image_state="pending")
        self._draft(video_state="rendered")
        summary = self._progress()["summary"]
        self.assertTrue(summary.startswith(
            "Rendering media · images 1/3 (1 failed) · videos 1/1 · "
            "next image batch ~"), summary)

        self.generator.sop_gen_state = "failed"
        self.generator.sop_gen_error = "No draft questions were created."
        self.assertEqual(
            self._progress()["summary"],
            "Generation failed - No draft questions were created.")
        self.assertNotIn("—", self._progress()["summary"])

    def test_the_ready_summary_counts_the_review_queue(self):
        self.generator.write({
            "sop_gen_state": "done",
            "sop_gen_started_at": self.now - timedelta(minutes=3),
            "sop_gen_finished_at": self.now})
        self._draft()
        self._draft(state="approved")
        self._ledger(0.5)
        self.assertEqual(
            self._progress(show_cost=False)["summary"],
            "2 drafts ready for review · 1 pending · 1 approved · 0 denied "
            "· took 3 min")
        self.assertTrue(self._progress()["summary"].endswith(
            " · run cost $0.50"))

        self.generator.question_ids.filtered(
            lambda d: d.state != "approved").write({"state": "approved"})
        self.assertTrue(self._progress(show_cost=False)["summary"].startswith(
            "All 2 drafts reviewed · 2 approved · 0 denied"))

    def test_an_overdue_render_job_prints_no_past_next_batch(self):
        self.generator.sop_gen_state = "done"
        self._draft(image_state="pending")
        self.crons["ir_cron_render_pending_images"].nextcall = (
            self.now - timedelta(minutes=30))
        progress = self._progress()
        self.assertTrue(progress["stalled"])
        self.assertNotIn("next image batch", progress["summary"])

    # ── media ETA ──────────────────────────────────────────────────────────

    def test_the_eta_comes_from_the_render_crons_real_schedule(self):
        self.generator.sop_gen_state = "done"
        for _i in range(3):
            self._draft(image_state="pending")
        cron = self.crons["ir_cron_render_pending_images"]
        cron.write({"interval_number": 5, "interval_type": "minutes"})

        media = self._progress()["media"]

        self.assertEqual(media["images_per_run"], IMAGE_RENDER_BATCH)
        self.assertEqual(media["image_run_every_min"], 5)
        self.assertEqual(
            media["est_minutes_left"], -(-3 // IMAGE_RENDER_BATCH) * 5)
        self.assertTrue(media["next_image_run_at"].endswith("Z"))

    # ── stalled ────────────────────────────────────────────────────────────

    def test_a_healthy_run_is_not_stalled(self):
        self.generator.sop_gen_state = "queued"
        self._draft(image_state="pending")
        data = self._progress()
        self.assertFalse(data["stalled"])
        self.assertIsNone(data["stalled_reason"])

    def test_a_queued_run_behind_an_inactive_cron_is_stalled(self):
        self.generator.sop_gen_state = "queued"
        self.crons["ir_cron_generate_from_sop"].active = False
        data = self._progress()
        self.assertTrue(data["stalled"])
        self.assertIn("question generation cron is switched off",
                      data["stalled_reason"])

    def test_a_queued_run_behind_an_overdue_cron_is_stalled(self):
        self.generator.sop_gen_state = "queued"
        self.crons["ir_cron_generate_from_sop"].nextcall = (
            fields.Datetime.now() - timedelta(minutes=10))
        data = self._progress()
        self.assertTrue(data["stalled"])
        self.assertIn("overdue", data["stalled_reason"])

    def test_pending_media_behind_an_overdue_or_inactive_cron_is_stalled(self):
        self.generator.sop_gen_state = "done"
        self._draft(image_state="pending")
        self._draft(video_state="pending")
        self.crons["ir_cron_render_pending_images"].nextcall = (
            fields.Datetime.now() - timedelta(minutes=10))
        self.crons["ir_cron_poll_video_ops"].active = False

        reason = self._progress()["stalled_reason"]

        self.assertIn("image render cron is more than 2 minutes overdue",
                      reason)
        self.assertIn("video (Veo) cron is switched off", reason)

    def test_a_tick_still_running_is_not_overdue(self):
        """Odoo moves nextcall only when a tick ends, so a long render tick
        reads as late unless its held lock is asked about."""
        self.generator.sop_gen_state = "done"
        self._draft(image_state="pending")
        self.crons["ir_cron_render_pending_images"].nextcall = (
            fields.Datetime.now() - timedelta(minutes=10))
        with _cron_tick_is_running(self.env, ADVISORY_LOCK_IMAGE_RENDER):
            self.assertFalse(self._progress()["stalled"])
        self.assertTrue(self._progress()["stalled"])

    def test_an_off_cron_with_no_work_is_not_a_stall(self):
        self.generator.sop_gen_state = "done"
        self._draft(image_state="rendered")
        for cron in self.crons.values():
            cron.active = False
        self.assertFalse(self._progress()["stalled"])

    # ── the retry action ───────────────────────────────────────────────────

    def test_retry_requeues_only_failed_drafts_and_keeps_their_images(self):
        kept = json.dumps([{"slot": "a", "label": "A",
                            "url": "https://example.com/a.png"}])
        failed = self._draft(image_state="failed", image_render_attempts=3,
                             images_json=kept)
        rendered = self._draft(image_state="rendered")

        result = (failed | rendered).action_retry_image_render()

        self.assertEqual(result["params"]["type"], "success")
        self.assertEqual(failed.image_state, "pending")
        self.assertEqual(failed.image_render_attempts, 0)
        self.assertEqual(failed.images_json, kept,
                         "a slot that rendered was paid for and is kept")
        self.assertEqual(rendered.image_state, "rendered")
        self.assertEqual(
            rendered.action_retry_image_render()["params"]["type"], "warning")

    # ── the SOP cron stamps the run window ─────────────────────────────────

    def _run_cron(self, side_effect):
        # Only this generator is in the queue, whatever the copy holds.
        self.Prompt.search([
            ("sop_gen_state", "in", ("queued", "generating")),
            ("id", "!=", self.generator.id)]).write({"sop_gen_state": "idle"})
        stale = self.now - timedelta(days=1)
        self.generator.write({"sop_gen_state": "queued", "state": "generating",
                              "sop_gen_started_at": stale,
                              "sop_gen_finished_at": stale})
        with patch.object(vertex, "generate_questions_from_sop",
                          side_effect=side_effect), \
                patch.object(self.env.cr, "commit", self.env.flush_all), \
                patch.object(self.env.cr, "rollback", lambda: None), \
                mute_logger("odoo.addons.assessments_be_v2.models.prompt"):
            self.Prompt._cron_generate_from_sop()
        return stale

    def test_the_cron_stamps_the_start_and_the_finish(self):
        seen = {}

        def author(env, prompt, **kw):
            seen.update(state=prompt.sop_gen_state,
                        started=prompt.sop_gen_started_at,
                        finished=prompt.sop_gen_finished_at)
            kw["report"].update(returned=1, created=1, rejected=0, reasons=[])
            return [self._draft().id]

        stale = self._run_cron(author)

        self.assertEqual(seen["state"], "generating")
        self.assertGreater(seen["started"], stale)
        self.assertFalse(seen["finished"],
                         "the previous run's finish must not survive the start")
        self.assertEqual(self.generator.sop_gen_state, "done")
        self.assertGreaterEqual(self.generator.sop_gen_finished_at,
                                self.generator.sop_gen_started_at)

    def test_a_crashed_run_is_finished_as_failed(self):
        def boom(env, prompt, **kw):
            raise RuntimeError("model exploded")

        stale = self._run_cron(boom)

        self.assertEqual(self.generator.sop_gen_state, "failed")
        self.assertTrue(self.generator.sop_gen_finished_at)
        self.assertGreater(self.generator.sop_gen_finished_at, stale)

    # ── a failed run says why, in the error AND the chatter ────────────────

    def _chatter(self):
        return " ".join(self.generator.message_ids.mapped("body"))

    def test_a_run_with_no_model_configured_names_the_setting(self):
        """No Vertex credential read as "the model returned 0 item(s)" under a
        "Generation complete" chatter line: the config error was caught as an
        unreadable reply, then its reason overwritten. The real service runs
        here; it must stop before the wire."""
        ICP = self.env["ir.config_parameter"].sudo()
        for key in ("vertex_api_key", "vertex_access_token",
                    "vertex_service_account_json"):
            ICP.set_param("assessments_be_v2.%s" % key, "")
        self.Prompt.search([
            ("sop_gen_state", "in", ("queued", "generating")),
            ("id", "!=", self.generator.id)]).write({"sop_gen_state": "idle"})
        self.generator.write({"source_text": "A SOP body.",
                              "sop_gen_state": "queued",
                              "state": "generating"})
        with patch.object(vertex, "_side_cursor_is_safe",
                          return_value=False), \
                patch.object(vertex, "_httpx",
                             side_effect=AssertionError("no network")), \
                patch.object(self.env.cr, "commit", self.env.flush_all), \
                patch.object(self.env.cr, "rollback", lambda: None), \
                self.assertLogs("odoo.addons.assessments_be_v2.models.prompt",
                                logging.ERROR) as logs:
            self.Prompt._cron_generate_from_sop()

        self.assertEqual(self.generator.sop_gen_state, "failed")
        self.assertNotEqual(self.generator.state, "generating",
                            "the stage bar must not keep saying Generating")
        error = self.generator.sop_gen_error
        self.assertIn("not configured", error)
        self.assertIn("Settings > Assessments v2 > Vertex AI", error)
        self.assertIn("not configured", "\n".join(logs.output))
        self.assertIn("Generation failed", self._chatter())
        self.assertIn("not configured", self._chatter())
        self.assertNotIn("Generation complete", self._chatter())

    def test_a_run_that_made_no_drafts_is_not_reported_complete(self):
        def nothing(env, prompt, **kw):
            kw["report"].update(returned=0, created=0, rejected=0,
                                no_items=True, reasons=["The reply was cut."])
            return []

        self._run_cron(nothing)

        self.assertEqual(self.generator.sop_gen_state, "failed")
        self.assertIn("Generation failed", self._chatter())
        self.assertIn("The reply was cut.", self._chatter())
        self.assertNotIn("Generation complete", self._chatter())

    def test_an_unreadable_reply_keeps_its_reason(self):
        """The parse error was recorded, then overwritten by "returned 0
        item(s)" - the one line that said why was the one thrown away."""
        self.generator.source_text = "A SOP body."
        report = {}
        with patch.object(vertex, "_call_vertex",
                          return_value="no json here"), \
                self.assertLogs(vertex._logger.name,
                                logging.WARNING) as logs:
            ids = vertex.generate_questions_from_sop(
                self.env, self.generator, report=report)

        self.assertEqual(ids, [])
        self.assertTrue(report["no_items"])
        self.assertTrue(
            any("Could not parse" in r for r in report["reasons"]), report)
        self.assertIn("Could not parse", "\n".join(logs.output))

    def test_a_failed_self_heal_keeps_the_base_batch(self):
        """Self-heal is best effort: when it raises, the model's own items go
        on to drafting; a rewritten SOP reference is logged."""
        self.generator.source_text = "A SOP body."
        reply = json.dumps([{
            "name": "Capital", "question_type": "mcq",
            "prompt": "Which city is the capital of France?",
            "options": ["Paris", "Lyon"], "correct": ["Paris"]}])
        with patch.object(vertex, "_call_vertex", return_value=reply), \
                patch.object(vertex, "_selfheal_generation",
                             side_effect=RuntimeError("heal broke")), \
                patch.object(vertex, "_selfheal_enabled", return_value=True), \
                patch.object(vertex, "_rewrite_source_references",
                             return_value=1), \
                self.assertLogs(vertex._logger.name, logging.INFO) as logs:
            ids = vertex.generate_questions_from_sop(
                self.env, self.generator, report={})

        self.assertTrue(ids, "the base batch was drafted")
        text = "\n".join(logs.output)
        self.assertIn("self-heal layer failed", text)
        self.assertIn("rewrote 1 SOP reference", text)

    def test_a_bearer_with_no_project_names_the_project(self):
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.vertex_project_id", "")
        with patch.object(vertex, "_vertex_bearer", return_value="token"), \
                self.assertRaises(vertex.VertexNotConfiguredError) as caught:
            vertex._gemini_request(self.env, "gemini-x", "generateContent")
        self.assertIn("project ID", str(caught.exception))

    def test_every_terminal_verdict_carries_a_finish(self):
        for draft_count, cancel in ((3, False), (0, False), (3, True)):
            with self.subTest(draft_count=draft_count, cancel=cancel):
                self.generator.sop_gen_cancel_requested = cancel
                vals = self.Prompt._sop_gen_result_vals(
                    draft_count, report={}, prompt=self.generator)
                self.assertTrue(vals["sop_gen_finished_at"])

    def test_a_kill_of_a_queued_run_finishes_it(self):
        self.generator.write({"sop_gen_state": "queued",
                              "state": "generating"})
        self.generator.action_cancel_generation()
        self.assertEqual(self.generator.sop_gen_state, "cancelled")
        self.assertTrue(self.generator.sop_gen_finished_at)


@tagged("-at_install", "post_install")
class TestGenerationProgressRoutes(_Fixture, HttpCase):

    def setUp(self):
        super().setUp()
        self.authenticate("admin", "admin")

    def _post(self, path):
        response = self.url_open(path, data=json.dumps({}), headers=_JSON,
                                 timeout=30)
        return response.status_code, response.json()

    def test_progress_answers_for_a_generator_and_404s_otherwise(self):
        self.generator.sop_gen_state = "queued"
        status, payload = self._post(
            "/api/v1/generators/%d/progress" % self.generator.id)
        self.assertEqual(status, 200, payload)
        data = payload["data"]
        self.assertEqual(data["generator_id"], self.generator.id)
        self.assertEqual(data["phase"], "queued")
        self.assertTrue(data["show_cost"], "admin passes the operator check")
        self.assertEqual(set(data), {
            "generator_id", "phase", "active", "summary", "stalled",
            "stalled_reason", "next_generation_run_at", "run", "drafts",
            "images", "videos", "media", "failed_images", "can_retry_images",
            "show_cost"})

        status, payload = self._post("/api/v1/generators/0/progress")
        self.assertEqual(status, 404)
        self.assertEqual(payload["error"]["code"], "not_found")

    def test_the_generator_row_carries_the_run_window(self):
        self.generator.sop_gen_started_at = self.now
        status, payload = self._post(
            "/api/v1/generators/%d" % self.generator.id)
        self.assertEqual(status, 200, payload)
        self.assertTrue(payload["data"]["sop_gen_started_at"].endswith("Z"))
        self.assertIsNone(payload["data"]["sop_gen_finished_at"])

    def test_draft_retry_refuses_with_nothing_failed_then_requeues(self):
        kept = json.dumps([{"slot": "a", "url": "https://example.com/a.png"}])
        draft = self._draft(image_state="rendered", images_json=kept)
        path = "/api/v1/drafts/%d/retry_images" % draft.id

        status, payload = self._post(path)
        self.assertEqual(status, 409, payload)
        self.assertEqual(payload["error"]["code"], "not_applicable")
        self.assertEqual(draft.image_state, "rendered")

        draft.write({"image_state": "failed", "image_render_attempts": 3})
        status, payload = self._post(path)
        self.assertEqual(status, 200, payload)
        draft.invalidate_recordset()
        self.assertEqual(draft.image_state, "pending")
        self.assertEqual(draft.image_render_attempts, 0)
        self.assertEqual(draft.images_json, kept)

    def test_generator_retry_refuses_with_nothing_failed_then_counts(self):
        path = ("/api/v1/generators/%d/retry_failed_images"
                % self.generator.id)
        rendered = self._draft(image_state="rendered")
        # A failure from an earlier run: not in progress's `images.failed`,
        # so not retried by the button that shows that count.
        earlier = self._draft(image_state="failed")
        self._backdate(earlier, self.now - timedelta(hours=2))
        self.generator.sop_gen_started_at = self.now - timedelta(minutes=10)

        status, payload = self._post(path)
        self.assertEqual(status, 409, payload)
        self.assertEqual(payload["error"]["code"], "not_applicable")

        failed = self._draft(image_state="failed") | self._draft(
            image_state="failed")
        self.assertEqual(self._progress()["images"]["failed"], 2)
        status, payload = self._post(path)
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"], {"retried": 2},
                         "the count progress showed is what was retried")
        (failed | rendered | earlier).invalidate_recordset()
        self.assertEqual(set(failed.mapped("image_state")), {"pending"})
        self.assertEqual(rendered.image_state, "rendered")
        self.assertEqual(earlier.image_state, "failed")

        status, _payload = self._post(
            "/api/v1/generators/0/retry_failed_images")
        self.assertEqual(status, 404)
