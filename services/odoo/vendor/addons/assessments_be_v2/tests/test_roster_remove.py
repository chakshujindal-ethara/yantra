"""The Candidates table's Remove button, which never worked.

TWO DEFECTS IN ONE. The widget has always called
`action_remove_from_assessment` on `assessments.be.evaluator`, and this module
never defined it - the only copy lives on `etp_assessment_pro`, which this
model does not inherit. Every press raised a server error.

And the obvious port would have been wrong. A candidate is attached to an
assessment TWICE: the evaluator row (their sitting) and the `evaluator_ids`
m2m (the roster). Upstream unlinks only the first, and `_sync_roster_rows`
then rebuilds the attempt from the surviving m2m entry - so the candidate
reappears the next time anything touches the assessment, which reads as the
button not working rather than as a bug.

TransactionCase, matching the house style: the assertion is about the model
method the button calls.
"""
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestRosterRemove(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Applicant = self.env["hr.applicant"]
        self.Evaluator = self.env["assessments.be.evaluator"]

    def _applicant(self, name="Asha Rao"):
        return self.Applicant.create({
            "partner_name": name,
            "email_from": "%s_%s@example.com" % (
                name.split()[0].lower(), uuid4().hex[:8]),
        })

    def _assessment_with(self, applicant):
        assessment = self.Assessment.create({
            "name": "Roster %s" % uuid4().hex[:6],
            "duration_minutes": 30,
            "evaluator_ids": [(6, 0, applicant.ids)],
        })
        attempt = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        return assessment, attempt

    # ------------------------------------------------------------------
    def test_removing_drops_the_roster_link_as_well_as_the_attempt(self):
        """The half an obvious port gets wrong.

        Leave the m2m entry behind and `_sync_roster_rows` rebuilds the
        attempt, so the candidate comes back and the button looks broken.
        """
        applicant = self._applicant()
        assessment, attempt = self._assessment_with(applicant)

        attempt.action_remove_from_assessment()

        self.assertFalse(attempt.exists(), "the sitting should be gone")
        self.assertNotIn(
            applicant, assessment.evaluator_ids,
            "the roster link must go too, or the attempt is recreated")

        assessment._sync_roster_rows()
        self.assertFalse(
            self.Evaluator.search([("assessment_id", "=", assessment.id)]),
            "a removed candidate must not come back on the next sync")

    def test_a_submitted_sitting_is_refused_by_name(self):
        """Answers, a score and a violation history, with no undo."""
        applicant = self._applicant("Ravi Kumar")
        _assessment, attempt = self._assessment_with(applicant)
        attempt.state = "submitted"

        with self.assertRaises(UserError) as caught:
            attempt.action_remove_from_assessment()

        self.assertIn("Ravi Kumar", str(caught.exception))
        self.assertTrue(attempt.exists())

    def test_a_locked_pending_sitting_is_refused(self):
        """Stricter than upstream, deliberately.

        Upstream refuses only `state != pending`. A PENDING attempt the
        proctor locked is still a finding about a person, and this module's
        own API route already treats it as untouchable.
        """
        applicant = self._applicant()
        _assessment, attempt = self._assessment_with(applicant)
        attempt.is_locked = True

        with self.assertRaises(UserError):
            attempt.action_remove_from_assessment()

        self.assertTrue(attempt.exists())

    def test_a_started_sitting_is_refused(self):
        applicant = self._applicant()
        _assessment, attempt = self._assessment_with(applicant)
        attempt.started_at = "2026-08-19 10:00:00"

        with self.assertRaises(UserError):
            attempt.action_remove_from_assessment()

        self.assertTrue(attempt.exists())

    def test_one_touched_sitting_refuses_the_whole_batch(self):
        """All or nothing, so a bulk Remove cannot half-succeed silently."""
        keep, drop = self._applicant("Held One"), self._applicant("Free One")
        assessment = self.Assessment.create({
            "name": "Roster %s" % uuid4().hex[:6],
            "duration_minutes": 30,
            "evaluator_ids": [(6, 0, (keep + drop).ids)],
        })
        held = self.Evaluator.create({
            "assessment_id": assessment.id, "applicant_id": keep.id,
            "state": "submitted",
        })
        free = self.Evaluator.create({
            "assessment_id": assessment.id, "applicant_id": drop.id,
        })

        with self.assertRaises(UserError):
            (held + free).action_remove_from_assessment()

        self.assertTrue(free.exists(), "nothing is removed when one is held")
