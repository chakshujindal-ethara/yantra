"""A paper is settled ONCE, by whoever gets there first, and it says so honestly.

THE DEFECT. `_auto_submit_expired` has six production callers and they pass
DIFFERENT reason codes: the deadline sweep and three expiry checks pass
"expired", proctoring passes its own, and the candidate's own /submit passes
none. Idempotency was resting on "two racers write the same values", which stops
being true the moment the values differ.

The interleaving that reaches production:

    T2  candidate's /submit reads is_locked = False
    T5  the violation cap settles and commits auto_submit_reason = 'violation'
    T7  the candidate's /submit settles - reason_code is None, so the key is
        absent from `vals` and 'violation' SURVIVES

So a paper the candidate handed in themselves is stamped as ended by a
proctoring violation. Reverse the order and a genuine violation reads as a clean
submit. `serializers.attempt_row` derives `auto_submitted` from that field, so
the candidate's completion screen and the reviewer's CSV export both carry the
wrong story - and an appeal is answered from it.

THE SECOND DEFECT, in the same three lines at the end of the function:

    evs = assessment.assessment_evaluator_ids
    if evs and all(e.state == "submitted" for e in evs):
        assessment.write({"state": "done"})

That wrote the ONE ROW THE WHOLE COHORT SHARES, inside the transaction that had
just written this candidate's settlement and their placeholder answers. Exams end
in a burst, so settlements collided on that row, and because the shared write
shared a transaction with the settlement, THE SETTLEMENT WAS DISCARDED TOO - the
candidate's paper was not handed in. Same family as the `response_count`
incident; see `models/assessment.py` on `response_count` for the measurements.

It also loaded every sibling row on every settlement to compute one boolean -
~1.4M row reads in the sharpest minute of a 1,200-candidate deadline.

Both now defer to `_cron_recompute_subjective_results`, which already owns this
exact flag-drain-commit pattern.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase


class TestSettlementIsSerialised(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        self.question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Explain your reasoning.",
            "generator_id": self.generator.id,
        })
        self.assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, self.question.ids)],
            "state": "in_progress",
        })

    def _attempt(self):
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "c_%s@example.com" % uuid4().hex[:8],
        })
        return self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": applicant.id,
            "question_order": "[%d]" % self.question.id,
        })

    # ── first settlement wins ────────────────────────────────────────────

    def test_a_second_settlement_does_not_overwrite_the_first_reason(self):
        """THE HEADLINE. A violation ending must survive a later plain submit.

        This is the T5-then-T7 order above. Before the guard the second call
        wrote state/is_locked again with no `auto_submit_reason` key, leaving the
        first caller's value in place by luck - and the reverse order CLEARED a
        real violation. Now the second call returns without writing at all, so
        neither order can rewrite history.
        """
        attempt = self._attempt()
        self.assertTrue(attempt._auto_submit_expired(reason_code="violation"))
        self.assertEqual(attempt.auto_submit_reason, "violation")

        # The candidate's own submit arrives second, with no reason code.
        self.assertFalse(
            attempt._auto_submit_expired(),
            "a settled attempt must refuse a second settlement")
        self.assertEqual(
            attempt.auto_submit_reason, "violation",
            "the FIRST settlement's cause is the true one")

    def test_the_reverse_order_cannot_invent_a_violation(self):
        """A clean submit first must not later be relabelled as a violation.

        The dangerous direction: this is what puts a proctoring breach that never
        happened into an audit trail an appeal is answered from.
        """
        attempt = self._attempt()
        self.assertTrue(attempt._auto_submit_expired())
        self.assertFalse(attempt.auto_submit_reason)

        self.assertFalse(attempt._auto_submit_expired(reason_code="violation"))
        self.assertFalse(
            attempt.auto_submit_reason,
            "a settled clean submit must not acquire a violation afterwards")

    def test_submitted_at_is_not_moved_by_a_later_settlement(self):
        """The timestamp overstates how long the candidate had, otherwise.

        `submitted_at` is stamped in a nested write in `write()` guarded on
        `not rec.submitted_at`, so two racers both saw it falsy and the later
        stamp won.
        """
        attempt = self._attempt()
        attempt._auto_submit_expired(reason_code="expired")
        first = attempt.submitted_at
        self.assertTrue(first)

        attempt._auto_submit_expired(reason_code="expired")
        self.assertEqual(attempt.submitted_at, first)

    def test_an_already_locked_attempt_is_refused_even_if_state_lags(self):
        """`is_locked` alone is enough to refuse.

        The guard reads BOTH columns because either one being set means somebody
        is mid-settlement, and reading only `state` would let a second caller in
        during the window between the two writes.
        """
        attempt = self._attempt()
        attempt.is_locked = True
        self.assertFalse(attempt._auto_submit_expired(reason_code="expired"))

    # ── the cohort rollup is off the settlement transaction ──────────────

    def test_settling_does_not_write_the_shared_assessment_state(self):
        """THE OTHER HEADLINE. Settling does not close the cohort.

        The candidate's paper is in, and the cohort-wide write - the one that
        used to collide and take the settlement with it - is left to a cron
        that holds no settlement. Settling writes no flag on the paper either
        (`test_settling_never_writes_the_shared_paper_row`).
        """
        attempt = self._attempt()
        attempt._auto_submit_expired(reason_code="expired")

        self.assertEqual(attempt.state, "submitted")
        self.assertEqual(
            self.assessment.state, "in_progress",
            "the settlement must NOT write the cohort's shared row")

    def test_the_cron_closes_the_cohort_once_everyone_is_in(self):
        """The deferred work still happens - a flag nobody drains is a leak."""
        a1, a2 = self._attempt(), self._attempt()
        a1._auto_submit_expired(reason_code="expired")

        self.env["assessments.be"]._cron_recompute_subjective_results(
            commit=False)
        self.assertEqual(
            self.assessment.state, "in_progress",
            "one candidate still outstanding")

        a2._auto_submit_expired(reason_code="expired")
        self.env["assessments.be"]._cron_recompute_subjective_results(
            commit=False)
        self.assertEqual(self.assessment.state, "done")
        self.assertFalse(self.assessment.cohort_close_stale)

    def test_an_assessment_with_nobody_assigned_is_never_closed(self):
        """`assigned` is load-bearing, not tidiness.

        The cron sweeps `in_progress` rows so a lost flag self-heals, which means
        it also sees live papers with nobody assigned yet. With a bare
        `not outstanding` those would flip to done - a paper NOBODY HAS SAT,
        closed. The inline version was safe from this only by accident, because a
        settlement implies an evaluator.
        """
        self.assertFalse(self.assessment.assessment_evaluator_ids)
        self.env["assessments.be"]._cron_recompute_subjective_results(
            commit=False)
        self.assertEqual(self.assessment.state, "in_progress")

    def test_the_cron_self_heals_a_lost_flag(self):
        """The flag is an optimisation; the `in_progress` sweep is the guarantee.

        Simulates the flag being cleared while a settlement is still outstanding -
        a stale ORM read, or a cron tick landing between the two. Without the
        sweep the cohort would sit `in_progress` with everybody submitted and no
        later event would ever revisit it.
        """
        attempt = self._attempt()
        attempt._auto_submit_expired(reason_code="expired")
        self.assessment.cohort_close_stale = False

        self.env["assessments.be"]._cron_recompute_subjective_results(
            commit=False)
        self.assertEqual(
            self.assessment.state, "done",
            "a lost flag must not lose the cohort")

    def test_the_cron_never_reopens_a_closed_assessment(self):
        """Only ever drives a close.

        An operator who has moved an assessment on must not have it dragged back
        by a late settlement.
        """
        self.assessment.state = "done"
        attempt = self._attempt()
        attempt._auto_submit_expired(reason_code="expired")
        self.env["assessments.be"]._cron_recompute_subjective_results(
            commit=False)
        self.assertEqual(self.assessment.state, "done")

    # ── the candidate's work is still settled correctly ──────────────────

    def test_placeholders_are_still_written_for_unanswered_questions(self):
        """The guard must not skip the actual work it protects."""
        attempt = self._attempt()
        attempt._auto_submit_expired(reason_code="expired")

        responses = self.env["assessments.be.response"].search(
            [("assessment_evaluator_id", "=", attempt.id)])
        self.assertEqual(len(responses), 1)
        self.assertTrue(responses.auto_submitted)
        self.assertEqual(responses.state, "submitted")
        self.assertIn("Auto-submitted", responses.justification)
