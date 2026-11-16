"""Archiving an assessment, and what archiving must NOT touch.

WHY THIS EXISTS. `assessments.be.active` has carried archive semantics since
the model was written, but nothing in the product could set it - the console
had no route, and `assessment_update` deliberately refuses everything outside
`POST_DRAFT_FIELDS` once an assessment leaves draft. So the one assessment an
operator actually wants out of the way, a finished or running one, was the one
that could never be filed away. `/api/v1/assessments/<id>/archive` is that
route, and these are the tests that pin what it means.

ARCHIVING IS VISIBILITY, NOT LIFECYCLE, and that is the whole point. The row
leaves the default list and every figure built on it; the state machine, the
sitting window, and every evaluator, response and score stay exactly as they
were. An assessment that must STOP is cancelled - a different control with a
different meaning. `test_archiving_keeps_every_response_and_score` is the one
that matters: its failure mode is silent, irreversible loss of results that an
operator may already have hired or rejected somebody on.

THE 404 TRAP has its own test too. An archived record is invisible to an
ordinary `browse`, so a route that forgets `active_test=False` can archive
something it can then never restore - the call to put it back answers 404
forever. `test_an_archived_assessment_can_be_restored` fails on that
implementation.

TransactionCase rather than HttpCase, matching test_question_delete: the rule
under test is the model write and the domain it changes, not the transport.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAssessmentArchive(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.Applicant = self.env["hr.applicant"]
        self.Response = self.env["assessments.be.response"]

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _question(self, name="Battery charging"):
        # `prompt` is required=True on the model - a question with no text is
        # not a question - so the fixture has to carry one.
        return self.Question.create({
            "name": "%s %s" % (name, uuid4().hex[:6]),
            "question_type": "mcq",
            "prompt": "What does the SOP require before charging a battery?",
        })

    def _assessment(self, name="Warehouse Safety"):
        return self.Assessment.create({
            "name": "%s %s" % (name, uuid4().hex[:6]),
            "question_ids": [(6, 0, self._question().ids)],
        })

    def _answer(self, assessment):
        """One submitted answer - the thing that must never be lost."""
        applicant = self.Applicant.create({
            "partner_name": "Asha Rao",
            "email_from": "asha_%s@example.com" % uuid4().hex[:8],
        })
        return self.Response.create({
            "assessment_id": assessment.id,
            "evaluator_id": applicant.id,
            "question_id": assessment.question_ids[0].id,
            "justification": "Because the SOP says so.",
        })

    # The route's own body, so the test exercises the rule rather than a
    # paraphrase of it. `archive: false` is the restore direction.
    def _archive(self, assessment, archive=True):
        assessment.write({"active": not archive})

    # ------------------------------------------------------------------
    # What archiving does
    # ------------------------------------------------------------------
    def test_archiving_takes_it_out_of_the_default_list(self):
        asm = self._assessment()
        self._archive(asm)

        self.assertFalse(asm.active)
        self.assertNotIn(
            asm.id, self.Assessment.search([]).ids,
            "an archived assessment must be out of the default list",
        )

    def test_an_archived_assessment_is_found_with_include_archived(self):
        # The list route's `include_archived` switch is exactly this context,
        # and it is what makes the console's "Show archived" toggle - and so
        # the restore path - reachable at all.
        asm = self._assessment()
        self._archive(asm)

        self.assertIn(
            asm.id,
            self.Assessment.with_context(active_test=False).search([]).ids,
            "active_test=False must still find an archived assessment",
        )

    def test_an_archived_assessment_can_be_restored(self):
        # THE 404 TRAP. An archived row is invisible to an ordinary browse, so
        # the unarchive call has to reach it through `active_test=False` - the
        # route does, and this is what proves the record is still there to be
        # reached. Without it, archiving would be a one-way door.
        asm = self._assessment()
        asm_id = asm.id
        self._archive(asm)

        found = self.Assessment.with_context(
            active_test=False).browse(asm_id).exists()
        self.assertTrue(found, "an archived assessment must still exist")

        self._archive(found, archive=False)
        self.assertTrue(found.active)
        self.assertIn(
            asm_id, self.Assessment.search([]).ids,
            "a restored assessment must be back in the default list",
        )

    # ------------------------------------------------------------------
    # What archiving must NOT do
    # ------------------------------------------------------------------
    def test_archiving_keeps_every_response_and_score(self):
        # The one with a silent, irreversible failure mode. Nothing about a
        # candidate's answer may move because somebody tidied a list.
        asm = self._assessment()
        response = self._answer(asm)
        before = (response.justification, response.question_id.id,
                  response.assessment_id.id)

        self._archive(asm)

        self.assertTrue(
            response.exists(), "archiving must not delete a response")
        self.assertEqual(
            (response.justification, response.question_id.id,
             response.assessment_id.id),
            before,
            "archiving must leave every recorded answer exactly as it was",
        )

    def test_archiving_does_not_move_the_state_machine(self):
        # Archiving is visibility; cancelling is the control that stops a
        # sitting. Conflating them would file away a live exam by ending it.
        asm = self._assessment()
        asm.state = "in_progress"

        self._archive(asm)

        self.assertEqual(
            asm.state, "in_progress",
            "archiving must not cancel or otherwise re-state an assessment",
        )

    def test_a_live_sitting_can_be_archived(self):
        # Allowed in EVERY state on purpose. `assessment_update` refuses most
        # writes outside draft, which is why archiving is its own route - a
        # finished or running assessment is the usual reason to archive one.
        for state in ("draft", "in_progress", "done", "cancelled"):
            asm = self._assessment()
            asm.state = state
            self._archive(asm)
            self.assertFalse(
                asm.active, "archiving must work in state %r" % state)

    def test_archiving_keeps_the_questions_on_the_paper(self):
        # `question_ids` is a plain m2m and Odoo filters archived records out
        # of RELATIONAL reads - but the ARCHIVED record here is the assessment,
        # not the questions, so the paper it holds must be untouched.
        asm = self._assessment()
        before = asm.question_ids.ids

        self._archive(asm)

        self.assertEqual(
            asm.question_ids.ids, before,
            "archiving an assessment must not empty the paper it holds",
        )
