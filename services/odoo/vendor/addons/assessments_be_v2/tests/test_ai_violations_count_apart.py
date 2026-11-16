# -*- coding: utf-8 -*-
"""R5: AI proctoring violations are counted apart from the regular ones.

A reason starting "AI: " (the browser's camera rules) moves only
`ai_violation_count` / `ai_violation_log` - on a paper with AI proctoring on;
with it off no AI rule is watching, and the reason counts as regular. Any
other reason moves only
`violation_count` / `violation_log`. The latest-violation fields
(`is_violated`, `violation_reason`, `violation_datetime`) stay shared, and each
kind is held to its own limit on the paper.

MODEL LEVEL ONLY. The /violation route, each kind's cap and mode, and the
auto-submit stamped `ai_violation` live in controllers/api/candidate.py and are
tested beside it (BE-2).
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import ValidationError
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.services import evidence

AI = "AI: No face in view"
AI_PHONE = "AI: Phone in view"
REGULAR = "tab-switch"


@tagged("-at_install", "post_install")
class TestAiViolationsCountApart(TransactionCase):

    def setUp(self):
        super().setUp()
        # erase purges snapshots; keep tests off the bucket
        purge = patch.object(evidence, "purge_evidence")
        purge.start()
        self.addCleanup(purge.stop)
        generator = self.env["assessments.be.prompt"].create(
            {"name": "AI apart %s" % uuid4().hex[:6]})
        self.paper = self.env["assessments.be"].create({
            "name": "AI apart %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "duration_minutes": 30,
            "rule_webcam": True, "rule_ai_proctor": True,
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Apart Probe",
            "email_from": "apart_%s@example.com" % uuid4().hex[:8],
        })
        self.ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id})

    @staticmethod
    def _reasons(log):
        return [entry["reason"] for entry in log or []]

    def test_a_new_paper_starts_at_five_and_log_only(self):
        self.assertEqual(self.paper.ai_max_violations, 5)
        self.assertEqual(self.paper.ai_violation_action, "log_only")

    def test_an_ai_reason_moves_only_the_ai_columns(self):
        self.assertEqual(self.ev._record_violation(AI), 1)
        self.assertEqual(self.ev.ai_violation_count, 1)
        self.assertEqual(self._reasons(self.ev.ai_violation_log), [AI])
        self.assertEqual(self.ev.violation_count, 0)
        self.assertFalse(self.ev.violation_log)
        # The latest violation stays one shared fact.
        self.assertTrue(self.ev.is_violated)
        self.assertEqual(self.ev.violation_reason, AI)

    def test_a_regular_reason_moves_only_the_regular_columns(self):
        self.ev._record_violation(AI)
        self.assertEqual(self.ev._record_violation(REGULAR), 1,
                         "the regular count does not include the AI one")
        self.assertEqual(self.ev.violation_count, 1)
        self.assertEqual(self._reasons(self.ev.violation_log), [REGULAR])
        self.assertEqual(self.ev.ai_violation_count, 1)
        self.assertEqual(self._reasons(self.ev.ai_violation_log), [AI])
        self.assertEqual(self.ev.violation_reason, REGULAR)

    def test_with_ai_proctoring_off_an_ai_reason_counts_as_regular(self):
        self.paper.rule_ai_proctor = False
        self.assertEqual(self.ev._record_violation(AI), 1)
        self.assertEqual(self.ev.violation_count, 1)
        self.assertEqual(self._reasons(self.ev.violation_log), [AI])
        self.assertEqual(self.ev.ai_violation_count, 0)
        self.assertFalse(self.ev.ai_violation_log)

    def test_ai_turned_off_mid_sitting_keeps_a_running_pages_flags_apart(self):
        """The page started its AI under the rule (`ai_status` is only taken
        while it is on); an admin turning a misfiring AI off must not move its
        flags onto the regular cap."""
        self.ev.sudo().ai_status = "running"
        self.paper.rule_ai_proctor = False
        self.assertEqual(self.ev._record_violation(AI), 1)
        self.assertEqual((self.ev.violation_count, self.ev.ai_violation_count),
                         (0, 1))
        self.ev.sudo().ai_status = "failed"     # its AI never ran
        self.ev._record_violation(AI_PHONE)
        self.assertEqual((self.ev.violation_count, self.ev.ai_violation_count),
                         (1, 1))

    def test_a_report_sent_again_counts_once_on_its_own_kind(self):
        stamp = 1760500000000
        self.assertEqual(self.ev._record_violation(AI, client_at=stamp), 1)
        # A different reason dodges the 1.2 s fold, so only the stamp can stop it.
        self.assertIsNone(self.ev._record_violation(AI_PHONE, client_at=stamp))
        self.assertEqual(self.ev.ai_violation_count, 1)
        self.assertEqual(len(self.ev.ai_violation_log), 1)
        # The stamp is looked up in that kind's log only.
        self.assertEqual(self.ev._record_violation(REGULAR, client_at=stamp), 1)
        self.assertIsNone(self.ev._record_violation("copy-paste", client_at=stamp))
        self.assertEqual((self.ev.violation_count, self.ev.ai_violation_count),
                         (1, 1))

    def test_each_kind_breaches_its_own_limit(self):
        self.paper.write({"max_violations": 2, "violation_action": "log_only",
                          "ai_max_violations": 1,
                          "ai_violation_action": "auto_submit"})
        self.ev._record_violation(REGULAR)
        self.assertFalse(self.ev.violation_limit_breached)
        self.assertFalse(self.ev.ai_violation_limit_breached)
        self.ev._record_violation(AI)
        self.assertTrue(self.ev.ai_violation_limit_breached)
        self.assertFalse(self.ev.violation_limit_breached,
                         "an AI violation is not a second regular one")
        self.ev._record_violation("copy-paste")
        self.assertTrue(self.ev.violation_limit_breached)

    def test_an_ai_limit_of_zero_follows_the_regular_rule(self):
        self.paper.write({"ai_max_violations": 0,
                          "ai_violation_action": "log_only"})
        self.ev._record_violation(AI)
        self.assertFalse(self.ev.ai_violation_limit_breached,
                         "0 under Log only means no limit")
        self.paper.ai_violation_action = "auto_submit"
        self.assertTrue(self.ev.ai_violation_limit_breached,
                        "0 under Auto-submit is the first violation")

    def test_a_negative_ai_limit_is_refused(self):
        with self.assertRaises(ValidationError) as refused:
            self.paper.ai_max_violations = -1
            self.env.flush_all()
        self.assertIn("AI violation limit", str(refused.exception))
        self.assertEqual(self.paper.ai_max_violations, 5)

    def test_erasure_empties_both_logs_and_keeps_both_counts(self):
        self.ev._record_violation(AI)
        self.ev._record_violation(REGULAR)
        self.ev._anonymize_pii()
        # Written [] and read back falsy, as `violation_log` always was.
        self.assertFalse(self.ev.ai_violation_log)
        self.assertFalse(self.ev.violation_log)
        self.assertEqual((self.ev.violation_count, self.ev.ai_violation_count),
                         (1, 1))

    def test_the_wire_values_exist(self):
        Evaluator = self.env["assessments.be.evaluator"]
        self.assertIn("ai_violation", dict(
            Evaluator._fields["auto_submit_reason"].selection))
        self.assertEqual(
            [key for key, _label in Evaluator._fields["ai_status"].selection],
            ["running", "running_gaze", "gaze_failed", "failed"])
        self.assertEqual(Evaluator.AI_REASON_PREFIX, "AI: ")
