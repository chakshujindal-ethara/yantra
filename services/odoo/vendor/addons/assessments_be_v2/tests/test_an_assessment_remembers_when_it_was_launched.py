# -*- coding: utf-8 -*-
"""An assessment remembers when it was launched, apart from its schedule.

`start_date` is admin-writable and `action_start` keeps a pre-set one, so for
a pre-scheduled paper it is the plan, not the launch. The list's "Conducted"
column and the detail header need the launch itself: `launched_at`, stamped by
every `action_start`. Rows launched before the field existed have none, so the
wire falls back to `start_date`, which launch wrote for them. A draft has not
been conducted, so it sends none whatever its schedule says.
"""
from datetime import timedelta
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ..controllers.api import serializers as S
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class TestAnAssessmentRemembersWhenItWasLaunched(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.admin = api_admin.EtpAssessmentApiAdmin()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Launch %s" % uuid4().hex[:6]})
        # A KEYED mcq, so the answer-key gate cannot refuse the launch.
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "Pick one.",
            "generator_id": self.generator.id,
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": question.id,
            "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": opt, "sequence": i * 10, "is_correct": i == 0})
                for i, opt in enumerate(("Alpha", "Bravo"))
            ],
        })

    def _draft(self, **vals):
        slug = uuid4().hex[:8]
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % slug,
            "email_from": "launch_%s@example.com" % slug,
        })
        assessment = self.env["assessments.be"].create(dict({
            "name": "Launch paper %s" % slug,
            "generator_id": self.generator.id,
            "duration_minutes": 30,
            "evaluator_ids": [(6, 0, [applicant.id])],
        }, **vals))
        assessment._sync_roster_rows()
        return assessment

    def _row(self, assessment, route):
        if route == "assessment_detail":
            response = call_route(
                api_admin, self.admin, route, self.env,
                path={"assessment_id": assessment.id})
            self.assertEqual(status_of(response), 200, response)
            return response["data"]
        response = call_route(api_admin, self.admin, route, self.env,
                              search=assessment.name, limit=200)
        self.assertEqual(status_of(response), 200, response)
        return next(r for r in response["data"] if r["id"] == assessment.id)

    def test_launch_stamps_launched_at(self):
        assessment = self._draft()
        self.assertFalse(assessment.launched_at)
        before = fields.Datetime.now()

        assessment.action_start()

        self.assertEqual(assessment.state, "in_progress")
        self.assertTrue(assessment.launched_at)
        self.assertGreaterEqual(assessment.launched_at, before)

    def test_a_pre_scheduled_paper_keeps_its_start_date(self):
        """THE reason the field exists: launch keeps the schedule, so
        `start_date` alone would show a launch that has not happened yet."""
        scheduled = fields.Datetime.now() + timedelta(days=2)
        assessment = self._draft(start_date=scheduled)

        assessment.action_start()

        self.assertEqual(assessment.start_date, scheduled)
        self.assertTrue(assessment.launched_at)
        self.assertNotEqual(assessment.launched_at, assessment.start_date)
        self.assertLess(assessment.launched_at, scheduled)

    def test_list_and_detail_payloads_carry_it(self):
        assessment = self._draft(
            start_date=fields.Datetime.now() + timedelta(days=2))
        assessment.action_start()
        expected = S.iso(assessment.launched_at)

        for route in ("assessment_list", "assessment_detail"):
            row = self._row(assessment, route)
            self.assertEqual(row["launched_at"], expected, route)
            self.assertNotEqual(row["launched_at"], row["start_date"], route)

    def test_a_legacy_row_falls_back_to_start_date(self):
        """Launched before the field existed: no stamp, so the wire sends the
        `start_date` launch wrote, not nothing. Running or done alike."""
        assessment = self._draft()
        assessment.action_start()
        assessment.launched_at = False

        for close in (False, True):
            if close:
                assessment.action_done()
            for route in ("assessment_list", "assessment_detail"):
                row = self._row(assessment, route)
                label = "%s, %s" % (assessment.state, route)
                self.assertEqual(
                    row["launched_at"], S.iso(assessment.start_date), label)
                self.assertTrue(row["launched_at"], label)

    def test_a_paper_cancelled_from_draft_sends_none(self):
        """Never launched, so its `start_date` is still only a schedule."""
        assessment = self._draft(
            start_date=fields.Datetime.now() + timedelta(days=2))
        assessment.action_cancel()

        self.assertEqual(assessment.state, "cancelled")
        for route in ("assessment_list", "assessment_detail"):
            self.assertIsNone(self._row(assessment, route)["launched_at"],
                              route)

    def test_a_draft_sends_none_even_when_scheduled(self):
        """A draft's `start_date` is a plan. Falling back to it would show a
        paper as conducted before anyone pressed Launch."""
        assessment = self._draft(
            start_date=fields.Datetime.now() + timedelta(days=2))

        self.assertIsNone(self._row(assessment, "assessment_list")
                          ["launched_at"])

    def test_a_reset_clears_it_and_a_relaunch_stamps_it_again(self):
        assessment = self._draft()
        assessment.action_start()
        assessment.action_cancel()
        assessment.with_context(confirm_released=True).action_reset_draft()
        self.assertFalse(assessment.launched_at)
        self.assertIsNone(self._row(assessment, "assessment_list")
                          ["launched_at"])

        assessment.action_start()

        self.assertTrue(assessment.launched_at)
