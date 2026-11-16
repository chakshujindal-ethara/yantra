# -*- coding: utf-8 -*-
"""Two failures that both cost real money, pinned together because they share
one mechanism: `usage_ctx`.

WHY THIS FILE EXISTS.

  1. THE LEDGER LOST CALLS SILENTLY. `assessments.be.llm.usage.operation` is a
     Selection, and three call sites wrote values that were not in it -
     `locate_defect`, `draft_task_template` and `assign_question_skills`. The
     create raised, `_log_usage` swallows its own failures by design (a logging
     hiccup must not sink a paid generation), and the row vanished. Google still
     billed. Worse, `_check_budget` sums THIS TABLE to enforce the daily cap, so
     every lost row also raised the ceiling on the next call.

  2. THERE WAS NO WAY TO STOP A RUN. Generation executes inside a cron worker,
     so there is no process to signal and cancellation has to be cooperative:
     a flag, and a checkpoint at every point money leaves. `prompt_id` in
     `usage_ctx` is what scopes it to ONE generator, which is the same handle
     the ledger uses for attribution.

Nothing here calls Vertex. The gates are asserted directly, because the whole
point of both is to run BEFORE the HTTP request.
"""
import contextlib
import importlib.util
import io
import logging
import os
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase

from ..services import scoring as scoring_svc
from ..services import vertex
from .test_a_running_lane_keeps_what_it_holds import a_lane_is_running


class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Prompt = self.env["assessments.be.prompt"]
        self.Usage = self.env["assessments.be.llm.usage"]
        self.generator = self.Prompt.create(
            {"name": "Ledger fixture %s" % uuid4().hex[:6]})


