# -*- coding: utf-8 -*-
"""A cohort category can never report more than 100%.

THE DEFECT. `_cohort_categories` summed a numerator of `final_mark` over a
denominator of a literal `1.0`, carrying a comment that asserted `final_mark`
is 1-or-0 per question. That was true when it was written and stopped being
true the day component scoring landed: a multi-component question now earns
0..N. So an image_ab question marked 4 out of 5 contributed 4.0 to the
numerator and 1.0 to the denominator, and the dashboard printed 400% for one
answer. Stage showed 111.8%.

WHY IT SURVIVED THE EXISTING SUITE. Every other analytics fixture builds
single-component rubric questions, where `final_max` IS 1.0 and the literal is
accidentally right. The fixture below is deliberately multi-component - it is
the only shape that can tell the two apart.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase

from ..controllers.api.admin import _cohort_categories


class TestCohortCategoryCannotExceedFullMarks(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Tag = self.env["assessments.be.tag"]
        self.Question = self.env["assessments.be.question"]
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Over100 fixture %s" % uuid4().hex[:6]})

    def _multi_component_question(self, tag):
        """An A/B question with THREE dimensions, so `final_max` is 3."""
        question = self.Question.create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "image_ab",
            "prompt": "Judge both images.",
            "generator_id": self.generator.id,
            "tag_ids": [(6, 0, tag.ids)],
        })
        for label in ("Sharpness", "Realism", "Overall Choice"):
            dim = self.env["assessments.be.question.dimension"].create({
                "question_id": question.id,
                "name": label,
            })
            for opt in ("Response A", "Response B"):
                self.env["assessments.be.question.dimension.option"].create({
                    "question_dimension_id": dim.id,
                    "name": opt,
                    "is_correct": opt == "Response A",
                })
        return question

    def _sitting(self, assessment, question, correct_dimensions):
        applicant = self.Applicant.create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "c_%s@example.com" % uuid4().hex[:8],
        })
        evaluator = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        response = self.Response.create({
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "assessment_id": assessment.id,
            "state": "submitted",
            "justification": "An answer.",
        })
        # Mark it directly: this test is about how analytics AGGREGATES marks,
        # not about how the grader produces them.
        response.write({
            "final_mark": float(correct_dimensions),
            "final_max": 3.0,
        })
        evaluator.state = "submitted"
        return evaluator

    def test_a_multi_component_answer_does_not_report_over_100(self):
        """THE regression. Three of three correct is 100%, not 300%."""
        tag = self.Tag.create({
            "name": "skill:image-judgement",
            "display": "Image Judgement",
        })
        question = self._multi_component_question(tag)
        assessment = self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
        })
        # Two sittings, both perfect, so `min_answers=2` is satisfied.
        self._sitting(assessment, question, 3)
        self._sitting(assessment, question, 3)

        rows = _cohort_categories(self.Evaluator.search(
            [("assessment_id", "=", assessment.id)]))
        row = next(r for r in rows if r["tag"] == "skill:image-judgement")

        self.assertEqual(
            row["possible"], 6.0,
            "two answers out of three marks each is six available marks, not "
            "two - the denominator must follow the question's own final_max")
        self.assertEqual(row["earned"], 6.0)
        self.assertEqual(
            row["percent"], 100.0,
            "a perfect score is 100%, and before the fix this read 300%")

    def test_a_partial_multi_component_answer_is_a_fraction_of_its_own_max(
            self):
        """Two of three is 66.7%, and in particular is NOT 200%."""
        tag = self.Tag.create({
            "name": "skill:partial-judgement",
            "display": "Partial Judgement",
        })
        question = self._multi_component_question(tag)
        assessment = self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
        })
        self._sitting(assessment, question, 2)
        self._sitting(assessment, question, 2)

        rows = _cohort_categories(self.Evaluator.search(
            [("assessment_id", "=", assessment.id)]))
        row = next(r for r in rows if r["tag"] == "skill:partial-judgement")

        self.assertEqual(row["possible"], 6.0)
        self.assertEqual(row["earned"], 4.0)
        self.assertLessEqual(
            row["percent"], 100.0,
            "no category may ever exceed full marks")
        self.assertAlmostEqual(row["percent"], 66.7, places=1)
