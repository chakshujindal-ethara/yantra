"""Launching an assessment fills the roster row instead of duplicating it.

THE BUG THIS EXISTS FOR. `_sync_roster_rows` gives every assigned candidate an
`assessments.be.evaluator` row the moment they are assigned - added so a draft's
roster is not empty straight after a CSV import. `action_start` was never
updated to match: it still created one row per candidate unconditionally, which
collides with the (assessment_id, applicant_id) unique index:

    duplicate key value violates unique constraint
    "assessments_be_evaluator_uniq_assess_appl"

`POST /api/v1/assessments/<id>/launch` answered 500, and retrying could never
help - the blocking row is the one assignment itself had written. Every draft
whose candidates were assigned through the app was impossible to launch.

Nothing covered this: the model tests build evaluator rows directly and never
run assign-then-launch, which is the only order a person can actually use.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestLaunchFillsRosterRow(TransactionCase):
    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Generator = self.env["assessments.be.prompt"]

    def _applicant(self, name):
        slug = "%s_%s" % (name.lower().replace(" ", "_"), uuid4().hex[:8])
        return self.env["hr.applicant"].create({
            "partner_name": name,
            "email_from": "%s@example.com" % slug,
        })

    def _generator_with_questions(self, count=5):
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        for i in range(count):
            q = self.Question.create({
                "name": "Q%d" % i,
                "question_type": "mcq",
                "prompt": "Pick one",
                "difficulty": "easy",
                "generator_id": gen.id,
            })
            self.QDim.create({
                "question_id": q.id,
                "name": "Dim %d" % i,
                "option_line_ids": [
                    (0, 0, {"name": n, "sequence": j * 10,
                            "is_correct": j == 0})
                    for j, n in enumerate(("Alpha", "Bravo"))
                ],
            })
        return gen

    def _draft_with_assigned_candidates(self, how_many=3, questions=5):
        """A draft in the state the APP leaves it in: candidates assigned, so
        `_sync_roster_rows` has already written a roster row for each."""
        gen = self._generator_with_questions(questions)
        applicants = [self._applicant("Cand %d" % i) for i in range(how_many)]
        assessment = self.Assessment.create({
            "name": "Launch %s" % uuid4().hex[:6],
            "generator_id": gen.id,
            "question_limit": questions,
            "evaluator_ids": [(6, 0, [a.id for a in applicants])],
        })
        assessment._sync_roster_rows()
        assessment.invalidate_recordset()
        return assessment, applicants

    def test_the_fixture_reproduces_the_pre_launch_state(self):
        """Guard the guard: if assignment stops writing roster rows, the test
        below would pass for the wrong reason."""
        assessment, applicants = self._draft_with_assigned_candidates()
        self.assertEqual(len(assessment.assessment_evaluator_ids),
                         len(applicants),
                         "assignment must pre-create the roster rows")
        self.assertFalse(
            any(assessment.assessment_evaluator_ids.mapped("question_order")),
            "a roster row carries no question draw before launch")

    def test_launch_does_not_duplicate_a_pre_created_roster_row(self):
        assessment, applicants = self._draft_with_assigned_candidates()

        assessment.action_start()
        assessment.invalidate_recordset()

        rows = assessment.assessment_evaluator_ids
        self.assertEqual(len(rows), len(applicants),
                         "launch must FILL each roster row, not add a second")
        self.assertEqual(
            sorted(rows.mapped("applicant_id").ids),
            sorted(a.id for a in applicants))
        self.assertEqual(assessment.state, "in_progress")

    def test_launch_draws_questions_and_queues_the_invite(self):
        assessment, _ = self._draft_with_assigned_candidates(questions=5)

        assessment.action_start()
        assessment.invalidate_recordset()

        for row in assessment.assessment_evaluator_ids:
            self.assertTrue(row.question_order,
                            "a filled row must carry its own draw")
            self.assertEqual(row.invite_state, "queued",
                             "launch queues the invitation")
            self.assertTrue(row.access_token)

    def test_launch_keeps_the_token_the_roster_row_already_had(self):
        """`access_token` defaults to a uuid at create, so a roster row is
        already carrying the link `candidate_link` computes and the roster's
        Copy candidate link hands out. Minting a new one at launch would void a
        link an admin may already have sent on."""
        assessment, _ = self._draft_with_assigned_candidates()
        before = {e.applicant_id.id: e.access_token
                  for e in assessment.assessment_evaluator_ids}
        self.assertTrue(all(before.values()), "roster rows arrive with tokens")

        assessment.action_start()
        assessment.invalidate_recordset()

        after = {e.applicant_id.id: e.access_token
                 for e in assessment.assessment_evaluator_ids}
        self.assertEqual(after, before)

    def test_launch_still_works_when_no_roster_row_exists(self):
        """The old path, which must keep working: a record whose candidates
        were attached without `_sync_roster_rows` ever running."""
        gen = self._generator_with_questions(5)
        applicants = [self._applicant("Direct %d" % i) for i in range(2)]
        assessment = self.Assessment.create({
            "name": "NoRoster %s" % uuid4().hex[:6],
            "generator_id": gen.id,
            "question_limit": 5,
            "evaluator_ids": [(6, 0, [a.id for a in applicants])],
        })
        assessment.assessment_evaluator_ids.unlink()
        assessment.invalidate_recordset()
        self.assertFalse(assessment.assessment_evaluator_ids)

        assessment.action_start()
        assessment.invalidate_recordset()

        self.assertEqual(len(assessment.assessment_evaluator_ids),
                         len(applicants))
        self.assertTrue(
            all(assessment.assessment_evaluator_ids.mapped("question_order")))
