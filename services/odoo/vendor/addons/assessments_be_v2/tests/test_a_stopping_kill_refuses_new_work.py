# -*- coding: utf-8 -*-
"""A Kill still stopping a lane refuses new work, and stops what it holds.

  S1 (G1-08, owner Q8) - a click that queues grading while Kill is
  `stopping` said "Queued", then the lane's next checkpoint parked it back
  to `cancelled`. Every such click is refused (409 `stopping`), nothing
  written.
  S2 (R1-02) - the held candidate's re-score keys outlived the kill and were
  graded and billed on the next tick.
  S3 (R1-01) - archive then restore during a run left the flag up, which
  reads as a Kill and cancelled the paper's queue.
  N6 (R1-05) - Kill said "Nothing to stop" while a lane was grading.
  N5 (G4-11), S5 (R7-01) - the routes' side of archived and cancelled papers.
"""
import json
from unittest.mock import patch

from odoo.tests.common import HttpCase, TransactionCase, tagged

from ..models.assessment import RescoreRefused
from ..services import vertex as vertex_svc
from .test_a_running_lane_keeps_what_it_holds import a_lane_is_running
from .test_individual_scoring_stays_individual import _JSON, _Paper


class _HeldKill(_Paper):
    """`busy` is held by a running lane under a raised kill; `idle` has one
    errored and one pending answer."""

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.busy = self._candidate(1, requested=True)
        self.busy.llm_state = "scoring"
        self.idle = self._candidate(2, errored=(0,))
        self.paper.scoring_cancel_requested = True

    def _assert_nothing_written(self):
        answers = self._answers(self.idle)
        self.assertFalse(self.idle.scoring_requested)
        self.assertEqual(answers.mapped("llm_state"), ["error", "pending"])
        self.assertFalse(any(answers.mapped("rescore_request_key")))
        self.assertEqual(self.paper.scoring_last_candidates, 0,
                         "not even the tally may be saved")
        self.assertTrue(self.paper.scoring_cancel_requested)


@tagged("-at_install", "post_install")
class TestAClickWhileKillIsStoppingIsRefused(_HeldKill, TransactionCase):

    def test_every_action_that_queues_grading_is_refused(self):
        clicks = {
            "Score All": self.paper.action_llm_score_all,
            "Retry Failed": self.paper.action_llm_score_failed,
            "queue": self.idle.action_queue_llm_score,
            "reset failed": self.idle.action_reset_failed_scoring,
            "requeue errored": self.idle.action_reset_errored_scoring,
            "re-score candidate": self.idle.action_rescore_individually,
            "re-score answer": self._answers(self.idle)[1]
            .action_rescore_this_answer,
        }
        with a_lane_is_running(self.env):
            self.assertEqual(self.paper.scoring_phase, "stopping")
            for name, click in clicks.items():
                with self.subTest(name), \
                        self.assertRaises(RescoreRefused) as caught:
                    click()
                self.assertEqual(caught.exception.code, "stopping", name)
                self.assertEqual(caught.exception.http_status, 409)
                self._assert_nothing_written()

    def test_the_same_click_works_once_the_lane_has_let_go(self):
        self.paper.action_llm_score_all()
        self.assertTrue(self.idle.scoring_requested)
        self.assertFalse(self.paper.scoring_cancel_requested)


