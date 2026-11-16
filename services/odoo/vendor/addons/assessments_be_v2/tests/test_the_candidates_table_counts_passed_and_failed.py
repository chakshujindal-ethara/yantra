# -*- coding: utf-8 -*-
"""The Candidates table counts Passed and Failed, and the dashboard's review
and progress figures come from the server.

Two wire additions, one cohort:

  * `/assessments/<id>/candidates` takes `result` (`pass` / `fail` /
    `pending`, AND-ed with `state`) and returns `meta.counts.pass` / `fail`.
    Every tile, state or outcome, is counted over the same cohort (search and
    flags), never under the tile being pressed: pressing Failed leaves All and
    Passed as they were, and each number says what pressing that tile alone
    would list (R1, 14 Oct).
  * `/analytics` adds `totals.in_progress`, `totals.not_started` and
    `flags.needs_review`. The app used to work these out in the browser from a
    capped attempts cache, and counted in-progress sittings as "not started".
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class TestTheCandidatesTableCountsPassedAndFailed(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.admin = api_admin.EtpAssessmentApiAdmin()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Outcomes %s" % uuid4().hex[:6]})
        self.assessment = self.env["assessments.be"].create({
            "name": "Outcomes paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
        })
        # Written directly so the fixture does not depend on grading. `result`
        # is a stored compute triggered by `state`, so the state write is
        # flushed first: otherwise the pending recompute runs at the next
        # flush and resets the written result to "pending".
        self.passed = self._sitting("submitted", "pass", integrity_alert=True,
                                    score_outlier=True)
        self.passed |= self._sitting("submitted", "pass")
        self.failed = self._sitting("submitted", "fail", is_violated=True)
        self.failed |= self._sitting("submitted", "fail")
        self.failed |= self._sitting("submitted", "fail")
        self.undecided = self._sitting("submitted", "pending")
        self.mid_exam = self._sitting("in_progress", None, score_outlier=True)
        self.not_started = self._sitting("pending", None)
        self.not_started |= self._sitting("pending", None)

    def _sitting(self, state, result, **flags):
        slug = uuid4().hex[:8]
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % slug,
            "email_from": "outcome_%s@example.com" % slug,
        })
        sitting = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": applicant.id,
        })
        sitting.write({"state": state})
        self.env.flush_all()
        if result:
            sitting.write({"result": result})
        if flags:
            sitting.write(flags)
        return sitting

    def _roster(self, **params):
        response = call_route(
            api_admin, self.admin, "assessment_candidates", self.env,
            path={"assessment_id": self.assessment.id}, limit=200, **params)
        self.assertEqual(status_of(response), 200, response)
        return response

    def _ids(self, **params):
        return {row["id"] for row in self._roster(**params)["data"]}

    def test_the_fixture_holds(self):
        self.env.flush_all()
        self.env.invalidate_all()
        self.assertEqual(set(self.passed.mapped("result")), {"pass"})
        self.assertEqual(set(self.failed.mapped("result")), {"fail"})
        self.assertTrue(self.mid_exam.score_outlier)

    def test_pass_and_fail_counts_equal_the_rows(self):
        counts = self._roster()["meta"]["counts"]

        self.assertEqual((counts["pass"], counts["fail"]), (2, 3))
        for result in ("pass", "fail"):
            self.assertEqual(
                counts[result], self._roster(result=result)["meta"]["total"],
                "the %s chip must say what pressing it lists" % result)

    def test_result_fail_returns_only_the_fails(self):
        self.assertEqual(self._ids(result="fail"), set(self.failed.ids))
        self.assertEqual(self._ids(result="pass"), set(self.passed.ids))

    def test_result_composes_with_state(self):
        self.assertEqual(self._ids(result="fail", state="submitted"),
                         set(self.failed.ids))
        self.assertEqual(self._ids(result="fail", state="in_progress"), set())
        self.assertEqual(self._ids(result="pending", state="submitted"),
                         set(self.undecided.ids))

    def test_no_pressed_tile_moves_any_count(self):
        """The tiles are one choice, so every count is over the same cohort:
        a pressed result must not shrink All, and a pressed state must not
        zero Passed / Failed. Each number is what pressing that tile alone
        lists. A flag still narrows every tile, the same way for each."""
        for flag in ({}, {"flagged_only": 1}):
            unpressed = self._roster(**flag)["meta"]["counts"]
            for params in ({"result": "fail"}, {"result": "pass"},
                           {"state": "submitted"}, {"state": "in_progress"},
                           {"state": "pending"},
                           {"result": "fail", "state": "in_progress"}):
                self.assertEqual(
                    self._roster(**params, **flag)["meta"]["counts"],
                    unpressed, "pressing %s moved a count (%s)"
                    % (params, flag))
            for key, count in unpressed.items():
                press = ({"result": key} if key in ("pass", "fail")
                         else {"state": key})
                self.assertEqual(
                    count, self._roster(**press, **flag)["meta"]["total"],
                    "%s says %d but pressing it lists otherwise (%s)"
                    % (key, count, flag))
        self.assertEqual(
            {k: unpressed[k] for k in ("all", "pass", "in_progress")},
            {"all": 2, "pass": 1, "in_progress": 1},
            "the flagged cohort is the outlier pass and the mid-exam outlier")

    def test_an_unknown_result_is_ignored(self):
        everyone = self._roster()["meta"]["total"]

        self.assertEqual(everyone, 9)
        self.assertEqual(self._roster(result="maybe")["meta"]["total"],
                         everyone)

    def test_analytics_sends_needs_review_in_progress_and_not_started(self):
        response = call_route(api_admin, self.admin, "analytics", self.env,
                              assessment_id=self.assessment.id)
        self.assertEqual(status_of(response), 200, response)
        data = response["data"]
        totals, flags = data["totals"], data["flags"]

        self.assertEqual(totals["in_progress"], 1)
        self.assertEqual(totals["not_started"], 2)
        self.assertEqual(
            totals["not_started"] + totals["in_progress"]
            + totals["submitted"], totals["assigned"])
        # Three DISTINCT attempts: one passed with two flags, one violated
        # fail, one outlier mid-exam. Summing the flags would say four.
        self.assertEqual(flags["needs_review"], 3)
        self.assertEqual(
            flags["integrity_alert"] + flags["score_outlier"]
            + flags["violated"], 4)

    def test_the_existing_analytics_keys_are_unchanged(self):
        response = call_route(api_admin, self.admin, "analytics", self.env,
                              assessment_id=self.assessment.id)
        data = response["data"]

        self.assertLessEqual(
            {"assigned", "people", "submitted", "decided", "passed", "failed",
             "awaiting_result", "avg_score", "pass_rate", "completion_rate"},
            set(data["totals"]))
        self.assertLessEqual(
            {"integrity_alert", "score_outlier", "violated", "scoring_error"},
            set(data["flags"]))
        self.assertEqual(data["totals"]["submitted"], 6)
