# -*- coding: utf-8 -*-
"""swe-grading-12 - a web write never lands on a row a grading lane holds.

Odoo cursors run REPEATABLE READ, so a web request that COMMITS a row a lane
is holding mid-call hands that lane a SerializationFailure: its transaction is
rolled back and the Vertex calls it already paid for are discarded. So these
writers consult `_being_graded()`, as every scoring button does:

  * "Release Results" (cohort, and one or more rows) skips a candidate being
    graded and says so;
  * a `subjective_threshold` change defers its recompute to the cron while a
    lane runs.

And `_llm_score_start` does not re-write `llm_state` on a row already
`scoring` (the lane committed it; `cr.commit()` clears the env cache, so a
second UPDATE would hold the row's lock for the whole call).

A skipped candidate loses nothing: their marks are not final yet, and the next
click (a minute later) releases them.
"""
from odoo.tests.common import TransactionCase, tagged

from .test_a_running_lane_keeps_what_it_holds import a_lane_is_running
from .test_individual_scoring_stays_individual import _Paper


@tagged("-at_install", "post_install")
class TestReleaseLeavesAGradedCandidateToItsLane(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.busy = self._candidate(1, scored={0: 70}, requested=True)
        self.busy.llm_state = "scoring"
        self.idle = self._candidate(1, scored={0: 80})

    def test_the_button_asks_before_it_reveals_anything(self):
        # `action_release_all_results` is the BUTTON: it opens the counted
        # confirm dialog and writes nothing. `action_confirm_release` is the
        # write, which is what the console route and the dialog both call.
        action = self.paper.action_release_all_results()

        self.assertEqual(action["res_model"], "assessments.be.release.wizard")
        self.assertFalse(self.busy.results_released)
        self.assertFalse(self.idle.results_released)

    def test_the_cohort_release_skips_the_candidate_being_graded(self):
        with a_lane_is_running(self.env):
            result = self.paper.action_confirm_release()
        self.assertFalse(
            self.busy.results_released,
            "releasing into a row a lane holds discards its paid results")
        self.assertTrue(self.idle.results_released)
        self.assertEqual(result["release"], {"released": 1, "skipped": 1})
        self.assertIn("being graded right now", result["params"]["message"])

    def test_a_single_release_skips_it_too(self):
        with a_lane_is_running(self.env):
            result = (self.busy | self.idle).action_release_results()
        self.assertFalse(self.busy.results_released)
        self.assertTrue(self.idle.results_released)
        self.assertEqual(result["release"], {"released": 1, "skipped": 1})

    def test_releasing_only_busy_candidates_refuses_and_says_why(self):
        self.idle.results_released = True
        with a_lane_is_running(self.env), \
                self.assertRaisesRegex(Exception, "being graded right now"):
            self.paper.action_confirm_release()
        self.assertFalse(self.busy.results_released)

    def test_with_no_lane_running_everything_is_released_as_before(self):
        result = self.paper.action_confirm_release()
        self.assertTrue(self.busy.results_released)
        self.assertTrue(self.idle.results_released)
        self.assertEqual(result["release"]["skipped"], 0)


@tagged("-at_install", "post_install")
class TestAThresholdChangeDefersWhileALaneRuns(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.busy = self._candidate(1, scored={0: 70}, requested=True)
        self.busy.llm_state = "scoring"

    def test_the_recompute_is_deferred_to_the_cron(self):
        with a_lane_is_running(self.env):
            self.paper.subjective_threshold = 55.0
        self.assertTrue(
            self.paper.threshold_recompute_pending,
            "the inline recompute rewrites answers a lane is holding; it has "
            "to wait for the cron like an oversized cohort does")

    def test_with_no_lane_running_it_recomputes_inline_as_before(self):
        self.paper.subjective_threshold = 55.0
        self.assertFalse(self.paper.threshold_recompute_pending)


@tagged("-at_install", "post_install")
class TestTheScoringMarkIsWrittenOnce(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_a_second_start_on_an_already_scoring_row_writes_nothing(self):
        ev = self._candidate(1, requested=True)
        ev._llm_score_start()
        self.env.flush_all()

        writes = []
        original = type(ev).write

        def counting_write(self, vals):
            writes.append(vals)
            return original(self, vals)

        type(ev).write = counting_write
        try:
            ev._llm_score_start()
        finally:
            type(ev).write = original
        self.assertEqual(
            writes, [],
            "the duplicate UPDATE held this row's lock across a Vertex call")
        self.assertEqual(ev.llm_state, "scoring")

    def test_it_still_clears_a_previous_error(self):
        ev = self._candidate(1, requested=True)
        ev.write({"llm_state": "scoring", "llm_error": "boom"})
        ev._llm_score_start()
        self.assertFalse(ev.llm_error)

    def test_it_still_refuses_an_unsubmitted_attempt(self):
        ev = self._candidate(1)
        ev.state = "in_progress"
        with self.assertRaises(Exception):
            ev._llm_score_start()
