# -*- coding: utf-8 -*-
"""Settling a candidate's attempt writes nothing on the paper row the whole
cohort shares.

SEB review #4: every settlement still raised `cohort_close_stale` on the
paper, in the transaction holding the settlement. At a deadline that is one
row written by every candidate at once: lock waits and serialization retries
on the sharpest minute of the exam. The flag added nothing - the close pass
(`_cron_recompute_subjective_results`) sweeps `in_progress` papers whether
flagged or not, so the cohort still closes, from the cron alone.

"Written" is measured by `ctid`, which moves on every UPDATE, as in
`test_grading_never_writes_the_shared_paper_row`.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestSettlingNeverWritesTheSharedPaperRow(TransactionCase):

    def setUp(self):
        super().setUp()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Settle %s" % uuid4().hex[:6]})
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Explain your reasoning.",
            "generator_id": generator.id,
        })
        self.paper = self.env["assessments.be"].create({
            "name": "Settle paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, question.ids)],
            "state": "in_progress",
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "c_%s@example.com" % uuid4().hex[:8]})
        self.attempt = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id,
            "applicant_id": applicant.id,
            "question_order": "[%d]" % question.id,
        })

    def _ctid(self):
        self.env.flush_all()
        self.env.cr.execute("SELECT ctid FROM assessments_be WHERE id = %s",
                            [self.paper.id])
        return self.env.cr.fetchone()[0]

    def test_settling_leaves_the_paper_row_unwritten(self):
        before = self._ctid()

        self.assertTrue(self.attempt._auto_submit_expired(reason_code="expired"))

        self.assertEqual(self.attempt.state, "submitted")
        self.assertEqual(self._ctid(), before,
                         "settling wrote the paper row every candidate shares")

    def test_the_cron_still_closes_the_cohort(self):
        self.attempt._auto_submit_expired(reason_code="expired")

        self.env["assessments.be"]._cron_recompute_subjective_results(
            commit=False)

        self.assertEqual(self.paper.state, "done")
