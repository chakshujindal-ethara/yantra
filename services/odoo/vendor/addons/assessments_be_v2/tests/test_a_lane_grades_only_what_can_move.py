# -*- coding: utf-8 -*-
"""A grading lane spends only on work that can move, and says so honestly.

  S4 (R1-03, R2-01) - a full tick re-triggered at once even when every call
  was deferred, so a 429 storm became a tight loop.
  S5 (R7-01, G6-40, G6-41, R2-04) - paid grading still ran on cancelled
  papers and erased attempts.
  N4 (G1-17, R2-05) - the "Scored N/M" tally was rewritten on every click and
  jumped back to an old saved value on auto-scored papers.
  N5 (G4-11, G1-18, G1-19) - re-score on an archived paper, a key the grader
  can never take, and an unbounded id echo.
  Q6 - Postgres refusing a connection is a deferral, like a full pool.
"""
from datetime import timedelta
from unittest.mock import patch

from psycopg2 import OperationalError

from odoo import fields, tools
from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged

from ..models.assessment import RescoreRefused
from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc
from .test_individual_scoring_stays_individual import _Paper
from .test_one_paper_cannot_starve_another import clear_the_queue


class _Lane(_Paper):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.Assessment = self.env["assessments.be"]

    def _in_parallel(self):
        """`_drain_in_parallel` with each call on this test's cursor."""
        return patch.object(
            scoring_svc, "_grade_on_own_cursor",
            lambda registry, uid, ctx, job:
            scoring_svc._grade_outcome(self.env, job))

    def _picked(self):
        return self.Assessment._scoring_shard_evaluators(0, 1, limit=1000)


@tagged("-at_install", "post_install")
class TestADeferredTickWaitsForTheClock(_Lane, TransactionCase):

    def setUp(self):
        super().setUp()
        clear_the_queue(self.env)

    def test_a_tick_of_429s_does_not_re_trigger_its_lane(self):
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.scoring_tick_limit", "1")
        asha = self._candidate(1, requested=True)
        calls, judge = self._judge(
            error=vertex_svc.VertexQuotaError("Vertex quota exhausted [429]"))
        with judge, patch.object(
                type(self.Assessment), "_trigger_scoring_lane") as triggered, \
                patch.object(self.env.cr, "commit", self.env.flush_all):
            self.Assessment._cron_llm_auto_score(shard=0)
        self.assertEqual(len(calls), 1, "fixture guard: the tick was full")
        self.assertEqual(self._answers(asha).llm_state, "pending")
        triggered.assert_not_called()

    def test_the_parallel_drain_reports_what_it_stored(self):
        asha = self._candidate(1, requested=True)
        _calls, refused = self._judge(
            error=vertex_svc.VertexQuotaError("Vertex quota exhausted [429]"))
        _calls, judge = self._judge()
        with self._in_parallel(), \
                patch.object(self.env.cr, "commit", self.env.flush_all):
            with refused:
                self.assertEqual(
                    self.Assessment._drain_in_parallel(asha, workers=2), 0)
            with judge:
                self.assertEqual(
                    self.Assessment._drain_in_parallel(asha, workers=2), 1)


@tagged("-at_install", "post_install")
class TestNobodyPaysForACancelledPaperOrAnErasedAttempt(_Lane, TransactionCase):

    def test_the_lane_skips_a_cancelled_paper(self):
        queued = self._candidate(1, requested=True)
        keyed = self._candidate(1, scored={0: 40})
        self._answers(keyed).action_rescore_this_answer()
        self.assertEqual(self._picked() & (queued | keyed), queued | keyed,
                         "fixture guard: both are the lane's work")
        self.paper.state = "cancelled"
        self.assertFalse(self._picked() & (queued | keyed))
        self.paper.invalidate_recordset()
        self.assertEqual(self.paper.scoring_phase, "idle",
                         "a queue nobody will drain is not a live run")

    def test_the_lane_skips_an_erased_attempt(self):
        queued = self._candidate(1, requested=True)
        keyed = self._candidate(1, scored={0: 40})
        self._answers(keyed).action_rescore_this_answer()
        (queued | keyed).write({"pii_anonymized": True})
        self.assertFalse(self._picked() & (queued | keyed))

    def test_erasing_drops_a_queued_rescore(self):
        asha = self._candidate(1, scored={0: 75}, requested=True)
        answer = self._answers(asha)
        answer.action_rescore_this_answer()
        asha.action_erase_candidate_data()
        self.assertFalse(answer.rescore_request_key)
        self.assertFalse(asha.scoring_requested)
        self.assertEqual(answer.llm_raw_100, 75.0)

    def test_retry_and_queue_refuse_a_cancelled_paper(self):
        asha = self._candidate(2, errored=(0,))
        self.paper.state = "cancelled"
        for click in (asha.action_reset_failed_scoring,
                      asha.action_reset_errored_scoring,
                      asha.action_queue_llm_score,
                      asha.action_rescore_individually):
            with self.subTest(click.__name__), \
                    self.assertRaisesRegex(UserError, "cancelled"):
                click()
        self.assertEqual(self._answers(asha).mapped("llm_state"),
                         ["error", "pending"])
        self.assertFalse(asha.scoring_requested)
        self.assertFalse(any(
            self._answers(asha).mapped("rescore_request_key")))

    def test_the_queue_actions_leave_an_erased_attempt_alone(self):
        erased = self._candidate(1)
        erased.action_erase_candidate_data()
        other = self._candidate(1)
        result = (erased | other).action_queue_llm_score()
        self.assertEqual(result["queue"], {"queued": 1, "skipped": 1})
        self.assertFalse(erased.scoring_requested)
        self.paper.action_llm_score_all()
        self.assertFalse(erased.scoring_requested)


