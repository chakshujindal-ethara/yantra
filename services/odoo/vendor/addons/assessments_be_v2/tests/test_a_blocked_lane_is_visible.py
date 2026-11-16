# -*- coding: utf-8 -*-
"""A blocked scoring lane is visible, and "queued" means queued (W4 P0 b).

On 2026-09-30 shard 2 of 4 sat on a leaked advisory lock for 14 minutes with
20 candidates left. Its cron still ticked, so `nextcall` moved and the health
check read healthy; the skipped ticks logged nothing; the console said
"queued". And `queued` counted every attempt with `scoring_requested`, which is
never cleared after a good score - prod showed 2102 queued beside 2103 scored.
"""
from datetime import timedelta

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ._paging_harness import call_route
from .test_a_running_lane_keeps_what_it_holds import a_lane_is_running
from .test_individual_scoring_stays_individual import _Paper

_LOGGER = "odoo.addons.assessments_be_v2.models.assessment"
_MANAGER = "assessments_be_v2.group_assessment_manager"


@tagged("post_install", "-at_install")
class TestABlockedLaneIsVisible(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        # THE CRON IS ON TIME, so the only thing judged here is the lane.
        self.env["ir.cron"].sudo().with_context(active_test=False).search([
            ("code", "like", "_cron_llm_auto_score"),
            ("model_id.model", "=", "assessments.be"),
        ]).write({"active": True,
                  "nextcall": fields.Datetime.now() + timedelta(minutes=1)})
        # The ambient database is not this test's fixture: park what it has
        # queued or recently stored (rolled back with the test).
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be_evaluator "
            "SET scoring_requested = false, llm_scored_at = NULL "
            "WHERE scoring_requested OR llm_scored_at > %s",
            [fields.Datetime.now() - timedelta(hours=1)])
        self.env.invalidate_all()
        self.env.user.group_ids = [(4, self.env.ref(_MANAGER).id)]

    def _queued(self, minutes_ago=0):
        """A queued candidate whose row was last written ``minutes_ago``."""
        ev = self._candidate(1, requested=True)
        if minutes_ago:
            self._age(ev, minutes_ago)
        return ev

    def _age(self, ev, minutes_ago):
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be_evaluator SET write_date = %s WHERE id = %s",
            [fields.Datetime.now() - timedelta(minutes=minutes_ago), ev.id])
        self.env.invalidate_all()

    def _route(self):
        return call_route(api_admin, api_admin.EtpAssessmentApiAdmin(),
                          "scoring_pipeline", self.env,
                          assessment_id=self.paper.id)["data"]

    def _route_queries(self):
        """Counted the way `TestTheScoringPollAsksEachThingOnce` counts."""
        self.env.flush_all()
        self.env.invalidate_all()
        before = self.env.cr.sql_log_count
        self._route()
        return self.env.cr.sql_log_count - before

    def _health(self):
        return self.env["assessments.be"]._scoring_drainer_health()

    # (a) queued means queued

    def test_a_scored_candidate_is_not_queued_and_a_pending_one_is(self):
        scored = self._candidate(1, scored={0: 80}, requested=True)
        self.assertEqual(
            (scored.llm_state, scored.scoring_requested), ("scored", True),
            "fixture guard: a good score leaves the request raised")
        self._queued()
        self.assertEqual(self._route()["queued"], 1)

    # (b) a skipped tick is loud when it matters

    def test_a_skipped_tick_with_work_waiting_says_so(self):
        self._queued()
        with a_lane_is_running(self.env), \
                self.assertLogs(_LOGGER, "WARNING") as logs:
            self.env["assessments.be"]._cron_llm_auto_score(shard=0)
        self.assertIn("SCORING_LANE_BLOCKED shard=0 queued=1",
                      "\n".join(logs.output))

    def test_a_skipped_tick_with_nothing_queued_is_silent(self):
        with a_lane_is_running(self.env), \
                self.assertNoLogs(_LOGGER, "WARNING"):
            self.env["assessments.be"]._cron_llm_auto_score(shard=0)

    # (c) health sees a lane that is not moving

    def test_old_work_and_nothing_stored_is_a_blocked_lane(self):
        self._queued(minutes_ago=20)
        health = self._health()
        self.assertEqual(health["overdue"], 0,
                         "fixture guard: the cron itself is on time")
        self.assertTrue(health["blocked"])
        self.assertEqual(health["stuck"], {0: 1})
        drainer = self._route()["drainer"]
        self.assertTrue(drainer["stalled"])
        self.assertEqual(
            drainer["reason"], "grading shard 0 has stored nothing in 15 "
            "minutes with 1 candidate(s) queued on it")

    def test_a_stuck_lane_costs_the_poll_no_extra_query(self):
        """`/scoring` is polled under a query budget
        (`TestTheScoringPollAsksEachThingOnce.CEILING`), and a database with
        an old queue must not push it over."""
        ev = self._queued()
        self._route()  # warm the caches both counts below share
        fresh = self._route_queries()
        self._age(ev, 20)
        stuck = self._route_queries()
        self.assertEqual(self._health()["stuck"], {0: 1},
                         "fixture guard: the second count took the stuck path")
        self.assertLessEqual(stuck, fresh)

    def test_something_stored_recently_is_a_moving_lane(self):
        self._queued(minutes_ago=20)
        self._candidate(1, scored={0: 80})  # llm_scored_at = now
        health = self._health()
        self.assertFalse(health["blocked"])
        self.assertEqual(health["stuck"], {})

    def test_fresh_work_is_not_a_blocked_lane(self):
        self._queued()
        self.assertFalse(self._health()["blocked"])

    def test_only_the_lane_that_is_not_moving_is_named(self):
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.scoring_shards", "4")
        ev = self._queued(minutes_ago=20)
        stored = self._candidate(1, scored={0: 80})
        self.assertNotEqual(ev.id % 4, stored.id % 4, "fixture guard")
        self.assertEqual(self._health()["stuck"], {ev.id % 4: 1})
