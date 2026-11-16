# -*- coding: utf-8 -*-
"""Every violation is recorded with its timestamp, atomically, once per action.

WHY THIS FILE EXISTS. `violation_reason` / `violation_datetime` only ever held
the LATEST breach, so a reviewer answering an appeal saw one event over a
sitting that may have had a dozen. `violation_log` is the full history, and it
is appended INSIDE the same atomic SQL that bumps the counter - two beacons
microseconds apart must not lose an entry, the same reason the counter was
already raw SQL rather than a read-modify-write.

The recording rule now lives once, on the evaluator, and both the JSON API and
the portal delegate to it. These tests drive the model method directly (it
reads `self.env.cr` for its atomic write, which the test cursor provides) and
assert on the four properties that make the feature: the tally aggregates and
orders by count, a deduped burst counts AND logs exactly once, PII erase empties
the log, and a legacy attempt with a null log serializes to [] rather than
crashing.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import serializers as S
from odoo.addons.assessments_be_v2.services import evidence


@tagged("-at_install", "post_install")
class TestViolationLog(TransactionCase):

    def setUp(self):
        super().setUp()
        # erase purges snapshots; keep tests off the bucket
        purge = patch.object(evidence, "purge_evidence")
        purge.start()
        self.addCleanup(purge.stop)
        generator = self.env["assessments.be.prompt"].create({"name": "Gen"})
        self.assessment = self.env["assessments.be"].create({
            "name": "Violation log probe",
            "generator_id": generator.id,
            "duration_minutes": 30,
            # Log only, so recording a violation never ends the sitting - these
            # tests are about the LOG, not the auto-submit decision.
            "violation_action": "log_only",
        })
        self.applicant = self.env["hr.applicant"].create({
            "partner_name": "Log Probe",
            "email_from": "logprobe_%s@example.com" % uuid4().hex[:8],
        })
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": self.applicant.id,
        })

    def _log(self):
        return self.evaluator.violation_log or []

    # ------------------------------------------------------------------
    # The tally
    # ------------------------------------------------------------------
    def test_three_violations_of_two_kinds_tally_two_one_in_order(self):
        """Two 'tab-switch' and one 'copy-paste' -> [{tab-switch:2},{copy:1}],
        ordered by count DESCENDING."""
        self.evaluator._record_violation("tab-switch")
        self.evaluator._record_violation("copy-paste")
        self.evaluator._record_violation("tab-switch")

        self.assertEqual(self.evaluator.violation_count, 3)
        self.assertEqual(len(self._log()), 3, "every event must be logged")

        tally = S.violation_tally(self.evaluator)
        self.assertEqual(
            tally,
            [{"reason": "tab-switch", "count": 2},
             {"reason": "copy-paste", "count": 1}],
            "the tally must aggregate per reason and order by count descending")

    def test_each_log_entry_carries_a_reason_and_a_timestamp(self):
        self.evaluator._record_violation("devtools")
        entry = self._log()[0]
        self.assertEqual(entry.get("reason"), "devtools")
        self.assertTrue(entry.get("at"), "each entry must carry its timestamp")

    # ------------------------------------------------------------------
    # The dedupe counts AND logs once
    # ------------------------------------------------------------------
    def test_a_same_reason_burst_counts_once_and_logs_once(self):
        """A single physical action fires several beacons; a repeat of the
        SAME reason within 1.2s must fold into one count AND one log entry."""
        self.evaluator._record_violation("tab-switch")
        # Immediately again, same reason: the burst dedupe folds it.
        self.evaluator._record_violation("tab-switch")

        self.assertEqual(
            self.evaluator.violation_count, 1,
            "a same-reason burst inside 1.2s must count once")
        self.assertEqual(
            len(self._log()), 1,
            "a deduped burst must not leave a second log entry either")

    def test_two_different_reasons_back_to_back_both_count_and_log(self):
        """The other half of the dedupe: genuinely different reasons are not
        folded, so both are recorded."""
        self.evaluator._record_violation("tab-switch")
        self.evaluator._record_violation("copy-paste")

        self.assertEqual(self.evaluator.violation_count, 2)
        self.assertEqual(len(self._log()), 2)

    # ------------------------------------------------------------------
    # PII erase empties the log
    # ------------------------------------------------------------------
    def test_pii_erase_empties_the_log(self):
        """Erasure must scrub the history, not just the latest reason - the log
        quotes what the person did on every prior event too."""
        self.evaluator._record_violation("tab-switch")
        self.evaluator._record_violation("copy-paste")
        self.assertTrue(self._log())

        self.evaluator._anonymize_pii()

        self.assertEqual(
            self._log(), [],
            "PII erase must empty violation_log or the history leaks")
        self.assertEqual(
            S.violation_tally(self.evaluator), [],
            "an erased log serializes to an empty tally")
        # The non-PII integrity fact - that violations happened - is kept.
        self.assertEqual(self.evaluator.violation_count, 2)

    # ------------------------------------------------------------------
    # A legacy attempt with a null log
    # ------------------------------------------------------------------
    def test_a_legacy_null_log_serializes_to_an_empty_list(self):
        """A row written before `violation_log` existed carries null. The
        serializer must return [] and never crash."""
        self.assertFalse(self.evaluator.violation_log)
        self.assertEqual(S.violation_tally(self.evaluator), [])
        # And the admin row that embeds it must build without raising.
        row = S.evaluator_admin_row(self.evaluator)
        self.assertEqual(row["flags"]["violations"], [])

    def test_the_latest_fields_still_reflect_the_last_event(self):
        """`violation_reason` / `violation_datetime` are unchanged: nothing that
        reads the 'latest' fields moves."""
        self.evaluator._record_violation("tab-switch")
        self.evaluator._record_violation("copy-paste")
        self.assertEqual(self.evaluator.violation_reason, "copy-paste")
        self.assertTrue(self.evaluator.violation_datetime)