@tagged("-at_install", "post_install")
class TestKillStopsWhatItsLaneHolds(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_kill_counts_the_candidate_being_graded(self):
        busy = self._candidate(1, requested=True)
        busy.llm_state = "scoring"
        with a_lane_is_running(self.env):
            result = self.paper.action_kill_scoring()
        self.assertEqual(result["kill"], {"settled": 0, "cleared": 0,
                                          "held": 1})
        self.assertNotEqual(result["params"]["title"], "Nothing to stop")
        self.assertIn("1 candidate(s) being graded now will stop at their "
                      "next call", result["params"]["message"])

    def test_a_killed_rescore_is_not_graded_on_the_next_tick(self):
        asha = self._candidate(2, scored={0: 40, 1: 40})
        answers = self._answers(asha)
        asha.action_rescore_individually(answers.question_id.ids)
        # Kill pressed while the lane held her: her next call is refused.
        self.paper.scoring_cancel_requested = True
        _calls, refused = self._judge(error=vertex_svc.VertexCancelledError(
            "Scoring was cancelled by an admin; this call was not made."))
        with refused:
            asha._action_llm_score()
        self.assertEqual(asha.llm_state, "cancelled")
        self.assertFalse(any(answers.mapped("rescore_request_key")))

        Assessment = self.env["assessments.be"]
        calls, judge = self._judge({answers[0].id: 90, answers[1].id: 90})
        with judge, patch.object(self.env.cr, "commit", self.env.flush_all):
            Assessment._clear_finished_scoring_kills()
            Assessment._cron_llm_auto_score(shard=0)
        self.assertEqual(calls, [], "a killed re-score was billed after all")
        self.assertEqual(answers.mapped("llm_raw_100"), [40.0, 40.0])

    def test_restoring_during_a_run_does_not_read_as_a_kill(self):
        held = self._candidate(1, requested=True)
        held.llm_state = "scoring"
        queued = self._candidate(1, requested=True)
        with a_lane_is_running(self.env), \
                patch.object(self.env.cr, "commit", self.env.flush_all):
            self.paper.write({"active": False})
            self.assertTrue(self.paper.scoring_cancel_requested)
            self.paper.write({"active": True})
            self.assertFalse(self.paper.scoring_cancel_requested)
            self.assertTrue(
                self.env["assessments.be"]._auto_score_eligible(queued))
        self.assertEqual((queued.llm_state, queued.scoring_requested),
                         ("pending", True))


@tagged("-at_install", "post_install")
class TestTheRoutesSayWhyNothingWasQueued(_HeldKill, HttpCase):

    def setUp(self):
        super().setUp()
        self.authenticate("admin", "admin")

    def _post(self, url, body):
        response = self.url_open(url, data=json.dumps(body), headers=_JSON,
                                 timeout=30)
        return response.status_code, response.json()

    def test_every_queueing_route_answers_409_stopping(self):
        calls = [
            ("/api/v1/scoring/queue", {"assessment_id": self.paper.id}),
            ("/api/v1/scoring/queue", {"evaluator_ids": [self.idle.id]}),
            ("/api/v1/scoring/requeue_errored",
             {"assessment_id": self.paper.id, "states": ["failed", "error"]}),
            ("/api/v1/attempts/%s/rescore" % self.idle.id, {}),
        ]
        with a_lane_is_running(self.env):
            for url, body in calls:
                status, payload = self._post(url, body)
                with self.subTest(url=url, body=body):
                    self.assertEqual(status, 409, payload)
                    self.assertEqual(payload["error"]["code"], "stopping")
        self._assert_nothing_written()

    def test_kill_reports_held_count(self):
        self.paper.scoring_cancel_requested = False
        with a_lane_is_running(self.env):
            status, payload = self._post(
                "/api/v1/assessments/%s/kill_scoring" % self.paper.id, {})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["held_count"], 1, payload)

    def test_a_rescore_on_an_archived_paper_is_409_archived(self):
        self.paper.scoring_cancel_requested = False
        self.paper.write({"active": False})
        status, payload = self._post(
            "/api/v1/attempts/%s/rescore" % self.idle.id, {})
        self.assertEqual(status, 409, payload)
        self.assertEqual(payload["error"]["code"], "archived")
        self.assertTrue(self.paper.scoring_cancel_requested,
                        "the archive's stop must not be lifted")

    def test_requeue_errored_refuses_a_cancelled_paper(self):
        self.paper.write({"scoring_cancel_requested": False,
                          "state": "cancelled"})
        status, payload = self._post(
            "/api/v1/scoring/requeue_errored",
            {"assessment_id": self.paper.id, "states": ["failed", "error"]})
        self.assertEqual(status, 422, payload)
        self.assertIn("cancelled", payload["error"]["message"])
        self.assertEqual(self._answers(self.idle)[0].llm_state, "error")
        self.assertFalse(self.idle.scoring_requested)
