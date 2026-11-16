"""Saving an answer must never hand the paper in.

THE REPORTED BUG. A candidate answered every question, pressed PREVIOUS, and
the assessment submitted itself. They were right that it was not their doing,
and right that at that point any button would have done it: every navigation in
the runner POSTs the current answer, `action_submit` promoted the response to
'submitted', and `_check_all_submitted` locked the evaluator the instant the
submitted count reached `total_questions`. Answering the last question WAS
finishing the exam - the review screen could be reached, but only after the
paper had already been taken away.

The same report reached upstream's Odoo portal (e1b4f58, "fix: previous auto
submit bug") and was fixed there by demanding proof of intent on the finish
route. This fork's runner never touches that route; the equivalent here is
refusing to treat a SAVE as a FINISH.

What these tests pin, in order of how much they would cost to get wrong:

  * answering the LAST question leaves the attempt open and writable;
  * a second save after that - which is what Previous/Next actually send -
    still leaves it open;
  * the explicit /submit path still settles it;
  * expiry still settles it WITHOUT the candidate's consent, because a
    deadline that needs a click is not a deadline.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAnswerDoesNotSubmit(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Generator = self.env["assessments.be.prompt"]
        self.Question = self.env["assessments.be.question"]
        self.Assessment = self.env["assessments.be"]
        self.Applicant = self.env["hr.applicant"]
        self.Response = self.env["assessments.be.response"]
        self.generator = self.Generator.create(
            {"name": "Forklift SOP %s" % uuid4().hex[:6]})

    def _question(self):
        """An mcq with a real answer key - a keyless one cannot be launched."""
        q = self.Question.create({
            "name": "Battery charging %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "What does the SOP require before charging a battery?",
            "generator_id": self.generator.id,
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": q.id,
            "name": "Correctness",
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": i * 10, "is_correct": i == 0})
                for i, n in enumerate(("Vent the bay", "Ignore it", "Refuel"))
            ],
        })
        return q

    def _launched(self, count=2):
        """A launched assessment of `count` questions, and its one evaluator."""
        for _ in range(count):
            self._question()
        applicant = self.Applicant.create({
            "partner_name": "Asha Rao",
            "email_from": "asha_%s@example.com" % uuid4().hex[:8],
        })
        assessment = self.Assessment.create({
            "name": "Warehouse Safety %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "evaluator_ids": [(6, 0, applicant.ids)],
        })
        assessment.action_start()
        evaluator = assessment.assessment_evaluator_ids[0]
        return assessment, evaluator

    def _answer(self, evaluator, question):
        """Answer one question the way the runner does: create, then submit."""
        dimension = question.question_dimension_ids[0]
        correct = dimension.option_line_ids.filtered("is_correct")[0]
        existing = self.Response.search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "=", question.id),
        ], limit=1)
        response = existing or self.Response.create({
            "assessment_evaluator_id": evaluator.id,
            # The APPLICANT, required alongside the attempt: the model keeps
            # both so a response resolves to a person even if the attempt row
            # is later rebuilt.
            "evaluator_id": evaluator.applicant_id.id,
            "assessment_id": evaluator.assessment_id.id,
            "question_id": question.id,
            "line_ids": [(0, 0, {
                "question_dimension_id": dimension.id,
                "selected_option_id": correct.id,
            })],
        })
        response.action_submit()
        return response

    # ------------------------------------------------------------------
    # The bug
    # ------------------------------------------------------------------
    def test_answering_every_question_leaves_the_attempt_open(self):
        assessment, evaluator = self._launched(count=2)
        for question in assessment.question_ids:
            self._answer(evaluator, question)
        evaluator.invalidate_recordset()

        self.assertFalse(
            evaluator.is_locked,
            "answering the last question handed the paper in - the candidate "
            "never reached the review screen, and any button pressed "
            "afterwards was submitting their exam")
        self.assertNotEqual(evaluator.state, "submitted")

    def test_navigating_after_the_last_answer_still_leaves_it_open(self):
        """THE REPORTED SEQUENCE, at the layer that produced it.

        Previous re-POSTs the current answer, which reaches an ALREADY
        submitted response - so `_update_response` rewrites it in place rather
        than calling `action_submit` a second time (that raises "This response
        is already submitted"). The rewrite is what used to re-trigger the
        all-answered check and settle the paper.
        """
        assessment, evaluator = self._launched(count=2)
        for question in assessment.question_ids:
            self._answer(evaluator, question)

        # The Previous press: the last answer is written again, unchanged.
        last = assessment.question_ids[-1]
        response = self.Response.search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "=", last.id),
        ], limit=1)
        self.assertEqual(response.state, "submitted")
        dimension = last.question_dimension_ids[0]
        correct = dimension.option_line_ids.filtered("is_correct")[0]
        response.line_ids.unlink()
        response.write({"line_ids": [(0, 0, {
            "question_dimension_id": dimension.id,
            "selected_option_id": correct.id,
        })]})
        evaluator.invalidate_recordset()

        self.assertFalse(
            evaluator.is_locked,
            "pressing Previous on a fully answered paper submitted it")

    def test_the_answers_are_still_recorded(self):
        """The fix must not cost the saving, only the settling."""
        assessment, evaluator = self._launched(count=2)
        for question in assessment.question_ids:
            self._answer(evaluator, question)

        submitted = self.Response.search_count([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("state", "=", "submitted"),
        ])
        self.assertEqual(submitted, 2, "answers stopped being saved")

    # ------------------------------------------------------------------
    # The paths that MUST still end an attempt
    # ------------------------------------------------------------------
    def test_the_explicit_submit_still_settles_the_attempt(self):
        assessment, evaluator = self._launched(count=2)
        for question in assessment.question_ids:
            self._answer(evaluator, question)

        evaluator.sudo()._auto_submit_expired()
        evaluator.invalidate_recordset()

        self.assertTrue(
            evaluator.is_locked,
            "the candidate can no longer finish their own exam")
        self.assertEqual(evaluator.state, "submitted")

    def test_settling_an_unanswered_paper_still_works(self):
        """Expiry must not need the candidate's consent, or a walked-away tab
        never settles and the assessment never completes."""
        _assessment, evaluator = self._launched(count=2)

        evaluator.sudo()._auto_submit_expired()
        evaluator.invalidate_recordset()

        self.assertTrue(evaluator.is_locked)
        # Every unanswered question is stamped, so the grader sees a blank
        # rather than a missing row.
        self.assertEqual(
            self.Response.search_count([
                ("assessment_evaluator_id", "=", evaluator.id),
                ("state", "=", "submitted"),
            ]), 2)
