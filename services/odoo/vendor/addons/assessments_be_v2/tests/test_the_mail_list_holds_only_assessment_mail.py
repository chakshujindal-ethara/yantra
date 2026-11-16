# -*- coding: utf-8 -*-
"""A-226 / A-227: `/emails` and `/emails/<id>/cancel` see only this module's mail.

Both ran sudo over the whole `mail.mail` table, and a Manager is sent
`body_html`. So every Manager read every mail in the database - an admin's
password-reset link from any module included - and could cancel any queued
one by raw id. Scoped now to the records the chatter allow-list names: an
invitation (filed on the attempt) still lists and cancels; a `res.users` mail
is not listed and its cancel is the standard not-found refusal.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class TestTheMailListHoldsOnlyAssessmentMail(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.admin = api_admin.EtpAssessmentApiAdmin()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "cand.%s@example.com" % uuid4().hex[:6],
        })
        self.attempt = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id, "applicant_id": applicant.id})

    def _mail(self, model, res_id):
        return self.env["mail.mail"].create({
            "subject": "Mail %s" % uuid4().hex[:6],
            "body_html": "<p>secret link</p>",
            "email_to": "someone@example.com",
            "model": model,
            "res_id": res_id,
            "state": "outgoing",
        })

    def _call(self, method, path=None, **params):
        return call_route(api_admin, self.admin, method, self.env,
                          path=path, **params)

    def test_a_foreign_mail_is_neither_listed_nor_cancellable(self):
        reset = self._mail("res.users", self.env.user.id)
        invite = self._mail("assessments.be.evaluator", self.attempt.id)

        listed = {row["id"] for row in self._call(
            "email_list", state="outgoing", limit=200)["data"]}
        self.assertIn(invite.id, listed, "an invitation must still list")
        self.assertNotIn(reset.id, listed,
                         "another module's mail reached a Manager's list")

        refused = self._call("email_cancel", path={"mail_id": reset.id})
        self.assertEqual(status_of(refused), 404, refused)
        self.assertEqual(refused["error"]["code"], "not_found")
        self.assertEqual(reset.state, "outgoing")

        done = self._call("email_cancel", path={"mail_id": invite.id})
        self.assertEqual(status_of(done), 200, done)
        self.assertEqual(invite.state, "cancel")
