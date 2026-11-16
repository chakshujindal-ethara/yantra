# -*- coding: utf-8 -*-
"""A grading failure says WHICH candidate and WHICH answers, at a level that
can be alerted on - the post-deploy log watch depends on it.

  * A failed call's ERROR names the evaluator, the answer ids, the model, the
    call note, whether it was cached, and the thread (four calls interleave on
    `etp-grade` threads).
  * `_store_error` logs every branch, with ids: an answer going terminal at 0
    is ERROR, a failed re-grade that kept the old mark is WARNING.
  * Each refusal has its own WARNING tag (SPEND_CAP, GRADING_POOL_FULL); a
    KILL logs SCORING_STOPPED, because the candidate lands `cancelled`, not
    "left pending".
  * Cache create and refresh spend reach the "LLM usage" log stream, and the
    per-call line carries `cached=` (`in=` already includes cached tokens),
    `ev=` and `cache=`, so spend totalled from logs prices a cache HIT right.
"""
import logging
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from ..services import grading_cache
from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc
from .test_individual_scoring_stays_individual import _Paper
from .test_one_paper_cannot_starve_another import clear_the_queue

_SCORING = "odoo.addons.assessments_be_v2.services.scoring"
_VERTEX = "odoo.addons.assessments_be_v2.services.vertex"

# `logging.INFO`, never the string: Odoo registers its RUNBOT level under the
# NAME "INFO" (netsvc.py), so `assertLogs(level="INFO")` asks for level 25 and
# quietly misses every real INFO record.
_INFO = logging.INFO


