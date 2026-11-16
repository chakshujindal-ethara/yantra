"""A retired question must never be drawn into a NEW paper.

`retired` is the operator's "delete" for a question that history still points
at. `response.question_id` is ondelete="cascade", so actually unlinking one
destroys the answers given to it and silently rewrites scores already recorded;
retiring takes it out of the BANK instead and leaves every past paper intact.

That split is the whole design, and it is only one `("retired", "=", False)`
clause in `action_start` wide. Delete that clause and nothing raises - the next
launch simply serves a retired question to a fresh cohort, which no other test
would catch. These tests fail loudly instead.

The asymmetry is asserted here too: OUT of the bank, still IN history. A paper
already built keeps resolving the question, because filtering it there would
shrink a live instrument and rewrite recorded scores.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestRetiredNotDrawn(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Generator = self.env["assessments.be.prompt"]
        self.Question = self.env["assessments.be.question"]
        self.Assessment = self.env["assessments.be"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.Generator.create(
            {"name": "Forklift SOP %s" % uuid4().hex[:6]})

    def _question(self, retired=False):
        """An mcq with a REAL answer key.

        A dimensionless mcq is rejected by `action_start`'s keyless gate - it
        can never be answered correctly by anyone - so a fixture without a key
        cannot be launched.
        """
        q = self.Question.create({
            "name": "Battery charging %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "What does the SOP require before charging a battery?",
            "generator_id": self.generator.id,
            "retired": retired,
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

    def _draft(self, **vals):
        applicant = self.Applicant.create({
            "partner_name": "Asha Rao",
            "email_from": "asha_%s@example.com" % uuid4().hex[:8],
        })
        base = {
            "name": "Warehouse Safety %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "evaluator_ids": [(6, 0, applicant.ids)],
        }
        base.update(vals)
        return self.Assessment.create(base)

    # ------------------------------------------------------------------
    # The draw
    # ------------------------------------------------------------------
    def test_a_retired_question_is_not_drawn_into_a_new_paper(self):
        live = self._question()
        retired = self._question(retired=True)
        assessment = self._draft()

        assessment.action_start()

        self.assertIn(live, assessment.question_ids)
        self.assertNotIn(
            retired, assessment.question_ids,
            "a retired question was drawn into a new paper - the "
            "('retired', '=', False) clause in action_start is gone")

    def test_the_exclusion_does_not_leak_outside_the_draw(self):
        """The exclusion must scope to the draw and nothing else.

        An ordinary search is how every other read reaches a question - the
        bank list, an in-flight paper, scoring. If the exclusion ever became
        global (an `active`-style filter, or a default domain), retiring would
        stop being reversible bookkeeping and start destroying access to
        history.
        """
        retired = self._question(retired=True)
        self.assertIn(
            retired, self.Question.search([("id", "=", retired.id)]),
            "a plain search must still find a retired question")
        self.assertEqual(
            self.Question.search_count([("id", "=", retired.id)]), 1)

    def test_a_paper_already_built_keeps_its_retired_question(self):
        """Retiring AFTER a launch must not shrink the live instrument."""
        q1, q2 = self._question(), self._question()
        assessment = self._draft()
        assessment.action_start()
        self.assertEqual(len(assessment.question_ids), 2)

        q2.retired = True
        assessment.invalidate_recordset()

        self.assertEqual(
            len(assessment.question_ids), 2,
            "retiring a question emptied it out of a paper that was already "
            "built - that is the damage `retired` exists to avoid, and is why "
            "it is not Odoo's `active`")
        self.assertIn(q2, assessment.question_ids)

    # ------------------------------------------------------------------
    # What the operator is told
    # ------------------------------------------------------------------
    def test_the_availability_count_matches_what_the_launch_would_draw(self):
        """The count sizes "Number of Questions"; a count the draw then refuses
        to honour promises a paper that never gets built."""
        self._question()
        self._question(retired=True)
        assessment = self._draft()
        assessment.invalidate_recordset()
        self.assertEqual(assessment.total_questions_available, 1)

    def test_retiring_everything_says_so_instead_of_crying_empty(self):
        self._question(retired=True)
        assessment = self._draft()
        with self.assertRaises(Exception) as caught:
            assessment.action_start()
        self.assertIn(
            "retired", str(caught.exception).lower(),
            "an operator who just retired the last question must be told that, "
            "not sent looking for a deletion that never happened")

    # ------------------------------------------------------------------
    # The two buttons the Odoo form offers, and why they are not the same
    # ------------------------------------------------------------------
    def test_retiring_keeps_the_question_on_papers_already_built(self):
        """`action_retire_from_bank` is the Odoo form's Archive button.

        The point of the whole design, asserted from the button an operator
        actually presses rather than only from the delete path: the question
        leaves the bank and the paper keeps it.
        """
        q = self._question()
        assessment = self._draft(question_ids=[(6, 0, q.ids)])

        q.action_retire_from_bank()

        self.assertTrue(q.retired)
        self.assertTrue(q.active, "retiring is not archiving")
        self.assertIn(
            q, assessment.question_ids,
            "a retired question must stay on the paper that already uses it",
        )

    def test_archiving_a_question_empties_it_off_the_paper(self):
        """WHY THE ODOO FORM MUST NOT OFFER A BARE `active` CHECKBOX.

        This is the damage, asserted rather than described. `question_ids` is a
        plain m2m with no `active_test` override, so Odoo drops an archived
        question out of every assessment holding it - a paper already sat
        silently becomes a paper with one fewer question. `active` is therefore
        `invisible="1"` on the question form and the header offers Archive
        (retire) instead. If this test ever fails, that reasoning has changed
        and the form can be reconsidered.
        """
        q = self._question()
        assessment = self._draft(question_ids=[(6, 0, q.ids)])
        self.assertIn(q, assessment.question_ids)

        q.active = False
        assessment.invalidate_recordset()

        self.assertNotIn(
            q, assessment.question_ids,
            "archiving must still be the thing retiring exists to avoid - if "
            "Odoo has stopped filtering archived records out of relational "
            "reads, the question form's hidden `active` field can be revisited",
        )

    def test_restore_is_the_way_back(self):
        q = self._question(retired=True)

        q.action_restore_to_bank()

        self.assertFalse(q.retired)
        assessment = self._draft()
        assessment.invalidate_recordset()
        self.assertEqual(
            assessment.total_questions_available, 1,
            "a restored question is drawable again",
        )