class TestEveryOperationReachesTheLedger(_Base):
    """The Selection must accept every value any caller writes."""

    # The three that were being written and dropped, plus the video poll that
    # was not being written at all. Named literally rather than derived, so
    # deleting one from the model is a failure here and not a silent narrowing.
    PREVIOUSLY_LOST = ("locate_defect", "draft_task_template",
                       "assign_question_skills", "fetch_video_op")

    def test_the_operations_that_were_being_dropped_are_accepted_now(self):
        for operation in self.PREVIOUSLY_LOST:
            with self.subTest(operation=operation):
                row = self.Usage.create({"operation": operation})
                self.assertEqual(row.operation, operation)

    def test_every_operation_written_anywhere_is_on_the_model(self):
        """A grep-based guard against the bug class, not just its instances.

        The defect was never "these three values are wrong" - it was that
        adding a call site and forgetting the Selection costs money with no
        error anywhere. This reads the operations the services actually write
        and checks each against the field, so the NEXT one is caught here.
        """
        import os
        import re

        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        written = set()
        for folder in ("services", "models", "controllers"):
            base = os.path.join(root, folder)
            for dirpath, _dirs, files in os.walk(base):
                for name in files:
                    if not name.endswith(".py"):
                        continue
                    with open(os.path.join(dirpath, name), encoding="utf-8") as fh:
                        body = fh.read()
                    written.update(re.findall(
                        r'"operation"\s*:\s*"([a-z_]+)"', body))
                    written.update(re.findall(
                        r'\boperation\s*=\s*"([a-z_]+)"', body))
        # `ctx.get("operation") or "other"` and similar defaults are not call
        # sites; the two patterns above only match literal assignments.
        allowed = {code for code, _label
                   in self.Usage._fields["operation"].selection}
        missing = sorted(written - allowed)
        self.assertFalse(
            missing,
            "these operations are written by the code but are not on "
            "assessments.be.llm.usage, so their rows - and their cost - are "
            "silently discarded: %s" % ", ".join(missing))

    def test_an_unknown_operation_is_filed_rather_than_lost(self):
        """The backstop, for the call site that forgets anyway.

        A mislabelled row is recoverable; a missing one is not. The original
        name is kept in the note so the cost can still be attributed by hand.
        """
        values = vertex._ledger_values(
            self.env, "gemini-3-pro", {"promptTokenCount": 10},
            0, {"operation": "a_brand_new_lane", "note": "why"})

        self.assertEqual(values["operation"], "other")
        self.assertIn("a_brand_new_lane", values["note"])
        row = self.Usage.create(values)
        self.assertTrue(row.id, "the coerced row must be creatable")

    def test_a_failed_call_is_recorded_with_no_cost(self):
        """A 429 storm has to be visible somewhere other than the server log.

        The row carries the status in its note and zero tokens: the call was
        refused, so there is nothing to bill and nothing to pretend was
        billed.
        """
        vertex._log_failed_call(
            self.env, "gemini-3-pro",
            {"operation": "generate_questions",
             "prompt_id": self.generator.id, "note": "batch"},
            429, "RESOURCE_EXHAUSTED")

        row = self.Usage.search(
            [("prompt_id", "=", self.generator.id)], limit=1, order="id desc")
        self.assertTrue(row, "a refused call left no trace at all")
        self.assertEqual(row.cost_usd, 0.0)
        self.assertEqual(row.total_tokens, 0)
        self.assertIn("429", row.note)

    def test_attribution_survives_the_round_trip(self):
        """`prompt_id` is what makes a cost readable per generator - and it is
        also the handle the kill switch uses, so a lane that drops it loses
        both at once."""
        values = vertex._ledger_values(
            self.env, "gemini-3-pro",
            {"promptTokenCount": 100, "candidatesTokenCount": 50},
            0, {"operation": "generate_questions",
                "prompt_id": self.generator.id})
        row = self.Usage.create(values)

        self.assertEqual(row.prompt_id, self.generator)
        self.assertEqual(row.tokens_in, 100)
        self.assertEqual(row.tokens_out, 50)
        self.assertEqual(row.total_tokens, 150)
        self.assertGreater(row.cost_usd, 0.0)

    def test_a_row_records_how_long_its_call_took_and_which_try_it_was(self):
        """R10.3: the ledger answers "where does the time go" per operation.
        `attempt` is the HTTP try (1, or 2 for the re-ask), so a call's
        count is the highest over its rows."""
        clock = [1000.0]

        class _Reply:
            status_code = 200
            text = ""

            def json(self):
                return {"candidates": [{"finishReason": "STOP", "content": {
                    "parts": [{"text": '{"ok": true}'}]}}],
                    "usageMetadata": {"promptTokenCount": 10,
                                      "candidatesTokenCount": 5}}

        class _Client:
            def post(self, url, json=None, headers=None, **kw):
                clock[0] += 1.5
                return _Reply()

        with patch.object(vertex, "time", SimpleNamespace(
                    monotonic=lambda: clock[0])), \
                patch.object(vertex, "_vertex_creds", return_value=(
                    "p", "global", "gemini-3.1-pro-preview", "")), \
                patch.object(vertex, "_gemini_request",
                             return_value=("https://vertex.invalid", {})), \
                patch.object(vertex, "_httpx", return_value=_Client()), \
                patch.object(vertex, "_check_budget"), \
                patch.object(vertex, "_check_cancelled"), \
                patch.object(vertex, "_check_scoring_cancelled"), \
                self.assertLogs(vertex._logger.name, logging.INFO) as logs:
            vertex._call_vertex_single(
                self.env, "sys", "hi", response_json=True,
                usage_ctx={"operation": "draft_task_template",
                           "prompt_id": self.generator.id})

        # NOTE: needs `latency_ms` and `attempt` on models/llm_usage.py (BE-1).
        row = self.Usage.search(
            [("prompt_id", "=", self.generator.id)], limit=1, order="id desc")
        self.assertEqual((row.latency_ms, row.attempt), (1500, 1))
        self.assertTrue(
            any("LLM usage" in line and "ms=1500" in line
                for line in logs.output), logs.output)


    def test_a_retried_call_books_its_second_try(self):
        """A reply cut off at MAX_TOKENS is asked again with more room; the
        row of the answer that came back is try 2, timed on its own."""
        clock = [1000.0]
        replies = iter((
            {"candidates": [{"finishReason": "MAX_TOKENS",
                             "content": {"parts": []}}],
             "usageMetadata": {"promptTokenCount": 10}},
            {"candidates": [{"finishReason": "STOP", "content": {
                "parts": [{"text": '{"ok": true}'}]}}],
             "usageMetadata": {"promptTokenCount": 10,
                               "candidatesTokenCount": 5}}))

        class _Reply:
            status_code = 200
            text = ""

            def __init__(self, body):
                self.body = body

            def json(self):
                return self.body

        class _Client:
            def post(self, url, json=None, headers=None, **kw):
                clock[0] += 2.25
                return _Reply(next(replies))

        with patch.object(vertex, "time", SimpleNamespace(
                    monotonic=lambda: clock[0])), \
                patch.object(vertex, "_vertex_creds", return_value=(
                    "p", "global", "gemini-3.1-pro-preview", "")), \
                patch.object(vertex, "_gemini_request",
                             return_value=("https://vertex.invalid", {})), \
                patch.object(vertex, "_httpx", return_value=_Client()), \
                patch.object(vertex, "_check_budget"), \
                patch.object(vertex, "_check_cancelled"), \
                patch.object(vertex, "_check_scoring_cancelled"):
            vertex._call_vertex_single(
                self.env, "sys", "hi", response_json=True,
                usage_ctx={"operation": "draft_task_template",
                           "prompt_id": self.generator.id})

        rows = self.Usage.search(
            [("prompt_id", "=", self.generator.id)], order="id")
        self.assertEqual(rows.mapped("attempt"), [1, 2])
        self.assertEqual(rows[-1].latency_ms, 2250)

    def test_the_cost_tool_says_when_the_ledger_is_empty(self):
        path = os.path.join(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))), "tools", "llm_cost_model.py")
        spec = importlib.util.spec_from_file_location("be_v2_cost_tool", path)
        tool = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(tool)
        self.env.flush_all()
        self.env.cr.execute("DELETE FROM assessments_be_llm_usage")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            tool.operations_table(self.env.cr)
        self.assertIn("(no billed calls in this ledger)", out.getvalue())

    def test_the_cost_tool_lists_an_operation_with_no_averages(self):
        """`tools/llm_cost_model.py --measure` died on a TypeError when an
        operation had no output, thinking, latency or cost on record."""
        path = os.path.join(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))), "tools", "llm_cost_model.py")
        spec = importlib.util.spec_from_file_location("be_v2_cost_tool", path)
        tool = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(tool)
        self.env.cr.execute("DELETE FROM assessments_be_llm_usage "
                            "WHERE operation = 'map_similarity'")
        row = self.Usage.create({"operation": "map_similarity",
                                 "tokens_in": 10})
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be_llm_usage SET tokens_out = NULL, "
            "thoughts_tokens = NULL, cost_usd = NULL, latency_ms = NULL "
            "WHERE id = %s", (row.id,))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            tool.operations_table(self.env.cr)
        line = next(x for x in out.getvalue().splitlines()
                    if "map_similarity" in x)
        self.assertIn("$  0.0000", line)


