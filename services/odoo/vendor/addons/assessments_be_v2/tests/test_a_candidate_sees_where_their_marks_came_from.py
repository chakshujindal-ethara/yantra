# -*- coding: utf-8 -*-
"""A released result says WHERE the marks came from, not only the total.

THE GAP. The model has always computed this split - twice, into `result_summary`
(staff) and `result_summary_public` (candidate) - and both are HTML. The QWeb
runner rendered the public one on its completion page, so a candidate could see
that they had lost their marks on the written half rather than the objective one.
The JSON API sent neither, so the Flutter client could only ever print one figure.
"6 / 10" tells somebody they failed and nothing about what to work on.

WHY NOT SHIP `result_summary_public`. It is a styled Bootstrap card with inline
`background:#f8f9fa`, built for the backend's theme; the client would have to
either render foreign markup or strip it. It is also HTML on a candidate screen,
which is a surface worth not having. `candidate_result.breakdown` sends the
numbers and the client draws its own rows.

INVARIANT 2 STILL HOLDS, and that is the thing most worth pinning here: counts
and marks, never a percentage of this candidate's score. A breakdown is exactly
the shape that invites a percentage in, so the last test in this file asserts
there is none - in the breakdown and in the payload that carries it.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import serializers as S


@tagged("-at_install", "post_install")
class TestACandidateSeesWhereTheirMarksCameFrom(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]

    # -- fixtures ---------------------------------------------------------

    def _objective(self):
        """A keyed mcq worth one component. Returns (question, dimension)."""
        question = self.Question.create({
            "name": "Objective %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "Pick one.",
        })
        dimension = self.QDim.create({
            "question_id": question.id,
            "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": i * 10, "is_correct": i == 0})
                for i, n in enumerate(("Alpha", "Bravo"))],
        })
        return question, dimension

    def _subjective(self):
        return self.Question.create({
            "name": "Written %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Explain your reasoning.",
            "subjective_rubric_json": json.dumps(
                {"scoring_guide": "Mentions the trade-off."}),
        })

    def _attempt(self, questions):
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:6],
        })
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "duration_minutes": 30,
            "question_ids": [(6, 0, questions.ids)],
        })
        return self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "access_token": str(uuid4()),
        })

    def _answer(self, evaluator, question, picks=(), justification="",
                raw_100=None, state="submitted"):
        """One answer, built the way the runner builds one.

        THE SCORE IS NOT WRITEABLE. `score`, `max_score`, `has_objective`,
        `needs_llm` and `llm_passed` are all stored COMPUTES over the answer's
        actual content, so a fixture that stamps them writes nothing and every
        assertion about the split comes back zero. Choices go in as `line_ids`
        and the grader's raw 0-100 is stamped only where the grader itself is not
        what is under test - the same shape `test_component_marks` uses.

        NOTE THE TWO EVALUATOR FIELDS. `response.evaluator_id` is an
        `hr.applicant` - the PERSON - while `assessment_evaluator_id` is the
        attempt. The names invite the opposite reading, and writing the attempt's
        id into `evaluator_id` fails on a foreign key against `hr_applicant`
        rather than on anything that mentions the mistake.
        """
        vals = {
            "evaluator_id": evaluator.applicant_id.id,
            "assessment_evaluator_id": evaluator.id,
            "assessment_id": evaluator.assessment_id.id,
            "question_id": question.id,
            "state": state,
            "line_ids": [
                (0, 0, {"question_dimension_id": dimension.id,
                        "selected_option_id": option.id})
                for dimension, option in picks
            ],
        }
        if justification:
            vals["justification"] = justification
        if raw_100 is not None:
            vals.update({"llm_raw_100": raw_100, "llm_state": "scored"})
        return self.env["assessments.be.response"].create(vals)

    @staticmethod
    def _option(dimension, correct):
        options = dimension.option_line_ids.sorted("sequence")
        return options[0] if correct else options[1]

    def _breakdown(self, evaluator):
        return {row["key"]: row
                for row in S.candidate_result_breakdown(evaluator)}

    # -- cases ------------------------------------------------------------

    def test_the_objective_section_counts_fully_correct_answers(self):
        right, right_dim = self._objective()
        wrong, wrong_dim = self._objective()
        evaluator = self._attempt(right | wrong)
        self._answer(evaluator, right,
                     picks=[(right_dim, self._option(right_dim, True))])
        self._answer(evaluator, wrong,
                     picks=[(wrong_dim, self._option(wrong_dim, False))])

        rows = self._breakdown(evaluator)

        self.assertIn("objective", rows)
        self.assertEqual(rows["objective"]["value"], 1)
        self.assertEqual(rows["objective"]["total"], 2)
        self.assertEqual(rows["objective"]["unit"], "correct")

    def test_a_paper_that_hides_answers_states_marks_not_verdicts(self):
        """`results_show_answers` off: marks and totals stay, but "3 / 3
        correct" and "1/1 passed" are per-answer verdicts the paper hides."""
        question, dimension = self._objective()
        written = self._subjective()
        evaluator = self._attempt(question | written)
        self._answer(evaluator, question,
                     picks=[(dimension, self._option(dimension, True))])
        self._answer(evaluator, written, justification="The trade-off.",
                     raw_100=90)

        def summary():
            return {key: (row["value"], row["total"], row["unit"])
                    for key, row in self._breakdown(evaluator).items()}

        shown = summary()
        evaluator.assessment_id.results_show_answers = False
        hidden = summary()

        self.assertEqual(shown, {"objective": (1, 1, "correct"),
                                 "subjective": (1, 1, "passed")})
        self.assertEqual(hidden, {"objective": (1, 1, "marks"),
                                  "subjective": (1, 1, "marks")})

    def test_with_the_key_hidden_the_marks_are_real_marks(self):
        """The hidden-key unit said "marks" while the value still counted
        fully correct questions and passed written answers: 3 of 4 marks on
        two two-part questions read "1 / 2 marks"."""
        whole, whole_first = self._objective()
        whole_second = self._second_part(whole)
        part, part_first = self._objective()
        part_second = self._second_part(part)
        passed, failed = self._subjective(), self._subjective()
        evaluator = self._attempt(whole | part | passed | failed)
        self._answer(evaluator, whole, picks=[
            (whole_first, self._option(whole_first, True)),
            (whole_second, self._option(whole_second, True))])
        self._answer(evaluator, part, picks=[
            (part_first, self._option(part_first, True)),
            (part_second, self._option(part_second, False))])
        self._answer(evaluator, passed, justification="The trade-off.",
                     raw_100=90)
        self._answer(evaluator, failed, justification="Not sure.", raw_100=10)

        def summary():
            return {key: (row["value"], row["total"], row["unit"])
                    for key, row in self._breakdown(evaluator).items()}

        self.assertEqual(summary(), {"objective": (1, 2, "correct"),
                                     "subjective": (1, 2, "passed")})
        evaluator.assessment_id.results_show_answers = False
        self.assertEqual(summary(), {"objective": (3, 4, "marks"),
                                     "subjective": (1, 2, "marks")})
        self.assertEqual(evaluator.score_marks_display, "4 / 6",
                         "every question answered: the rows add up to the "
                         "headline")

    def test_with_the_key_hidden_a_blank_written_answer_still_counts(self):
        """A written question left blank is never graded, so it is not
        `needs_llm` and fell out of the written row while the headline still
        counted it: "4 / 6" over rows of 3 / 4 and 1 / 1."""
        whole, whole_first = self._objective()
        whole_second = self._second_part(whole)
        part, part_first = self._objective()
        part_second = self._second_part(part)
        passed, blank = self._subjective(), self._subjective()
        evaluator = self._attempt(whole | part | passed | blank)
        self._answer(evaluator, whole, picks=[
            (whole_first, self._option(whole_first, True)),
            (whole_second, self._option(whole_second, True))])
        self._answer(evaluator, part, picks=[
            (part_first, self._option(part_first, True)),
            (part_second, self._option(part_second, False))])
        self._answer(evaluator, passed, justification="The trade-off.",
                     raw_100=90)
        self._answer(evaluator, blank)
        evaluator.assessment_id.results_show_answers = False

        rows = self._breakdown(evaluator)

        self.assertEqual(evaluator.score_marks_display, "4 / 6")
        self.assertEqual({key: (row["value"], row["total"], row["unit"])
                          for key, row in rows.items()},
                         {"objective": (3, 4, "marks"),
                          "subjective": (1, 2, "marks")})
        self.assertEqual(rows["subjective"]["pending"], 0,
                         "a blank answer is not waiting for the grader")

    def _second_part(self, question):
        return self.QDim.create({
            "question_id": question.id,
            "name": "Second part",
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": i * 10, "is_correct": i == 0})
                for i, n in enumerate(("Alpha", "Bravo"))],
        })

    def test_a_half_right_multi_part_answer_is_not_counted_correct(self):
        """`score >= max_score` is the model's own definition of correct, and
        this mirrors the comparison rather than the number so the two cannot
        drift apart.

        Two keyed axes, one right: the answer earns a real mark and is still not
        a fully correct answer. A single-axis question cannot express that - it
        is 1 or 0 - so this needs the two-part shape.
        """
        question, first = self._objective()
        second = self.QDim.create({
            "question_id": question.id,
            "name": "Second part",
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": i * 10, "is_correct": i == 0})
                for i, n in enumerate(("Alpha", "Bravo"))],
        })
        evaluator = self._attempt(question)
        response = self._answer(evaluator, question, picks=[
            (first, self._option(first, True)),
            (second, self._option(second, False)),
        ])

        self.assertEqual(response.score, 1, "one axis was right")
        self.assertEqual(response.max_score, 2, "out of two keyed axes")
        self.assertEqual(
            self._breakdown(evaluator)["objective"]["value"], 0,
            "1 of 2 is not a fully correct answer")

    def test_a_paper_with_no_written_half_omits_that_section(self):
        """A section with a zero denominator is noise, not information."""
        question, dimension = self._objective()
        evaluator = self._attempt(question)
        self._answer(evaluator, question,
                     picks=[(dimension, self._option(dimension, True))])

        rows = self._breakdown(evaluator)

        self.assertIn("objective", rows)
        self.assertNotIn(
            "subjective", rows,
            "a six-question objective paper has no written section; a '0 of 0 "
            "passed' row tells the candidate nothing")

    def test_an_ungraded_written_answer_is_reported_as_pending(self):
        """A candidate looking at a partial count must be told it is partial, or
        the figure reads as their final result."""
        graded = self._subjective()
        ungraded = self._subjective()
        evaluator = self._attempt(graded | ungraded)
        # 90 clears the default subjective threshold; the second answer is
        # written but never handed a raw, so it stays unscored.
        self._answer(evaluator, graded, justification="Because of the trade-off.",
                     raw_100=90)
        self._answer(evaluator, ungraded, justification="Some reasoning.")

        rows = self._breakdown(evaluator)

        self.assertEqual(rows["subjective"]["value"], 1)
        self.assertEqual(rows["subjective"]["total"], 2)
        self.assertEqual(
            rows["subjective"]["pending"], 1,
            "one answer is still with the judge and the count must say so")

    def test_an_unsubmitted_answer_is_in_no_section(self):
        """The split is over SUBMITTED responses. A draft answer is not a result."""
        question, dimension = self._objective()
        draft_q, draft_dim = self._objective()
        evaluator = self._attempt(question | draft_q)
        self._answer(evaluator, question,
                     picks=[(dimension, self._option(dimension, True))])
        self._answer(evaluator, draft_q, state="draft",
                     picks=[(draft_dim, self._option(draft_dim, True))])

        self.assertEqual(self._breakdown(evaluator)["objective"]["total"], 1)

    # -- the invariant ----------------------------------------------------

    def test_the_breakdown_carries_no_percentage_of_the_candidates_score(self):
        """INVARIANT 2, on the payload most likely to break it.

        A breakdown is exactly the shape that invites a percentage in - it is
        already reporting fractions - so this is asserted over the SERIALIZED
        keys rather than trusted to review.
        """
        question, dimension = self._objective()
        written = self._subjective()
        evaluator = self._attempt(question | written)
        self._answer(evaluator, question,
                     picks=[(dimension, self._option(dimension, True))])
        self._answer(evaluator, written, justification="Thin reasoning.",
                     raw_100=10)

        for row in S.candidate_result_breakdown(evaluator):
            self.assertNotIn("percent", json.dumps(row).lower())
            self.assertNotIn("score_percent", row)
            self.assertNotIn("raw", json.dumps(row).lower())

    def test_the_breakdown_is_withheld_until_results_are_released(self):
        """It rides inside `candidate_result`, which returns NO score keys at all
        before release - not a null, not a zero, no key. So there is nothing for
        a client bug to render early."""
        question, dimension = self._objective()
        evaluator = self._attempt(question)
        self._answer(evaluator, question,
                     picks=[(dimension, self._option(dimension, True))])
        self.assertFalse(evaluator.results_released, "fixture check")

        payload = S.candidate_result(evaluator, "completed")

        self.assertFalse(payload["released"])
        self.assertNotIn(
            "breakdown", payload,
            "an unreleased result must carry no breakdown key at all")

    def test_a_released_result_carries_the_breakdown(self):
        """Guard the guard: if it were withheld unconditionally, the test above
        would pass while the feature did not exist."""
        question, dimension = self._objective()
        evaluator = self._attempt(question)
        self._answer(evaluator, question,
                     picks=[(dimension, self._option(dimension, True))])
        evaluator.write({"results_released": True})

        payload = S.candidate_result(evaluator, "completed")

        self.assertTrue(payload["released"])
        self.assertIn("breakdown", payload)
        self.assertEqual(payload["breakdown"][0]["key"], "objective")
