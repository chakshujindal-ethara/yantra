"""The denominator is the PAPER, not the answers.

WHAT THIS GUARDS, and it is a real one. Attempt 740 was an 8-question paper
scored out of 3, and it reported 100% PASS. The denominator had been built from
the response rows, so every question the candidate never opened quietly left
the total instead of scoring 0 out of its marks - the less of the paper you
attempted, the shorter the paper became, and abandoning everything you could
not answer was the optimal strategy.

The fix is `_paper_component_totals()`: it counts over `question_order`, the
candidate's FROZEN draw, and asks each question what it is worth via
`_component_counts()` - a figure that lives on the QUESTION precisely so it can
be computed for a question with no response row at all. Deriving it from an
answer would put the bug straight back.

MOVING TO PER-COMPONENT MARKS DID NOT CHANGE THIS, only made the numbers finer,
and that is exactly why the test is worth having now. The denominator used to
be a question COUNT, so "count over the draw" and "count over the answers"
differed by whole questions; it is now a sum of per-question component counts,
which is more arithmetic in a place that has already been wrong once. A paper
of a 3-mark question and a 2-mark question reads 5 whether the candidate
answered both, one, or neither.

THE RAW DENOMINATOR IS THE SAME SUM OVER A DIFFERENT SET. Objective components
carry no raw at all, so they are absent from both sides of the raw fraction
rather than scoring 0 in it - a 5-mark paper with one graded free-text answer
has a raw denominator of 1, not 5. Pinned here because both totals come out of
the same helper and a change to one is a change to the other.

`subjective_threshold` is PINNED rather than left to
`DEFAULT_SUBJECTIVE_THRESHOLD`: it is the bar `result` is decided against, and
reading a deployment's tuned default would make the pass/fail assertion below
mean something different on every database.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestPaperDenominatorCountsUnansweredQuestions(TransactionCase):

    THRESHOLD = 70.0

    def setUp(self):
        super().setUp()
        self.Generator = self.env["assessments.be.prompt"]
        self.Question = self.env["assessments.be.question"]
        self.Dimension = self.env["assessments.be.question.dimension"]
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.Generator.create(
            {"name": "Mixed paper %s" % uuid4().hex[:6]})

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _dimension(self, question, name):
        return self.Dimension.create({
            "question_id": question.id,
            "name": name,
            "option_line_ids": [
                (0, 0, {"name": option, "sequence": i * 10,
                        "is_correct": i == 0})
                for i, option in enumerate(("Right", "Wrong"))
            ],
        })

    def _three_mark_question(self):
        """An mcq with three keyed sub-questions: 3 marks, no raw."""
        question = self.Question.create({
            "name": "Three parts %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "Answer all three parts.",
            "generator_id": self.generator.id,
        })
        dims = [self._dimension(question, "Part %d" % i) for i in range(1, 4)]
        return question, dims

    def _two_mark_question(self):
        """An image_ab with one verdict axis plus its justification: 2 marks,
        of which 1 carries a raw. The one the candidate abandons.

        `official_reasoning` is what the judge marks the justification
        against, so it is what makes that second mark exist - without one the
        question is worth its verdict axis alone and this would be a
        one-mark question. See `question._component_counts`.
        """
        question = self.Question.create({
            "name": "Which render %s" % uuid4().hex[:6],
            "question_type": "image_ab",
            "prompt": "Pick the better render and say why.",
            "official_reasoning": "The sharper render that follows the brief.",
            "generator_id": self.generator.id,
        })
        self._dimension(question, "Overall Choice")
        return question

    def _paper(self):
        question_3, dims = self._three_mark_question()
        question_2 = self._two_mark_question()
        questions = question_3 + question_2
        assessment = self.Assessment.create({
            "name": "Mixed paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, questions.ids)],
            "subjective_threshold": self.THRESHOLD,
        })
        return assessment, question_3, dims, question_2

    def _evaluator(self, assessment, drawn):
        """One candidate whose FROZEN draw is `drawn`.

        `question_order` is written the way `action_start` writes it - a JSON
        list of question ids - because that is the column
        `_paper_component_totals` reads.
        """
        applicant = self.Applicant.create({
            "partner_name": "Candidate %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:8],
        })
        return self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": json.dumps(drawn.ids),
        })

    def _answer_all_parts(self, evaluator, question, dims):
        return self.Response.create({
            # `response_ids` on the evaluator is keyed on THIS field;
            # `evaluator_id` is the hr.applicant, not the assignment.
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": evaluator.applicant_id.id,
            "question_id": question.id,
            "assessment_id": evaluator.assessment_id.id,
            "state": "submitted",
            "line_ids": [
                (0, 0, {"question_dimension_id": dimension.id,
                        "selected_option_id":
                            dimension.option_line_ids.sorted("sequence")[0].id})
                for dimension in dims
            ],
        })

    # ------------------------------------------------------------------
    # Cases
    # ------------------------------------------------------------------
    def test_the_questions_price_themselves(self):
        """The two halves of the arithmetic, asserted before it is summed.

        Without this, a failure below could equally mean the paper total is
        wrong or that a question is not worth what the file claims.
        """
        _assessment, question_3, _dims, question_2 = self._paper()

        self.assertEqual(question_3._component_counts(), (3, 3))
        self.assertEqual(question_2._component_counts(), (2, 2))

    def test_an_unanswered_question_still_costs_its_marks(self):
        """THE case: 2 questions worth 3 and 2, one response row, total 5.

        The candidate answered the 3-mark question perfectly and never opened
        the 2-mark one. The paper is 5 marks and they scored 3 - 60%, a FAIL
        against a 70 bar. Under the old answers-derived denominator this read
        3 out of 3 and passed at 100%.
        """
        assessment, question_3, dims, question_2 = self._paper()
        evaluator = self._evaluator(assessment, question_3 + question_2)
        self._answer_all_parts(evaluator, question_3, dims)
        evaluator.state = "submitted"

        possible, raw_possible = evaluator._paper_component_totals()

        self.assertEqual(
            possible, 5,
            "the paper is worth 3 + 2 whether or not the candidate opened "
            "the second question - the denominator is the draw, not the "
            "answers")
        self.assertEqual(
            raw_possible, 5,
            "the raw is quoted out of the same paper as the mark - an "
            "abandoned question occupies its share of BOTH totals")
        self.assertEqual(evaluator.score_marks_display, "3 / 5")
        self.assertEqual(evaluator.score_percent, 60.0)
        self.assertEqual(
            evaluator.result, "fail",
            "an abandoned question has to be able to fail an attempt")

    def test_answering_the_second_question_does_not_change_the_total(self):
        """The denominator is a property of the paper, not of progress.

        A total that moved as answers arrived would mean a candidate's score
        was measured against a different paper at every point in the sitting.
        """
        assessment, question_3, dims, question_2 = self._paper()
        evaluator = self._evaluator(assessment, question_3 + question_2)
        self._answer_all_parts(evaluator, question_3, dims)

        before, raw_before = evaluator._paper_component_totals()

        verdict = question_2.question_dimension_ids[0]
        self.Response.create({
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": evaluator.applicant_id.id,
            "question_id": question_2.id,
            "assessment_id": assessment.id,
            "state": "submitted",
            "justification": "B is sharper and follows the brief.",
            "llm_raw_100": 90.0,
            "llm_state": "scored",
            "line_ids": [(0, 0, {
                "question_dimension_id": verdict.id,
                "selected_option_id":
                    verdict.option_line_ids.sorted("sequence")[0].id})],
        })
        evaluator.state = "submitted"

        after, raw_after = evaluator._paper_component_totals()

        self.assertEqual((before, raw_before), (5, 5))
        self.assertEqual((after, raw_after), (5, 5))
        self.assertEqual(evaluator.score_marks_display, "5 / 5")
        self.assertEqual(evaluator.result, "pass")

    def test_a_candidate_who_opened_nothing_is_scored_out_of_the_whole_paper(
            self):
        """No response rows at all, and the paper is still worth 5.

        This is the shape the denominator CANNOT be derived from the answers
        for: there is nothing to derive it from. It is also the case that used
        to divide by zero into a 0% rather than reading the draw.
        """
        assessment, question_3, _dims, question_2 = self._paper()
        evaluator = self._evaluator(assessment, question_3 + question_2)

        self.assertEqual(evaluator._paper_component_totals(), (5, 5))
        self.assertEqual(evaluator.score_marks_display, "0 / 5")

    def test_the_response_row_fallback_is_only_for_a_paper_never_drawn(self):
        """The documented fallback, pinned so it stays a fallback.

        An evaluator row created but never launched has no `question_order`,
        and `_paper_component_totals` then counts the response rows. That is
        the ONLY branch where the answers decide the total, and it reads 3
        here - which is precisely the wrong number for a launched attempt.
        Pinning it names the branch, so a change that widened it to the normal
        path (or narrowed it to nothing, breaking un-launched rows) shows up
        as a failure with this docstring attached rather than as a silent
        return to attempt 740.
        """
        assessment, question_3, dims, question_2 = self._paper()
        never_drawn = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": self.Applicant.create({
                "partner_name": "Never drawn %s" % uuid4().hex[:6],
                "email_from": "nd_%s@example.com" % uuid4().hex[:8],
            }).id,
        })
        self.assertFalse(never_drawn.question_order)
        self._answer_all_parts(never_drawn, question_3, dims)

        self.assertEqual(
            never_drawn._paper_component_totals(), (3, 3),
            "with no draw recorded there is nothing but the answers to count")

        # And the moment a draw IS recorded, the paper's real length wins.
        never_drawn.question_order = json.dumps((question_3 + question_2).ids)
        self.assertEqual(never_drawn._paper_component_totals(), (5, 5))