class TestTheKillSwitchStopsOneGeneratorOnly(_Base):
    """Cancellation is cooperative, scoped by `prompt_id`, and keeps drafts."""

    def _drafts(self, generator, **vals):
        return self.env["assessments.be.prompt.question"].create(dict({
            "prompt_id": generator.id,
            "name": "Draft %s" % uuid4().hex[:6],
            "question_type": "mcq",
        }, **vals))

    def test_a_cancelled_generator_refuses_its_next_call(self):
        self.generator.sop_gen_cancel_requested = True

        with self.assertRaises(vertex.VertexCancelledError):
            vertex._check_cancelled(
                self.env, {"prompt_id": self.generator.id})

    def test_a_healthy_generator_is_untouched(self):
        vertex._check_cancelled(self.env, {"prompt_id": self.generator.id})

    def test_the_kill_is_scoped_to_one_generator(self):
        """THE requirement: a second run must not be collateral damage."""
        other = self.Prompt.create({"name": "Bystander %s" % uuid4().hex[:6]})
        self.generator.sop_gen_cancel_requested = True

        with self.assertRaises(vertex.VertexCancelledError):
            vertex._check_cancelled(
                self.env, {"prompt_id": self.generator.id})
        vertex._check_cancelled(self.env, {"prompt_id": other.id})

    def test_scoring_a_candidate_is_never_cancelled_by_a_generator_kill(self):
        """The grading lane carries `evaluator_id` and no `prompt_id`.

        Pinned because the consequence would be severe and invisible: killing a
        generator must never abandon a submitted paper mid-grade.
        """
        self.generator.sop_gen_cancel_requested = True

        vertex._check_cancelled(self.env, {"operation": "score_subjective",
                                           "evaluator_id": 1})
        vertex._check_cancelled(self.env, {})

    def test_a_queued_run_is_settled_without_ever_starting(self):
        """Nothing has been spent yet, so there is nothing to wait for."""
        self.generator.write({"sop_gen_state": "queued", "state": "generating"})

        self.assertTrue(self.generator.action_cancel_generation())

        self.assertEqual(self.generator.sop_gen_state, "cancelled")
        self.assertFalse(
            self.generator.sop_gen_cancel_requested,
            "the flag must be cleared once the run has stopped, or the "
            "generator can never generate again")
        self.assertEqual(self.generator.state, "draft")

    def test_a_running_run_is_flagged_and_left_for_the_checkpoint(self):
        """It cannot be settled here: a cron worker is inside it."""
        self.generator.write(
            {"sop_gen_state": "generating", "state": "generating"})

        self.assertTrue(self.generator.action_cancel_generation())

        self.assertTrue(self.generator.sop_gen_cancel_requested)
        self.assertEqual(
            self.generator.sop_gen_state, "generating",
            "the state moves when the run actually stops, not when it is asked")

    def test_killing_an_idle_generator_reports_that_nothing_ran(self):
        self.assertFalse(self.generator.action_cancel_generation())
        self.assertFalse(self.generator.sop_gen_cancel_requested)

    def test_settling_keeps_every_draft(self):
        """The promise the button makes, and the reason it is not a rollback.

        The money that produced these drafts is spent whether they are kept or
        not, so discarding them on the admin's behalf destroys work they paid
        for and might want.
        """
        kept = self._drafts(self.generator)
        self.generator.write(
            {"sop_gen_state": "generating", "state": "generating"})
        self.generator.sop_gen_cancel_requested = True

        self.generator._settle_generation_cancelled("test")

        self.assertTrue(kept.exists())
        self.assertEqual(kept.prompt_id, self.generator)
        self.assertEqual(self.generator.sop_gen_state, "cancelled")

    def test_settling_stops_media_that_has_not_been_paid_for_yet(self):
        """The expensive tail. Authoring is one call; a render per draft and a
        Veo submission per clip are what a kill is really for."""
        pending = self._drafts(self.generator, image_state="pending")
        rendered = self._drafts(self.generator, image_state="rendered")
        submitted = self._drafts(self.generator, video_state="generating")

        self.generator._settle_generation_cancelled("test")

        self.assertEqual(pending.image_state, "cancelled")
        self.assertEqual(submitted.video_state, "cancelled")
        self.assertEqual(
            rendered.image_state, "rendered",
            "a picture already rendered has been paid for and must be kept")

    def test_a_kill_during_finalizing_is_recorded_as_cancelled(self):
        """`finalizing` is a one-way trap: the drainer never re-selects it, so
        the run cannot be re-sent to Vertex. The right answer is therefore to
        let it finish and record the verdict, not to unwind it."""
        self.generator.write({"sop_gen_state": "finalizing",
                              "sop_gen_cancel_requested": True})

        vals = self.Prompt._sop_gen_result_vals(
            3, report={}, prompt=self.generator)

        self.assertEqual(vals["sop_gen_state"], "cancelled")
        self.assertFalse(vals["sop_gen_cancel_requested"])
        self.assertIn("Cancelled", vals["sop_gen_report"])

    def test_a_normal_finish_is_unaffected(self):
        """The same method, with the flag down, must still say 'done'."""
        vals = self.Prompt._sop_gen_result_vals(
            3, report={}, prompt=self.generator)

        self.assertEqual(vals["sop_gen_state"], "done")


