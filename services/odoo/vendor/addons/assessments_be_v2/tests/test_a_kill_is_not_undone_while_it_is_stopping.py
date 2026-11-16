# -*- coding: utf-8 -*-
"""Kill Scoring keeps refusing until it has actually stopped - and stops then.

THE FLAG IS THE WHOLE MECHANISM. `action_kill_scoring` leaves
`scoring_cancel_requested` raised so the calls a lane has already dispatched
are refused at their checkpoint. So:

  swe-grading-8 / qa-backend-api-2 - a click alone never withdraws the kill.
  While a lane is still stopping, a click that would queue is refused
  ("still stopping", S1), whichever candidate it names; otherwise only a click
  that actually queues or resets something withdraws it, so a reset of 0
  answers leaves it up. An un-killed run in flight bills its next call.

  qa-backend-api-3 - the kill lowers its own flag once nothing is held, even
  when every caught call SUCCEEDED; a flag left up parks the next candidate to
  submit "cancelled by an admin" without grading them.
"""
import json

from odoo.tests.common import HttpCase, TransactionCase, tagged

from ..models.assessment import RescoreRefused
from .test_a_running_lane_keeps_what_it_holds import a_lane_is_running
from .test_individual_scoring_stays_individual import _JSON, _Paper


@tagged("-at_install", "post_install")
class TestAKillIsNotUndoneWhileItIsStopping(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def _killed(self, ev, held=True):
        """A kill still stopping ``ev``: the flag up and the row `scoring`."""
        ev.write({"llm_state": "scoring" if held else "pending",
                  "scoring_requested": True})
        self.paper.scoring_cancel_requested = True
        return ev

    def test_a_click_that_queues_nothing_leaves_the_kill_up(self):
        asha = self._killed(self._candidate(2))
        with a_lane_is_running(self.env), \
                self.assertRaisesRegex(RescoreRefused, "still stopping"):
            asha.action_queue_llm_score()
        self.assertTrue(
            self.paper.scoring_cancel_requested,
            "the only candidate is being graded, so nothing was queued and "
            "nothing may un-kill the run")

    def test_a_reset_that_resets_nothing_leaves_the_kill_up(self):
        asha = self._killed(self._candidate(2, scored={0: 40, 1: 50}),
                            held=False)
        result = asha.action_reset_failed_scoring()
        self.assertEqual(result["reset"]["answers"], 0)
        self.assertTrue(self.paper.scoring_cancel_requested)

    def test_a_rescore_of_another_candidate_leaves_the_kill_up(self):
        held = self._killed(self._candidate(1))
        other = self._candidate(1, paper=self.paper)
        with a_lane_is_running(self.env):
            with self.assertRaisesRegex(RescoreRefused, "still stopping"):
                other.action_rescore_individually()
            self.assertTrue(
                self.paper.scoring_cancel_requested,
                "a lane is still stopping this paper; a click on a different "
                "candidate does not withdraw the kill")
        self.assertEqual(held.llm_state, "scoring")

    def test_a_reset_that_does_reset_something_still_withdraws_it(self):
        asha = self._killed(self._candidate(2, errored=(0,)), held=False)
        result = asha.action_reset_failed_scoring()
        self.assertEqual(result["reset"]["answers"], 1)
        self.assertFalse(
            self.paper.scoring_cancel_requested,
            "an admin asking for this answer again IS a withdrawal")

    def test_a_kill_that_has_finished_stopping_lowers_its_own_flag(self):
        self._killed(self._candidate(1), held=False)
        self.paper.scoring_cancel_requested = True

        self.env["assessments.be"]._clear_finished_scoring_kills()

        self.assertFalse(
            self.paper.scoring_cancel_requested,
            "nothing is left to refuse, so a candidate submitting now must "
            "not be parked 'cancelled by an admin'")

    def test_a_kill_still_holding_a_candidate_keeps_its_flag(self):
        self._killed(self._candidate(1))
        with a_lane_is_running(self.env):
            self.env["assessments.be"]._clear_finished_scoring_kills()
        self.assertTrue(self.paper.scoring_cancel_requested)

    def test_a_kill_reports_what_it_stopped_not_the_paper_s_history(self):
        """The counts an admin is shown are this click's, not a lifetime
        tally of every candidate ever cancelled on the paper."""
        asha = self._candidate(2, requested=True)
        self._answers(asha)[0].rescore_request_key = "abc"

        first = self.paper.action_kill_scoring()["kill"]
        self.assertEqual((first["settled"], first["cleared"]), (1, 1))

        second = self.paper.action_kill_scoring()["kill"]
        self.assertEqual(
            (second["settled"], second["cleared"]), (0, 0),
            "a second kill stopped nothing; the candidate cancelled by the "
            "first one is not this click's work")


@tagged("-at_install", "post_install")
class TestTheKillRouteReportsThisClick(_Paper, HttpCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.authenticate("admin", "admin")

    def _kill(self):
        response = self.url_open(
            "/api/v1/assessments/%s/kill_scoring" % self.paper.id,
            data=json.dumps({}), headers=_JSON, timeout=30)
        return response.status_code, response.json()

    def test_a_second_kill_reports_zero(self):
        asha = self._candidate(2, requested=True)
        self._answers(asha)[0].rescore_request_key = "abc"

        status, payload = self._kill()
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["settled_count"], 1)
        self.assertEqual(payload["data"]["cleared_count"], 1)

        status, payload = self._kill()
        self.assertEqual(status, 200, payload)
        self.assertEqual(
            (payload["data"]["settled_count"],
             payload["data"]["cleared_count"]), (0, 0),
            "nothing was stopped by this click, so 'Nothing to stop' is true")
