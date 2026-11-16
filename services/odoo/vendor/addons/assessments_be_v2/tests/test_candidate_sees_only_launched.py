"""What reaches a candidate's own "My assessments" list, and what must not.

TWO SEPARATE LEAKS, both of which put a Start button in front of a candidate
that could only ever fail.

THE DRAFT LEAK. Assigning a candidate calls `_sync_roster_rows`, which creates
the `assessments.be.evaluator` row IMMEDIATELY - before launch, on purpose,
because the Odoo candidates table reads those rows rather than the m2m roster.
The candidate routes then listed every evaluator row for the applicant, so
merely putting somebody on the roster of a draft published that draft to them
while the operator was still deciding whether to launch it. Nothing is promised
until launch: that is the act that freezes the paper, mints the token and sends
the invitation. `_own_attempts` is the filter, and it is shared by the list, the
dashboard and the analytics so those three can never disagree.

THE BUCKET LEAK, which is the other half and lives in the client. The server
already files each attempt under a bucket, and `attempt_bucket` reads the
ASSESSMENT's state to do it - so an assessment marked done buckets as `closed`.
The Flutter client was re-deriving the bucket itself from an assessment record
it never loads (the assessment list is a manager route), so it defaulted every
un-started attempt to "Available". These tests pin the SERVER half: the bucket
on the wire has to be right, or the client has nothing correct to read.

TransactionCase, matching test_assessment_archive and test_question_delete: the
rules under test are the search domain and the bucket function, not transport.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api.serializers import (
    attempt_bucket,
)


@tagged("-at_install", "post_install")
class TestCandidateSeesOnlyLaunched(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.Applicant = self.env["hr.applicant"]
        self.Evaluator = self.env["assessments.be.evaluator"]

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _applicant(self):
        return self.Applicant.create({
            "partner_name": "Asha Rao",
            "email_from": "asha_%s@example.com" % uuid4().hex[:8],
        })

    def _question(self):
        return self.Question.create({
            "name": "Battery charging %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "What does the SOP require before charging a battery?",
        })

    def _assessment(self, state="draft"):
        asm = self.Assessment.create({
            "name": "Warehouse Safety %s" % uuid4().hex[:6],
            "question_ids": [(6, 0, self._question().ids)],
        })
        if state != "draft":
            asm.state = state
        return asm

    def _attempt(self, assessment, applicant):
        return self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })

    # The route helper's domain, exercised as the routes build it.
    def _visible(self, applicant):
        return self.Evaluator.sudo().search([
            ("applicant_id", "=", applicant.id),
            ("assessment_id.state", "!=", "draft"),
        ])

    # ------------------------------------------------------------------
    # The draft leak
    # ------------------------------------------------------------------
    def test_a_draft_assessment_is_not_shown_to_the_candidate(self):
        # Assigned but never launched. The roster row exists by design; it is
        # not a promise to the candidate, and it must not reach their list.
        applicant = self._applicant()
        draft = self._assessment("draft")
        ev = self._attempt(draft, applicant)

        self.assertTrue(ev.exists(), "the roster row is still created")
        self.assertNotIn(
            ev, self._visible(applicant),
            "a draft assessment must not appear on the candidate's list",
        )

    def test_a_launched_assessment_is_shown_to_the_candidate(self):
        applicant = self._applicant()
        live = self._assessment("in_progress")
        ev = self._attempt(live, applicant)

        self.assertIn(
            ev, self._visible(applicant),
            "a launched assessment must appear on the candidate's list",
        )

    def test_a_closed_assessment_is_still_shown_to_the_candidate(self):
        # HIDDEN IS WRONG HERE, and this is the pair to the draft test. A
        # candidate who was invited to something that has since closed is owed
        # the record of it - the fix for the draft leak must not swallow this.
        applicant = self._applicant()
        done = self._assessment("done")
        ev = self._attempt(done, applicant)

        self.assertIn(
            ev, self._visible(applicant),
            "a closed assessment must stay on the candidate's list",
        )

    def test_resetting_to_draft_withdraws_it_again(self):
        applicant = self._applicant()
        asm = self._assessment("in_progress")
        ev = self._attempt(asm, applicant)
        self.assertIn(ev, self._visible(applicant))

        asm.state = "draft"
        self.assertNotIn(
            ev, self._visible(applicant),
            "an assessment pulled back to draft is no longer being honoured, "
            "so it leaves the candidate's list with it",
        )

    # ------------------------------------------------------------------
    # The bucket the client reads
    # ------------------------------------------------------------------
    def test_a_closed_assessment_buckets_as_closed(self):
        # The bug the candidate saw: this bucketed correctly server-side all
        # along, and the client threw it away. Pinned so the wire stays right.
        applicant = self._applicant()
        ev = self._attempt(self._assessment("done"), applicant)

        self.assertEqual(attempt_bucket(ev), "closed")

    def test_a_live_assessment_buckets_as_available(self):
        applicant = self._applicant()
        ev = self._attempt(self._assessment("in_progress"), applicant)

        self.assertEqual(attempt_bucket(ev), "available")

    def test_a_cancelled_assessment_buckets_as_closed(self):
        # THE ONE THE CANDIDATE ACTUALLY HIT. "Mark done" is not the only way
        # an assessment ends - Cancel is right beside it - and `cancelled` used
        # to fall past every branch to the "upcoming" default. The candidate
        # was told an assessment that had been called off was still to come.
        applicant = self._applicant()
        ev = self._attempt(self._assessment("cancelled"), applicant)

        self.assertEqual(attempt_bucket(ev), "closed")

    def test_cancelled_and_done_read_the_same_to_a_candidate(self):
        # They are the same fact from the candidate's side: it is over and they
        # cannot sit it. Pinned so a future branch cannot split them again.
        applicant = self._applicant()
        done = self._attempt(self._assessment("done"), applicant)
        cancelled = self._attempt(self._assessment("cancelled"), applicant)

        self.assertEqual(attempt_bucket(done), attempt_bucket(cancelled))

    # `test_the_portal_and_the_api_agree_on_every_state` USED TO LIVE HERE.
    #
    # It instantiated `candidate_portal.EtpCandidatePortal` and compared
    # `_single_item(ev)["state"]` against `attempt_bucket(ev)` for three states,
    # because `attempt_bucket` was a PORT of that method and a fix applied to one
    # copy and not the other was the defect it existed to catch.
    #
    # The QWeb candidate pages are retired, so there is no second implementation
    # left to disagree with - `attempt_bucket` is now the only one. Deleted rather
    # than adapted: a test whose whole subject is agreement between two things
    # cannot be rewritten to be about one of them, and leaving it comparing
    # `attempt_bucket` to itself would have been a green test asserting nothing.
    # The bucketing rules themselves are covered by the cases around this note.

    def test_a_submitted_attempt_stays_completed_after_closing(self):
        # The branch order in `attempt_bucket` is load-bearing: what the
        # CANDIDATE did outranks what happened to the assessment afterwards.
        applicant = self._applicant()
        asm = self._assessment("in_progress")
        ev = self._attempt(asm, applicant)
        ev.state = "submitted"
        asm.state = "done"

        self.assertEqual(attempt_bucket(ev), "completed")
