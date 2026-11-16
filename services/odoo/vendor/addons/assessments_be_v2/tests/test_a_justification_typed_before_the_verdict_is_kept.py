"""A comparison's justification typed BEFORE any verdict is kept as a draft.

THE DEFECT (prod, 2026-09-29, questions 1167 and 1178). The runner autosaves
the justification on every keystroke. `_record_response` refused any image_ab
payload with no verdict lines outright - `return False` before anything was
stored - so a candidate who wrote their reasoning first and picked second got
`422 incomplete_answer` three times and none of that text reached the server.

THE FIX. Prose without a verdict is HELD AS A DRAFT, the mechanism an image_ab
with verdicts but no required prose already uses: the text is stored, the
question stays out of `answered`, and the route still answers the held-draft
`incomplete_answer` that the runner treats as "held, not lost". Picking the
verdicts promotes the same row; expiry settles it like every other held draft,
and an image_ab with no verdict never earns a mark.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAJustificationTypedBeforeTheVerdictIsKept(TransactionCase):

    PROSE = "Response B keeps the right hand on the cup, A swaps hands."

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.Response = self.env["assessments.be.response"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Prose first %s" % uuid4().hex[:6]})
        self.controller = self._controller()

    @staticmethod
    def _controller():
        import inspect

        from odoo import http

        from ..controllers.api import candidate as candidate_api
        for _name, obj in vars(candidate_api).items():
            if (inspect.isclass(obj) and issubclass(obj, http.Controller)
                    and obj.__module__ == candidate_api.__name__
                    and hasattr(obj, "exam_answer")):
                return obj()
        raise AssertionError("the candidate controller was not found")

    def _question(self, qtype="image_ab"):
        question = self.Question.create({
            "name": "Which render %s" % uuid4().hex[:6],
            "question_type": qtype,
            "prompt": "place the red cup on the top shelf with the right hand",
            "official_reasoning": "Response B is correct by construction."
            if qtype == "image_ab" else False,
            "generator_id": self.generator.id,
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": question.id,
            "name": "Overall Choice",
            "option_line_ids": [
                (0, 0, {"name": "Response A", "sequence": 10}),
                (0, 0, {"name": "Response B", "sequence": 20,
                        "is_correct": True}),
            ],
        })
        return question

    def _sitting(self, question):
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
            "question_limit": 1,
            "duration_minutes": 60,
            "state": "in_progress",
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Prose First",
            "email_from": "%s@example.com" % uuid4().hex[:10],
        })
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": json.dumps(question.ids),
            "access_token": uuid4().hex,
            # Begun: `_write_guard` refuses answers to an unstarted attempt.
            "started_at": fields.Datetime.now(),
        })
        assessment.sudo()._ensure_candidate_user(applicant)
        return evaluator, evaluator.sudo()._candidate_user()

    def _answer(self, evaluator, user, question, **params):
        from ..controllers.api import candidate as candidate_api
        from ..controllers.api import common as api_common

        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(self.env(user=user), dict(
            params, question_id=question.id, nav="stay"))
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            return self.controller.exam_answer(evaluator.access_token,
                                               **fake.params)

    def _row(self, evaluator, question):
        return self.Response.search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "=", question.id)])

    def test_prose_typed_first_is_stored_as_a_held_draft(self):
        question = self._question()
        evaluator, user = self._sitting(question)

        reply = self._answer(evaluator, user, question,
                             justification=self.PROSE)

        row = self._row(evaluator, question)
        self.assertEqual(len(row), 1, "the prose was refused, not stored")
        self.assertEqual(row.state, "draft")
        self.assertEqual(row.justification, self.PROSE)
        self.assertFalse(row.line_ids)
        self.assertEqual(
            (reply.get("error") or {}).get("code"), "incomplete_answer",
            "a held draft answers like every other held draft: %r" % (reply,))
        self.assertEqual(evaluator.answered_count, 0)

    def test_picking_the_verdict_afterwards_promotes_the_same_row(self):
        question = self._question()
        evaluator, user = self._sitting(question)
        self._answer(evaluator, user, question, justification=self.PROSE)
        held = self._row(evaluator, question)
        self.assertTrue(held, "the prose-first save kept nothing")
        pick = question.question_dimension_ids.option_line_ids.filtered(
            "is_correct")

        reply = self._answer(evaluator, user, question,
                             justification=self.PROSE,
                             selected_option_ids=pick.ids)

        self.assertTrue(reply.get("ok"), reply)
        row = self._row(evaluator, question)
        self.assertEqual(row, held, "promoted, not duplicated")
        self.assertEqual(row.state, "submitted")
        self.assertEqual(row.justification, self.PROSE)
        self.assertEqual(row.mcq_mark, 1.0)

    def test_expiry_settles_a_prose_only_draft_with_no_mark(self):
        question = self._question()
        evaluator, user = self._sitting(question)
        self._answer(evaluator, user, question, justification=self.PROSE)

        evaluator.sudo()._auto_submit_expired(reason_code="expired")

        row = self._row(evaluator, question)
        self.assertEqual(len(row), 1, "the draft was promoted, not duplicated")
        self.assertEqual(row.state, "submitted")
        self.assertEqual(row.justification, self.PROSE, "the prose survives")
        self.assertFalse(row.needs_llm, "no verdict, nothing to grade")
        self.assertEqual(row.llm_state, "not_needed")
        self.assertEqual(row.final_mark, 0.0)

    def test_an_empty_comparison_and_an_mcq_are_still_refused(self):
        for qtype, params in (("image_ab", {}),
                              ("mcq", {"justification": self.PROSE})):
            with self.subTest(qtype=qtype):
                question = self._question(qtype)
                evaluator, user = self._sitting(question)

                reply = self._answer(evaluator, user, question, **params)

                self.assertEqual(
                    (reply.get("error") or {}).get("code"),
                    "incomplete_answer")
                self.assertFalse(self._row(evaluator, question),
                                 "nothing is stored for a refused answer")