class TestTheScoringKillStopsOneAssessmentOnly(_Base):
    """The scoring twin of the generator kill: cooperative, scoped by the
    assessment resolved from `evaluator_id`, and it keeps stored scores.

    Nothing here calls Vertex - the gate is asserted directly, because the
    whole point of it is to run BEFORE the HTTP request.
    """

    def _assessment(self):
        return self.env["assessments.be"].create({
            "name": "Kill scoring %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "duration_minutes": 30,
        })

    def _submitted_evaluator(self, assessment, *, scored=False):
        """A submitted evaluator with one subjective answer, optionally scored,
        queued for grading."""
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:8],
        })
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        q = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric",
            "prompt": "Describe",
            "generator_id": self.generator.id,
            "assessment_ids": [(4, assessment.id)],
        })
        self.env["assessments.be.response"].create({
            "assessment_evaluator_id": ev.id,
            "evaluator_id": applicant.id,
            "question_id": q.id,
            "assessment_id": assessment.id,
            "state": "submitted",
            "justification": "an answer",
            "llm_raw_100": 80.0 if scored else 0.0,
            "llm_state": "scored" if scored else "pending",
        })
        ev.write({"state": "submitted", "scoring_requested": True,
                  "llm_state": "pending"})
        return ev

    def test_kill_stops_a_queued_evaluator_and_parks_it(self):
        assessment = self._assessment()
        ev = self._submitted_evaluator(assessment)

        assessment.action_kill_scoring()

        self.assertFalse(
            ev.scoring_requested,
            "a killed run must clear scoring_requested so the drainer stops "
            "selecting the candidate")
        self.assertEqual(
            ev.llm_state, "cancelled",
            "a stopped candidate is parked in 'cancelled', distinguishable "
            "from a broken one")

    def test_the_flag_stays_raised_so_a_lane_in_flight_refuses(self):
        """THE REGRESSION THIS FILE EXISTS FOR.

        `action_kill_scoring` used to settle inline, and settling CLEARS the
        flag - so the column went up and back down inside one transaction and
        the request committed with it down. The grading lane reads it on a fresh
        cursor after that commit, saw False, and the candidate being graded at
        that moment kept calling Vertex. Kill emptied the queue and did not stop
        the spending, which is the one thing it is for.

        `scoring` is what "in flight" means: the drainer sets it immediately
        before the Vertex call, so it is the state a worker actually holds.
        """
        assessment = self._assessment()
        ev = self._submitted_evaluator(assessment)
        ev.llm_state = "scoring"

        with a_lane_is_running(self.env):
            assessment.action_kill_scoring()

        self.assertTrue(
            assessment.scoring_cancel_requested,
            "with a lane mid-call the flag must remain raised, or the "
            "checkpoint cannot see it and money keeps leaving")
        self.assertTrue(assessment.scoring_cancelled_at)

    def test_a_kill_with_nothing_in_flight_does_not_strand_the_flag(self):
        """The other half of the same rule.

        Holding the flag up when NOTHING is mid-call costs something real: the
        kill has just emptied the queue, and until a lane's tick lowers it
        (`_clear_finished_scoring_kills`) the flag would refuse the
        assessment's next legitimate run. Same reasoning as the generator
        settling a run still sitting in `queued` on the spot.
        """
        assessment = self._assessment()
        ev = self._submitted_evaluator(assessment)   # 'pending' - not held

        assessment.action_kill_scoring()

        self.assertEqual(ev.llm_state, "cancelled")
        self.assertFalse(
            assessment.scoring_cancel_requested,
            "nothing was in flight, so nothing is left to refuse and the flag "
            "must not be left up with no tick coming to lower it")

    def test_a_real_kill_refuses_the_next_grading_call(self):
        """End-to-end, through the button rather than by setting the column.

        The other checkpoint tests raise the flag by hand, so they passed while
        `action_kill_scoring` was lowering it again. This one goes through the
        action, which is the path an operator actually takes.
        """
        assessment = self._assessment()
        ev = self._submitted_evaluator(assessment)
        ev.llm_state = "scoring"

        with a_lane_is_running(self.env):
            assessment.action_kill_scoring()

        with self.assertRaises(
                vertex.VertexCancelledError,
                msg="after Kill Scoring, the next billable grading call for "
                    "that assessment must be refused"):
            vertex._check_scoring_cancelled(
                self.env, {"evaluator_id": ev.id})

    def test_the_cron_lowers_the_flag_once_the_queue_is_settled(self):
        """The flag is lowered by the settle, not by the button."""
        assessment = self._assessment()
        ev = self._submitted_evaluator(assessment)
        ev.llm_state = "scoring"
        with a_lane_is_running(self.env):
            assessment.action_kill_scoring()
        self.assertTrue(assessment.scoring_cancel_requested)

        # The lane has stopped; the drainer's next settle finds nothing held.
        assessment._settle_scoring_cancelled("the drainer found it flagged")

        self.assertFalse(
            assessment.scoring_cancel_requested,
            "the settle is what lowers the flag - leaving it up would freeze "
            "the assessment forever")

    def test_asking_to_score_again_withdraws_the_kill(self):
        """A kill with a lane still in flight leaves the flag up, so asking to
        score again has to withdraw it - or the raised flag would refuse the
        run the admin just asked for.
        """
        assessment = self._assessment()
        held = self._submitted_evaluator(assessment)
        held.llm_state = "scoring"
        with a_lane_is_running(self.env):
            assessment.action_kill_scoring()
        self.assertTrue(assessment.scoring_cancel_requested)

        # A fresh candidate to give Score All something to queue.
        revived = self._submitted_evaluator(assessment)
        assessment.action_llm_score_all()

        self.assertFalse(
            assessment.scoring_cancel_requested,
            "requesting a score is an admin withdrawing the kill")
        self.assertTrue(
            revived.scoring_requested,
            "and the new run must actually be queued")

    def test_requeueing_one_attempt_withdraws_a_raised_kill(self):
        """THE SECOND REGRESSION. `_withdraw_scoring_kill` was wired only into
        the assessment-level actions, so re-queueing a SINGLE candidate - which
        is what `POST /scoring/queue` with `evaluator_ids` and the per-attempt
        rescore route both do - left a raised flag up. The cron then found the
        stale flag on its next tick and settled the row straight back to
        'cancelled': the admin's deliberate re-queue was silently undone while
        the button reported success.
        """
        assessment = self._assessment()
        held = self._submitted_evaluator(assessment)
        held.llm_state = "scoring"
        with a_lane_is_running(self.env):
            assessment.action_kill_scoring()
        self.assertTrue(assessment.scoring_cancel_requested)

        revived = self._submitted_evaluator(assessment)
        revived.action_queue_llm_score()

        self.assertFalse(
            assessment.scoring_cancel_requested,
            "queueing one candidate must withdraw the kill too, or the cron "
            "reverts the row to 'cancelled' on its next tick")
        self.assertTrue(revived.scoring_requested)

    def test_resetting_answers_withdraws_a_raised_kill(self):
        """The same hazard, reached through the per-attempt reset path.

        A RESET THAT ACTUALLY RESETS SOMETHING. The withdrawal used to happen
        on the click alone, before the busy check and before anything was
        written, so a click that reset 0 answers - or one aimed at another
        candidate entirely - un-killed a run that was still stopping
        (swe-grading-8). The hazard this test exists for is unchanged: the
        answers this reset sends back to `pending` must not be settled to
        'cancelled' by the next tick.
        """
        assessment = self._assessment()
        held = self._submitted_evaluator(assessment)
        held.llm_state = "scoring"
        with a_lane_is_running(self.env):
            assessment.action_kill_scoring()
        self.assertTrue(assessment.scoring_cancel_requested)

        other = self._submitted_evaluator(assessment)
        other.response_ids.write({"llm_state": "error", "llm_attempts": 3})
        result = other.action_reset_failed_scoring()

        self.assertEqual(result["reset"]["answers"], 1)
        self.assertFalse(
            assessment.scoring_cancel_requested,
            "a reset must withdraw the kill for the same reason a queue does")

    def test_a_reset_that_resets_nothing_leaves_a_raised_kill_alone(self):
        """swe-grading-8: the click is not the withdrawal - the work is."""
        assessment = self._assessment()
        held = self._submitted_evaluator(assessment)
        held.llm_state = "scoring"
        with a_lane_is_running(self.env):
            assessment.action_kill_scoring()

        other = self._submitted_evaluator(assessment)
        result = other.action_reset_failed_scoring()

        self.assertEqual(result["reset"]["answers"], 0)
        self.assertTrue(
            assessment.scoring_cancel_requested,
            "nothing was queued or reset, so the kill is still the last "
            "instruction an admin gave")

    def test_a_kill_mid_grade_parks_the_candidate_as_cancelled_not_failed(self):
        """A kill is an outcome somebody chose. Landing it in 'failed' would put
        an admin's own button beside genuine grader errors, and Score Failed
        Responses would then re-spend on the candidate they just stopped.
        """
        assessment = self._assessment()
        ev = self._submitted_evaluator(assessment)

        def _boom(env, evaluator):
            raise vertex.VertexCancelledError("killed by an admin")

        with patch.object(scoring_svc, "score_evaluator", _boom):
            ev._action_llm_score()

        self.assertEqual(
            ev.llm_state, "cancelled",
            "a cancelled grading run is not a failure")
        self.assertFalse(
            ev.scoring_requested,
            "and it must not sit queued for the drainer to pick up again")

    def test_stored_scores_survive_a_kill(self):
        assessment = self._assessment()
        scored = self._submitted_evaluator(assessment, scored=True)
        raw_before = scored.response_ids.mapped("llm_raw_100")

        assessment.action_kill_scoring()

        self.assertEqual(
            scored.response_ids.mapped("llm_raw_100"), raw_before,
            "a kill must never unwind a mark already stored")

    def test_an_unrelated_assessment_is_untouched(self):
        killed = self._assessment()
        bystander = self._assessment()
        ev_killed = self._submitted_evaluator(killed)
        ev_bystander = self._submitted_evaluator(bystander)

        killed.action_kill_scoring()

        self.assertEqual(ev_killed.llm_state, "cancelled")
        self.assertTrue(
            ev_bystander.scoring_requested,
            "a kill on one assessment must not stop another's grading")
        self.assertEqual(ev_bystander.llm_state, "pending")
        self.assertFalse(bystander.scoring_cancel_requested)

    def test_killing_an_idle_assessment_is_a_no_op_that_succeeds(self):
        """Idempotent: nothing queued, no exception, still reports success."""
        assessment = self._assessment()
        result = assessment.action_kill_scoring()
        self.assertEqual(result.get("type"), "ir.actions.client")

    # ------------------------------------------------------------------
    # The grading-lane checkpoint
    # ------------------------------------------------------------------
    def test_the_scoring_checkpoint_refuses_a_flagged_assessment(self):
        assessment = self._assessment()
        ev = self._submitted_evaluator(assessment)
        assessment.scoring_cancel_requested = True

        with self.assertRaises(vertex.VertexCancelledError):
            vertex._check_scoring_cancelled(
                self.env, {"evaluator_id": ev.id})

    def test_the_scoring_checkpoint_allows_an_unflagged_assessment(self):
        assessment = self._assessment()
        ev = self._submitted_evaluator(assessment)
        vertex._check_scoring_cancelled(self.env, {"evaluator_id": ev.id})

    def test_a_generator_kill_never_stops_scoring_and_vice_versa(self):
        """The two switches use distinct handles and must not cross."""
        assessment = self._assessment()
        ev = self._submitted_evaluator(assessment)
        # A generator kill (prompt_id) must not trip the scoring checkpoint.
        self.generator.sop_gen_cancel_requested = True
        vertex._check_scoring_cancelled(self.env, {"evaluator_id": ev.id})
        # And a scoring kill (evaluator_id) must not trip the generation one.
        assessment.scoring_cancel_requested = True
        vertex._check_cancelled(self.env, {"evaluator_id": ev.id})

    def test_the_cron_settles_a_flagged_assessment_without_a_vertex_call(self):
        """The cheap pre-run checkpoint: a killed assessment costs nothing on
        the next tick. The cron itself commits per item (so it cannot be driven
        from inside a TransactionCase), but its guard is a plain read + settle,
        which is exactly what this asserts: the flagged evaluator is still
        SELECTED by the drainer (so the guard runs), and settling it parks the
        candidate in 'cancelled' before any Vertex call could be made.
        """
        assessment = self._assessment()
        ev = self._submitted_evaluator(assessment)
        assessment.scoring_cancel_requested = True

        # The drainer must still hand the guard this evaluator - a flag alone
        # must not make it vanish from the queue, or the guard never runs.
        selected = self.env["assessments.be"]._scoring_shard_evaluators(0, 1)
        self.assertIn(
            ev, selected,
            "a flagged evaluator must still be selected so the cron's pre-run "
            "guard can settle it")

        # The guard's action: settle before any call. No Vertex is reached.
        assessment._settle_scoring_cancelled("cron pre-run guard")

        self.assertEqual(ev.llm_state, "cancelled")
        self.assertFalse(ev.scoring_requested)
        self.assertFalse(assessment.scoring_cancel_requested,
                         "settling clears the flag")
