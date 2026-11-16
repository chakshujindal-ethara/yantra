# -*- coding: utf-8 -*-
"""THE CANDIDATE'S OWN CARD LISTS EVERY BREACH, NOT ONLY THE LAST ONE.

WHY THIS FILE EXISTS. `attempt()` builds one row of the candidate's own 'My
Assessments' list. Its `proctoring` dict carried `violation_count` and
`violation_reason` - the count, and the LATEST reason. With only those two, the
client fell through to a legacy branch and printed

    "3 violations recorded. Last reason: Exited fullscreen."

on an attempt that had breached three DIFFERENT rules - naming one and hiding
the other two, on the one screen the candidate can actually see. The admin row
(`evaluator_admin_row`) has carried the full per-reason tally under
`flags.violations` all along; the candidate route was the half that lagged.

The fix added `"violations": violation_tally(evaluator)` to that same dict. This
test pins THREE things so the change is proven ADDITIVE, not a rewrite:

  * the new `violations` key equals the per-reason tally, ordered count
    descending, for a log holding several reasons;
  * it is `[]` - never a crash - for a null or empty log;
  * `violation_count` and `violation_reason` are still present and carry exactly
    what they always did.

The log is written directly here rather than through `_record_violation`, whose
1.2s same-reason burst dedupe would fold repeats of one reason into a single
count - this test needs a reason to appear more than once, which is the shape a
distribution is actually about.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import serializers as S


@tagged("-at_install", "post_install")
class TestCandidateCardCarriesTheViolationTally(TransactionCase):

    def setUp(self):
        super().setUp()
        generator = self.env["assessments.be.prompt"].create({"name": "Gen"})
        self.assessment = self.env["assessments.be"].create({
            "name": "Candidate tally probe",
            "generator_id": generator.id,
            "duration_minutes": 30,
            "violation_action": "log_only",
        })
        self.applicant = self.env["hr.applicant"].create({
            "partner_name": "Tally Probe",
            "email_from": "tallyprobe_%s@example.com" % uuid4().hex[:8],
        })
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": self.applicant.id,
        })

    def _proctoring(self):
        return S.attempt(self.evaluator)["proctoring"]

    def _write_log(self, reasons):
        """Seed violation_log directly with one entry per reason, bypassing the
        model's burst dedupe so a reason can legitimately appear twice."""
        self.evaluator.write({
            "violation_count": len(reasons),
            "violation_reason": reasons[-1] if reasons else False,
            "is_violated": bool(reasons),
            "violation_log": [
                {"reason": r, "at": "2026-01-01 00:00:0%d" % (i % 10)}
                for i, r in enumerate(reasons)
            ],
        })

    # ------------------------------------------------------------------
    # The new key: the full per-reason distribution
    # ------------------------------------------------------------------
    def test_the_card_carries_the_per_reason_tally_ordered_by_count(self):
        """Three breaches of two kinds -> two rows, most frequent first. This is
        exactly the distribution the legacy 'Last reason' line threw away."""
        self._write_log(["Exited fullscreen", "Switched tab", "Exited fullscreen"])
        proctoring = self._proctoring()

        self.assertEqual(
            proctoring["violations"],
            [{"reason": "Exited fullscreen", "count": 2},
             {"reason": "Switched tab", "count": 1}],
            "the candidate card must carry the full per-reason tally, ordered "
            "by count descending - not just the latest reason")

    def test_the_candidate_tally_matches_the_admin_row_exactly(self):
        """Both surfaces read the same evaluator; the candidate's card and the
        admin's flags must agree breach for breach, since they diverging is the
        whole class of bug this closes."""
        self._write_log(["Copy-paste", "Copy-paste", "Devtools", "Switched tab"])
        candidate = self._proctoring()["violations"]
        admin = S.evaluator_admin_row(self.evaluator)["flags"]["violations"]
        self.assertEqual(
            candidate, admin,
            "the candidate card and the admin row must show the same tally")

    # ------------------------------------------------------------------
    # Never a crash on a null or empty log
    # ------------------------------------------------------------------
    def test_a_null_log_serializes_to_an_empty_list_not_a_crash(self):
        """A legacy attempt written before `violation_log` existed carries null.
        The card must build and the key must be [], never raise into the
        candidate's own response."""
        self.assertFalse(self.evaluator.violation_log)
        proctoring = self._proctoring()
        self.assertEqual(
            proctoring["violations"], [],
            "a null violation_log must serialize to an empty tally")

    def test_an_empty_log_serializes_to_an_empty_list(self):
        self.evaluator.write({"violation_log": []})
        self.assertEqual(self._proctoring()["violations"], [])

    # ------------------------------------------------------------------
    # The addition is ADDITIVE: the old keys are untouched
    # ------------------------------------------------------------------
    def test_the_legacy_count_and_reason_keys_are_untouched(self):
        """`violation_count` and `violation_reason` must still be present and
        carry what they always did - the tally is added ALONGSIDE them, so a
        client reading either old key sees no change."""
        self._write_log(["Switched tab", "Exited fullscreen"])
        proctoring = self._proctoring()

        self.assertIn("violation_count", proctoring)
        self.assertIn("violation_reason", proctoring)
        self.assertEqual(
            proctoring["violation_count"], 2,
            "the count must be unchanged by the addition of the tally")
        self.assertEqual(
            proctoring["violation_reason"], "Exited fullscreen",
            "the latest-reason field must still be the LAST event, unchanged")

    def test_a_clean_attempt_reports_zero_count_and_an_empty_tally(self):
        """Guard the guard: an attempt with no breaches carries a zero count,
        an empty latest reason, and an empty tally - so the assertions above
        are pinning a real distribution, not a default that is always empty."""
        proctoring = self._proctoring()
        self.assertEqual(proctoring["violation_count"], 0)
        self.assertEqual(proctoring["violation_reason"], "")
        self.assertEqual(proctoring["violations"], [])
