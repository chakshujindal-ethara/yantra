"""A Form Studio rubric is complete when its AXES are answered.

The IG Entity form asks six pick-one checks and then "explain any FAILED
check". A candidate who passed every check has nothing to explain, but the
completeness gate demanded prose from every subjective_rubric regardless of
whether it carried axes - so a fully answered paper was rejected:

  * the API answered 422 incomplete_answer,
  * the portal silently returned False,
  * action_submit raised "Please provide a justification".

The axes are the answer. Prose is still required for a rubric that has no
axes, because there the prose IS the whole answer.
"""
from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase


class TestARubricIsCompleteWhenItsAxesAreAnswered(TransactionCase):

    def setUp(self):
        super().setUp()
        self.assessment = self.env["assessments.be"].create({
            "name": "Axes completeness",
        })
        self.question = self.env["assessments.be.question"].create({
            "name": "Audit this sample against the checks",
            "prompt": "Audit this sample against the checks below.",
            "question_type": "subjective_rubric",
            "assessment_ids": [(4, self.assessment.id)],
        })
        self.dimension = self.env["assessments.be.question.dimension"].create({
            "name": "Is the picture sharp and clear?",
            "question_id": self.question.id,
            "input_kind": "multipleChoice",
        })
        self.option_yes = self.env[
            "assessments.be.question.dimension.option"].create({
                "name": "Yes",
                "question_dimension_id": self.dimension.id,
            })
        self.candidate = self.env["hr.applicant"].create({
            "partner_name": "Axes Candidate",
        })
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": self.candidate.id,
        })

    def _response(self, with_axis, justification=""):
        vals = {
            "question_id": self.question.id,
            "assessment_id": self.assessment.id,
            "evaluator_id": self.candidate.id,
            "assessment_evaluator_id": self.evaluator.id,
            "justification": justification,
        }
        if with_axis:
            vals["line_ids"] = [(0, 0, {
                "question_dimension_id": self.dimension.id,
                "selected_option_id": self.option_yes.id,
            })]
        return self.env["assessments.be.response"].create(vals)

    def test_axes_answered_with_no_prose_submits(self):
        """The whole point: six ticks and an empty box is a complete answer."""
        response = self._response(with_axis=True)
        response.action_submit()
        self.assertEqual(
            response.state, "submitted",
            "a rubric whose axes are answered is complete; demanding prose "
            "rejected a candidate who had passed every check")

    def test_a_rubric_with_no_axes_still_requires_prose(self):
        """Where prose IS the answer, it is still mandatory."""
        bare = self.env["assessments.be.question"].create({
            "name": "Explain your reasoning",
            "prompt": "Explain your reasoning in full.",
            "question_type": "subjective_rubric",
            "assessment_ids": [(4, self.assessment.id)],
        })
        response = self.env["assessments.be.response"].create({
            "question_id": bare.id,
            "assessment_id": self.assessment.id,
            "evaluator_id": self.candidate.id,
            "assessment_evaluator_id": self.evaluator.id,
            "justification": "",
        })
        with self.assertRaises(UserError):
            response.action_submit()

    def test_axes_present_but_unanswered_still_requires_prose(self):
        """An untouched paper is not complete just because axes exist."""
        response = self._response(with_axis=False)
        with self.assertRaises(UserError):
            response.action_submit()

    def test_prose_alone_is_held_while_an_axis_is_unanswered(self):
        """Owner, 2026-09-29: the axes are marks, so prose with every axis
        blank is not a complete answer - it waits as a draft (the API holds
        it; `action_submit` refuses it) instead of scoring 0 on each axis."""
        response = self._response(with_axis=False, justification="Looks fine.")
        with self.assertRaises(UserError):
            response.action_submit()

    def test_prose_submits_when_no_axis_has_options(self):
        """A Form Studio text item is an axis with nothing to pick: it can
        never be 'answered', so it must not hold the prose back."""
        self.option_yes.unlink()
        response = self._response(with_axis=False, justification="Looks fine.")
        response.action_submit()
        self.assertEqual(response.state, "submitted")
