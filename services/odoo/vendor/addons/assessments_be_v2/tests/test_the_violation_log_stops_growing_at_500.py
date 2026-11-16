# -*- coding: utf-8 -*-
"""The violation log keeps its first 500 entries; the count keeps counting.

SEB review #5: every report rewrote the whole jsonb log and the repeat check
scanned all of it, with no cap, so a client stuck in a reporting loop made
each report dearer than the last. The log now stops at 500 entries. The count
(what the limit and the label read) still goes up on every report.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestTheViolationLogStopsGrowingAt500(TransactionCase):

    def setUp(self):
        super().setUp()
        generator = self.env["assessments.be.prompt"].create({"name": "Gen"})
        paper = self.env["assessments.be"].create({
            "name": "Log cap %s" % uuid4().hex[:6],
            "generator_id": generator.id, "duration_minutes": 30,
            "violation_action": "log_only",
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Log Cap",
            "email_from": "logcap_%s@example.com" % uuid4().hex[:8]})
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id})

    def _seed(self, entries):
        self.evaluator.write({
            "violation_count": entries,
            "violation_log": [{"reason": "Old %d" % i,
                               "at": "2026-10-19 09:00:00"}
                              for i in range(entries)]})

    def test_a_full_log_is_left_alone_and_the_count_still_moves(self):
        self._seed(500)

        count = self.evaluator._record_violation("Tab switch")

        self.assertEqual(count, 501)
        self.assertEqual(self.evaluator.violation_count, 501)
        self.assertEqual(len(self.evaluator.violation_log), 500)
        self.assertEqual(self.evaluator.violation_log[-1]["reason"], "Old 499")
        self.assertEqual(self.evaluator.violation_reason, "Tab switch")

    def test_a_log_that_is_not_a_list_still_takes_the_violation(self):
        """A JSON null (an old row) has no array length; the cap check must
        not fail the report over it."""
        self.env.flush_all()
        self.env.cr.execute("UPDATE assessments_be_evaluator SET violation_log "
                            "= 'null'::jsonb WHERE id = %s",
                            (self.evaluator.id,))
        self.evaluator.invalidate_recordset()

        self.assertEqual(self.evaluator._record_violation("Tab switch"), 1)
        self.assertEqual(self.evaluator.violation_count, 1)

    def test_the_log_fills_up_to_500(self):
        self._seed(499)

        self.evaluator._record_violation("Tab switch")

        self.assertEqual(len(self.evaluator.violation_log), 500)
        self.assertEqual(self.evaluator.violation_log[-1]["reason"],
                         "Tab switch")
