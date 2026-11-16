"""`/state?q=` with a number too big to read resumes like a missing `q`.

A JSON body `{"q": 1e400}` parses to float("inf"), and `int()` of that raised
OverflowError past the ValueError guard: a 500 instead of the next question.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import candidate as cand_api


class _StubRequest:
    def __init__(self, env):
        self.env = env
        self.params = {}


@tagged("-at_install", "post_install")
class TestAnUnreadableQuestionNumberIsIgnored(TransactionCase):

    def test_an_endless_q_serves_the_first_unanswered_question(self):
        gen = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        questions = self.env["assessments.be.question"].create([{
            "name": "Q%d %s" % (i, uuid4().hex[:4]),
            "question_type": "subjective_rubric", "prompt": "Why?",
            "generator_id": gen.id} for i in range(2)])
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.env["assessments.be"].create({
                "name": "Paper %s" % uuid4().hex[:6],
                "generator_id": gen.id}).id,
            "applicant_id": self.env["hr.applicant"].create({
                "partner_name": "Cand", "email_from": "c_%s@example.com"
                % uuid4().hex[:8]}).id,
            "question_order": json.dumps(questions.ids),
        })
        controller = cand_api.EtpAssessmentApiCandidate()
        with patch.object(cand_api, "request", _StubRequest(self.env)):
            for q in (json.loads("1e400"), float("nan"), "1e400", None):
                out = controller._question_payload(
                    evaluator, evaluator.access_token, requested_index=q)
                self.assertEqual(out.get("outcome"), "question", q)
                self.assertEqual(out["question"]["index"], 1, q)
