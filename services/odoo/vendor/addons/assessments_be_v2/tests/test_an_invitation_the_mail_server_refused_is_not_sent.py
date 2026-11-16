# -*- coding: utf-8 -*-
"""An invitation the mail server refused is not reported as sent.

THE DEFECT (stage, 19 Oct 2026). Stage's outgoing mail server had been
deleted, so every invitation died with "111 Connection refused" - and every
attempt read `sent`. `send_mail(force_send=True)` does not raise when sending
fails: `mail.mail` records `exception` and returns, and
`_send_single_invitation` took "no exception" for "delivered". The roster
showed invitations sent that never left, and `action_requeue_invitation`
skips `sent`, so none of them could be retried.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAnInvitationTheMailServerRefusedIsNotSent(TransactionCase):

    def setUp(self):
        super().setUp()
        gen = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        question = self.env["assessments.be.question"].create({
            "name": "Q", "question_type": "mcq", "prompt": "Pick one",
            "difficulty": "easy", "generator_id": gen.id})
        self.env["assessments.be.question.dimension"].create({
            "question_id": question.id, "name": "Dim",
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": j * 10, "is_correct": j == 0})
                for j, n in enumerate(("Alpha", "Bravo"))]})
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand",
            "email_from": "cand_%s@example.com" % uuid4().hex[:8]})
        assessment = self.env["assessments.be"].create({
            "name": "Invite %s" % uuid4().hex[:6], "generator_id": gen.id,
            "question_limit": 1, "evaluator_ids": [(6, 0, applicant.ids)]})
        assessment.action_start()
        self.attempt = assessment.assessment_evaluator_ids

    def _invitation(self):
        return self.env["mail.mail"].sudo().search(
            [("model", "=", self.attempt._name),
             ("res_id", "=", self.attempt.id)], order="id desc", limit=1)

    def test_a_refused_invitation_says_why(self):
        def refuse(*args, **kwargs):
            raise ConnectionRefusedError(111, "Connection refused")

        with patch.object(type(self.env["ir.mail_server"]), "_connect__",
                          refuse):
            reason = self.attempt._deliver_invitation()

        self.assertEqual(self._invitation().state, "exception",
                         "the fixture must make the send fail")
        self.assertTrue(reason, "a refused invitation was reported as sent")
        self.assertIn("Connection refused", reason)

    def test_an_invitation_the_server_took_is_sent(self):
        reason = self.attempt._deliver_invitation()

        self.assertFalse(reason, reason)
        self.assertTrue(self._invitation(), "no invitation was mailed")
        self.assertNotEqual(self._invitation().state, "exception")
