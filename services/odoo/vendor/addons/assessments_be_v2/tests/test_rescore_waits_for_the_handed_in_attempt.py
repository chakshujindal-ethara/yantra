# -*- coding: utf-8 -*-
""""Re-score This Answer" waits until the candidate has handed in.

Answers are submitted one by one during the exam, so an answer being
`submitted` says nothing about the attempt. The server already refuses a
re-score on an attempt still in progress; the button must not be offered
there either.
"""
from uuid import uuid4

from lxml import etree

from odoo.tests.common import TransactionCase, tagged
from odoo.tools.safe_eval import safe_eval


@tagged("-at_install", "post_install")
class TestRescoreWaitsForTheHandedInAttempt(TransactionCase):

    def setUp(self):
        super().setUp()
        # The button is drawn for Assessment Admins only.
        self.env.user.group_ids = [
            (4, self.env.ref("assessments_be_v2.group_assessment_manager").id)]
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Rescore %s" % uuid4().hex[:6]})
        paper = self.env["assessments.be"].create({
            "name": "Rescore paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
        })
        applicant = self.env["hr.applicant"].create(
            {"partner_name": "Mid Exam %s" % uuid4().hex[:6]})
        self.attempt = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id,
            "state": "in_progress"})
        question = self.env["assessments.be.question"].create({
            "name": "Describe %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric",
            "prompt": "Describe",
            "generator_id": generator.id,
            "assessment_ids": [(4, paper.id)],
        })
        self.answer = self.env["assessments.be.response"].create({
            "assessment_evaluator_id": self.attempt.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "assessment_id": paper.id,
            "state": "submitted",
            "justification": "A written answer handed in mid-exam.",
        })

    def _button(self):
        view = self.env.ref("assessments_be_v2.assessments_be_response_form")
        arch = etree.fromstring(self.env["assessments.be.response"].get_view(
            view.id, "form")["arch"])
        button = arch.xpath("//button[@name='action_rescore_this_answer']")
        self.assertTrue(button)
        return arch, button[0]

    def _hidden(self):
        arch, button = self._button()
        expr = button.get("invisible")
        names = {f.get("name") for f in arch.iter("field")}
        values = {}
        # `attempt_released` and `rescore_request_key` joined the
        # modifier when the released case got its own confirming button
        # and a queued re-score started withdrawing the control.
        for name in ("needs_llm", "state", "attempt_state",
                     "attempt_released", "rescore_request_key",
                     "assessment_scoring_phase"):
            if name in expr:
                self.assertIn(name, names,
                              "%s is in the modifier but not in the view" % name)
            values[name] = self.answer[name] if name in self.answer else False
        return safe_eval(expr, values)

    def test_hidden_while_the_attempt_is_in_progress(self):
        self.assertTrue(self.answer.needs_llm)
        self.assertEqual(self.answer.state, "submitted")
        self.assertTrue(self._hidden(),
                        "offered on an answer of an exam still in progress")

    def test_shown_once_the_attempt_is_submitted(self):
        self.attempt.state = "submitted"
        self.assertFalse(self._hidden())
