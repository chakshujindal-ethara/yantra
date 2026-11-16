# -*- coding: utf-8 -*-
"""A candidate on the roster is a candidate who is assigned, and vice versa.

THE DEFECT THIS PINS, reproduced from the back office in four clicks:
Assign Candidates > Add a line > pick a candidate > Save, then Launch & Invite
answers "Please assign at least one candidate before starting" while the Roster
table underneath the dialog shows that candidate, their email and a Pending
badge.

`assessments.be` carries the same fact twice - the `evaluator_ids` m2m to
`hr.applicant` ("assigned") and `assessment_evaluator_ids`, the one2many of
attempt rows ("the roster"). `_sync_roster_rows` went m2m -> roster and nothing
went back, so the tab's inline list - which edits the one2many directly - wrote
a roster row and left the m2m empty. `action_start` gates on the m2m.

`action_remove_from_assessment` already states the rule for the REMOVE
direction ("BOTH LINKS, not just the attempt row") and drops both. This is the
same rule for ADD.
"""
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestTheRosterAndTheAssignmentAgree(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Roster fixture %s" % uuid4().hex[:6]})
        self.question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Answer it.",
            "difficulty": "easy",
            "generator_id": self.generator.id,
        })

    def _draft(self):
        return self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, self.question.ids)],
            "state": "draft",
            "duration_minutes": 30,
        })

    def _applicant(self):
        return self.Applicant.create({
            "partner_name": "Roster Person",
            "email_from": "r_%s@example.com" % uuid4().hex[:8],
        })

    def test_a_roster_row_added_by_the_tab_also_assigns(self):
        """The o2m command the Assign Candidates inline list actually sends."""
        asm = self._draft()
        applicant = self._applicant()

        asm.write({"assessment_evaluator_ids": [(0, 0, {
            "applicant_id": applicant.id})]})

        self.assertEqual(
            len(asm.assessment_evaluator_ids), 1, "the fixture wrote no row")
        self.assertIn(
            applicant, asm.evaluator_ids,
            "the roster shows this candidate but the assessment does not "
            "consider them assigned - which is what refuses the launch")

    def test_such_a_paper_actually_launches(self):
        """THE OPERATOR-VISIBLE HALF, and the reason the sync matters.

        Asserting the m2m alone would pass against a fix that set the field but
        left launch broken for some other reason."""
        asm = self._draft()
        applicant = self._applicant()
        asm.write({"assessment_evaluator_ids": [(0, 0, {
            "applicant_id": applicant.id})]})

        asm.action_start()

        self.assertEqual(asm.state, "in_progress")

    def test_the_launched_candidate_is_actually_served_a_paper(self):
        """Past the gate, the draw loop iterates `evaluator_ids` too.

        A fix that only satisfied the gate would launch a paper whose candidate
        has no `question_order` and no invitation - worse than the refusal,
        because it looks like it worked."""
        asm = self._draft()
        applicant = self._applicant()
        asm.write({"assessment_evaluator_ids": [(0, 0, {
            "applicant_id": applicant.id})]})

        asm.action_start()

        row = asm.assessment_evaluator_ids
        self.assertEqual(len(row), 1, "launch duplicated the roster row")
        self.assertTrue(
            row.question_order,
            "the candidate was launched with no questions drawn")
        self.assertEqual(row.invite_state, "queued")

    def test_a_directly_created_row_assigns_too(self):
        """The API and the CSV import reach `create` without the o2m command."""
        asm = self._draft()
        applicant = self._applicant()

        self.Evaluator.create({
            "assessment_id": asm.id, "applicant_id": applicant.id})

        self.assertIn(applicant, asm.evaluator_ids)

    def test_the_m2m_route_still_works_and_makes_no_duplicate(self):
        """THE GUARD ON THE GUARD. `_sync_roster_rows` creates rows from the
        m2m; this creates m2m entries from rows. They must not bounce."""
        asm = self._draft()
        applicant = self._applicant()

        asm.write({"evaluator_ids": [(6, 0, [applicant.id])]})
        asm._sync_roster_rows()

        self.assertEqual(len(asm.evaluator_ids), 1)
        self.assertEqual(
            len(asm.assessment_evaluator_ids), 1,
            "the two syncs produced more than one row for one person")

    def test_removing_still_drops_both_halves(self):
        """The remove direction already worked; adding the inverse must not
        resurrect anybody. A candidate left in the m2m comes back the next time
        anything calls `_sync_roster_rows`."""
        asm = self._draft()
        applicant = self._applicant()
        asm.write({"assessment_evaluator_ids": [(0, 0, {
            "applicant_id": applicant.id})]})
        self.assertIn(applicant, asm.evaluator_ids)

        asm.assessment_evaluator_ids.action_remove_from_assessment()

        self.assertNotIn(
            applicant, asm.evaluator_ids,
            "the candidate is still assigned, so the roster row returns")
        asm._sync_roster_rows()
        self.assertFalse(
            asm.assessment_evaluator_ids, "the removed candidate came back")

    def test_an_empty_paper_is_still_refused(self):
        """The gate must still fire when there genuinely is nobody."""
        asm = self._draft()
        with self.assertRaises(UserError) as caught:
            asm.action_start()
        self.assertIn("assign at least one candidate", str(caught.exception))