@tagged("-at_install", "post_install")
class TestAGradingFailureNamesItsCandidate(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_a_failed_call_names_the_evaluator_its_answers_and_the_model(self):
        asha = self._candidate(2, requested=True)
        ids = self._answers(asha).ids
        _calls, judge = self._judge(error=RuntimeError("Vertex error [500]"))

        with judge, self.assertLogs(_SCORING, level="ERROR") as logged:
            asha._action_llm_score()

        failed = [l for l in logged.output
                  if "Scoring submission call failed" in l]
        self.assertTrue(failed)
        self.assertIn("ev=%s" % asha.id, failed[0])
        self.assertIn(str(ids[0]), failed[0])
        self.assertIn("note=submission(2)", failed[0])
        self.assertIn("thread=", failed[0])

    def test_an_answer_going_terminal_is_logged_at_error_with_its_ids(self):
        asha = self._candidate(1, requested=True)
        answer = self._answers(asha)[0]
        answer.llm_attempts = 2          # one try left
        _calls, judge = self._judge(error=RuntimeError("boom"))

        with judge, self.assertLogs(_SCORING, level="ERROR") as logged:
            asha._action_llm_score()

        self.assertEqual(answer.llm_state, "error")
        terminal = [l for l in logged.output if "ANSWER TERMINAL" in l]
        self.assertTrue(terminal, "the one event that needs a human")
        self.assertIn("resp=%s" % answer.id, terminal[0])
        self.assertIn("ev=%s" % asha.id, terminal[0])

    def test_a_failed_regrade_that_keeps_its_mark_is_logged(self):
        asha = self._candidate(1, scored={0: 70})
        answer = self._answers(asha)[0]
        answer.action_rescore_this_answer()
        _calls, judge = self._judge(error=RuntimeError("boom"))

        with judge, self.assertLogs(_SCORING, level="WARNING") as logged:
            asha._action_llm_score()

        self.assertEqual(answer.llm_raw_100, 70.0)
        self.assertTrue([l for l in logged.output if "RE-GRADE FAILED" in l])

    def test_a_spend_cap_refusal_is_a_warning_with_a_stable_tag(self):
        asha = self._candidate(1, requested=True)
        _calls, judge = self._judge(
            error=vertex_svc.VertexBudgetError("Daily LLM spend cap reached"))

        with judge, self.assertLogs(_SCORING, level="WARNING") as logged:
            asha._action_llm_score()

        capped = [l for l in logged.output if "SPEND_CAP" in l]
        self.assertTrue(capped, "a cap stopping all grading must be alertable")
        self.assertIn("evaluator %s" % asha.id, capped[0])
        self.assertEqual(self._answers(asha)[0].llm_attempts, 0,
                         "a refusal is still not a spent attempt")

    def test_a_full_pool_is_a_warning_of_its_own(self):
        from psycopg2.pool import PoolError
        deferred = scoring_svc._deferred_if_pool_full(
            PoolError("connection pool is full"))
        self.assertTrue(getattr(deferred, "pool_full", False))

        asha = self._candidate(1, requested=True)
        _calls, judge = self._judge(error=deferred)
        with judge, self.assertLogs(_SCORING, level="WARNING") as logged:
            asha._action_llm_score()
        self.assertTrue([l for l in logged.output if "GRADING_POOL_FULL" in l])

    def test_a_kill_says_stopped_not_left_pending(self):
        asha = self._candidate(1, requested=True)
        _calls, judge = self._judge(
            error=vertex_svc.VertexCancelledError("killed by an admin"))

        with judge, self.assertLogs(_SCORING, level=_INFO) as logged:
            asha._action_llm_score()

        stopped = [l for l in logged.output if "SCORING_STOPPED" in l]
        self.assertTrue(stopped, logged.output)
        self.assertNotIn("left pending", stopped[0],
                         "the candidate is parked `cancelled`, not left "
                         "waiting")
        self.assertIn("evaluator %s" % asha.id, stopped[0])
        self.assertEqual(asha.llm_state, "cancelled")


@tagged("-at_install", "post_install")
class TestTheLaneEndsItsTickOnTheDailyCap(_Paper, TransactionCase):
    """A cap that stops ALL grading is a lane-level fact, so the lane answers
    it once at the top of its tick instead of planning twenty candidates that
    cannot be graded and logging twenty identical INFO deferrals a minute."""

    def setUp(self):
        super().setUp()
        self._pin_settings()
        clear_the_queue(self.env)
        # `_trigger_scoring_lane` skips inactive crons; copies run with them off.
        cron = self.env.ref("assessments_be_v2.ir_cron_llm_auto_score")
        cron.sudo().active = True

    def test_the_tick_ends_at_once_and_says_so_at_warning(self):
        asha = self._candidate(1, requested=True)

        with patch.object(
                vertex_svc, "_check_spend",
                side_effect=vertex_svc.VertexBudgetError(
                    "Daily LLM spend cap $400.00 reached")), \
                patch.object(vertex_svc, "_call_vertex", side_effect=(
                    AssertionError("a capped lane must not call Vertex"))), \
                self.assertLogs(
                    "odoo.addons.assessments_be_v2.models.assessment",
                    level=logging.WARNING) as logged:
            self.env["assessments.be"]._cron_llm_auto_score(shard=0)

        self.assertTrue([l for l in logged.output if "SPEND_CAP daily" in l])
        self.assertEqual(self._answers(asha)[0].llm_state, "pending",
                         "nothing was planned, so nothing was spent")

    def test_a_full_tick_asks_its_own_cron_to_run_again(self):
        """At 20 candidates a tick the queue drains on the minute grid: a
        704-candidate paper spends ~35 minutes waiting for the clock."""
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.scoring_tick_limit", "1")
        self._candidate(1, requested=True)
        _calls, judge = self._judge()

        with judge, patch.object(
                type(self.env["assessments.be"]), "_trigger_scoring_lane"
                ) as triggered, patch.object(
                    self.env.cr, "commit", self.env.flush_all):
            self.env["assessments.be"]._cron_llm_auto_score(shard=0)

        triggered.assert_called_once()

    def test_the_trigger_reaches_this_lane_s_own_cron(self):
        cron = self.env.ref("assessments_be_v2.ir_cron_llm_auto_score")

        self.env["assessments.be"]._trigger_scoring_lane(0)

        self.assertTrue(
            self.env["ir.cron.trigger"].sudo().search_count(
                [("cron_id", "=", cron.id)]),
            "shard 0's drainer is the cron asked to run again")


@tagged("-at_install", "post_install")
class TestCacheSpendReachesTheUsageLog(TransactionCase):

    MODEL = "gemini-3.1-pro-preview"

    def _an_evaluator(self):
        paper = self.env["assessments.be"].create({"name": "Usage paper"})
        applicant = self.env["hr.applicant"].create(
            {"partner_name": "Usage candidate"})
        return self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id})

    def test_a_cache_create_is_logged_like_every_other_billed_call(self):
        with self.assertLogs(_VERTEX, level=_INFO) as logged:
            grading_cache._book(
                self.env, self.MODEL,
                {"operation": "scoring_cache_create", "note": "cache create"},
                5000, 5000, grading_cache.TTL_SECONDS)

        usage = [l for l in logged.output if "LLM usage" in l]
        self.assertTrue(usage, "cache spend was invisible to log-derived cost")
        self.assertIn("op=scoring_cache_create", usage[0])
        self.assertIn("cost=$", usage[0])

    def test_a_call_on_a_cache_says_so_and_names_its_candidate(self):
        ev = self._an_evaluator()
        with self.assertLogs(_VERTEX, level=_INFO) as logged:
            vertex_svc._log_usage(
                self.env, self.MODEL,
                {"promptTokenCount": 5120, "candidatesTokenCount": 900,
                 "cachedContentTokenCount": 4135},
                0, {"operation": "score_subjective", "evaluator_id": ev.id,
                    "note": "submission(8)"},
                cache=True)

        usage = [l for l in logged.output if "LLM usage" in l][0]
        self.assertIn("cached=4135", usage,
                      "`in=` already includes these; without the field a log "
                      "total prices a cache hit at full rate")
        self.assertIn("ev=%s" % ev.id, usage)
        self.assertIn("cache=yes", usage)