@tagged("-at_install", "post_install")
class TestARescoreIsRefusedOrTrimmedHonestly(_Lane, TransactionCase):

    def test_an_archived_paper_is_refused_before_anything_is_written(self):
        asha = self._candidate(1)
        self.paper.write({"active": False})
        with self.assertRaises(RescoreRefused) as caught:
            asha.action_rescore_individually()
        self.assertEqual(caught.exception.code, "archived")
        self.assertFalse(self._answers(asha).rescore_request_key)
        self.assertTrue(self.paper.scoring_cancel_requested,
                        "the archive's stop must not be lifted")

    def test_a_key_the_grader_can_never_take_is_dropped(self):
        asha = self._candidate(2, scored={0: 40, 1: 50})
        stale = self._answers(asha)[0]
        stale.action_rescore_this_answer()
        stale.question_id.question_type = "mcq"
        self.assertFalse(stale.needs_llm, "fixture guard")

        self.assertNotIn(asha, self._picked())
        self.assertFalse(stale.rescore_request_key)

    def test_not_on_attempt_names_ten_ids_at_most(self):
        asha = self._candidate(1)
        bogus = list(range(10 ** 9, 10 ** 9 + 15))
        with self.assertRaises(RescoreRefused) as caught:
            asha.action_rescore_individually(bogus)
        message = str(caught.exception)
        self.assertEqual(caught.exception.code, "not_on_attempt")
        self.assertIn(str(bogus[9]), message)
        self.assertNotIn(str(bogus[10]), message)
        self.assertIn("and 5 more", message)


@tagged("-at_install", "post_install")
class TestTheScoredTallyMovesOnlyForward(_Lane, TransactionCase):

    def test_a_second_click_writes_nothing(self):
        self._candidate(1, scored={0: 80})
        self.paper._remember_scoring_tally()
        Paper = type(self.paper)
        with patch.object(Paper, "write", autospec=True,
                          side_effect=Paper.write) as write:
            self.paper._remember_scoring_tally()
        write.assert_not_called()

    def test_an_auto_queued_submission_does_not_bring_back_an_old_tally(self):
        now = fields.Datetime.now()
        done = self._candidate(1, scored={0: 80})
        done.llm_scored_at = now
        self.paper.write({
            "scoring_last_scored": 1, "scoring_last_candidates": 3,
            "scoring_last_finished_at": now - timedelta(days=20)})
        # What the llm_auto_score submit hook does: queue, save no tally.
        self._candidate(1, requested=True)
        self.paper.invalidate_recordset()
        self.assertNotEqual(self.paper.scoring_phase, "idle")
        self.assertEqual(
            (self.paper.scoring_scored_count,
             self.paper.scoring_candidate_count,
             self.paper.scoring_finished_at), (1, 2, now))

    def test_a_forced_regrade_does_not_count_backwards(self):
        a = self._candidate(1, scored={0: 80})
        b = self._candidate(1, scored={0: 80})
        (a | b).write({"llm_state": "scored", "llm_scored_at":
                       fields.Datetime.now() - timedelta(hours=1)})
        (a | b).action_reset_failed_scoring(states=("scored",))
        self._answers(a).write({"llm_state": "scored", "llm_raw_100": 70.0})
        a.write({"llm_state": "scored", "scoring_requested": False,
                 "llm_scored_at": fields.Datetime.now()})
        self.paper.invalidate_recordset()
        self.assertNotEqual(self.paper.scoring_phase, "idle")
        self.assertEqual((self.paper.scoring_scored_count,
                          self.paper.scoring_candidate_count), (2, 2),
                         "one re-graded of two must not read 1/2 mid-run")


@tagged("-at_install", "post_install")
class TestPostgresRefusingAConnectionIsADeferral(_Lane, TransactionCase):

    def test_too_many_clients_waits_for_the_next_tick(self):
        asha = self._candidate(1, requested=True)
        refused = OperationalError(
            'connection to server at "db", port 5432 failed: FATAL:  sorry, '
            'too many clients already')
        with patch.object(self.env.registry, "cursor", side_effect=refused), \
                patch.object(vertex_svc, "_call_vertex",
                             side_effect=AssertionError("never reached")), \
                patch.object(self.env.cr, "commit", self.env.flush_all):
            stored = self.Assessment._drain_in_parallel(asha, workers=2)
        answer = self._answers(asha)
        self.assertEqual(stored, 0)
        self.assertEqual(answer.llm_state, "pending")
        self.assertFalse(answer.llm_attempts, "no attempt was spent")
        self.assertIn("too many clients", asha.llm_error or "")

    def test_reserved_slots_are_the_same_refusal(self):
        deferred = scoring_svc._deferred_if_pool_full(OperationalError(
            "FATAL:  remaining connection slots are reserved for roles with "
            "the SUPERUSER attribute"))
        self.assertIsInstance(deferred, vertex_svc.VertexQuotaError)
        self.assertTrue(deferred.pool_full)

    def test_any_other_database_error_is_not_a_deferral(self):
        broken = OperationalError("server closed the connection unexpectedly")
        self.assertIs(scoring_svc._deferred_if_pool_full(broken), broken)

    def test_prod_pool_keeps_the_default_four_calls(self):
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param("assessments_be_v2.scoring_parallel_calls", False)
        icp.set_param("assessments_be_v2.scoring_shards", "4")
        with patch.dict(tools.config._runtime_options, {"db_maxconn": 600}):
            self.assertEqual(self.Assessment._scoring_parallel_calls(), 4)
