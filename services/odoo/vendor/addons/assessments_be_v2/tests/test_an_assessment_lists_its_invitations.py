# -*- coding: utf-8 -*-
"""`/emails/assessment/<id>` has to list the invitations its candidates were sent.

Invitations are mailed through `send_mail` on each `assessments.be.evaluator`,
so they are filed against the attempt, never the assessment. The route matched
the assessment alone, and every assessment's Emails tab read "no email has been
sent" beside a roster of "Sent" invites.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ._paging_harness import call_route

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class TestAnAssessmentListsItsInvitations(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.admin = api_admin.EtpAssessmentApiAdmin()
        self.token = uuid4().hex[:8]

    def _assessment_with_attempt(self):
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % self.token})
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % self.token,
            "question_type": "subjective_rubric",
            "prompt": "Answer it.",
            "difficulty": "easy",
            "generator_id": generator.id,
        })
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, question.ids)],
        })
        applicant = self.env["hr.applicant"].with_context(
            tracking_disable=True, mail_create_nolog=True, mail_notrack=True,
        ).create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "cand.%s@example.com" % uuid4().hex[:6],
        })
        attempt = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        return assessment, attempt

    def _mail(self, model, res_id, state="sent"):
        return self.env["mail.mail"].create({
            "subject": "Mail %s" % uuid4().hex[:6],
            "body_html": "<p>hi</p>",
            "email_to": "someone@example.com",
            "model": model,
            "res_id": res_id,
            "state": state,
        })

    def _emails(self, kind, record_id, **params):
        return call_route(api_admin, self.admin, "emails_for_record", self.env,
                          path={"kind": kind, "record_id": record_id},
                          limit=200, **params)

    def test_the_assessment_lists_its_own_and_its_attempts_mail(self):
        assessment, attempt = self._assessment_with_attempt()
        other_attempt = self._assessment_with_attempt()[1]
        own = self._mail("assessments.be", assessment.id)
        invite = self._mail("assessments.be.evaluator", attempt.id)
        stranger = self._mail("assessments.be.evaluator", other_attempt.id)

        ids = [row["id"] for row in self._emails("assessment", assessment.id)["data"]]

        self.assertEqual(ids, [invite.id, own.id])
        self.assertNotIn(stranger.id, ids)

    def test_the_state_filter_still_applies_across_both(self):
        assessment, attempt = self._assessment_with_attempt()
        self._mail("assessments.be", assessment.id, state="sent")
        bounced = self._mail("assessments.be.evaluator", attempt.id,
                             state="exception")

        body = self._emails("assessment", assessment.id, state="exception")

        self.assertEqual([row["id"] for row in body["data"]], [bounced.id])
        self.assertEqual(body["meta"]["total"], 1)

    def test_the_attempt_scope_is_unchanged(self):
        assessment, attempt = self._assessment_with_attempt()
        self._mail("assessments.be", assessment.id)
        invite = self._mail("assessments.be.evaluator", attempt.id)

        body = self._emails("attempt", attempt.id)

        self.assertEqual([row["id"] for row in body["data"]], [invite.id])
