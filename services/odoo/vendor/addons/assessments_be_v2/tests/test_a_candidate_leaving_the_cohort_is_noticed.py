# -*- coding: utf-8 -*-
"""A candidate LEAVING the outlier cohort makes the paper stale too.

Staleness was read off `llm_scored_at`, which only moves when a candidate
becomes fully scored. A forced re-grade sends a scored candidate back to
pending (then scored or error): it leaves the cohort, the mean and spread
move, and a flag it carried stayed up until something else was scored
(2026-09-22 review). Still derived from the data - no lane writes the paper.
"""
from datetime import timedelta

from odoo import fields
from odoo.tests.common import tagged

from .test_grading_never_writes_the_shared_paper_row import _Base


@tagged("-at_install", "post_install")
class TestACandidateLeavingTheCohortIsNoticed(_Base):

    def test_a_scored_candidate_sent_back_is_unflagged(self):
        now = fields.Datetime.now()
        Assessment = self.env["assessments.be"]
        # Every paper already in the database is checked "tomorrow", so only
        # this one can be stale.
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be SET score_outlier_stale = false, "
            "score_outlier_checked_at = %s", [now + timedelta(days=1)])
        self.env.invalidate_all()
        paper, cohort = self._paper([50, 52, 48, 51, 49, 99])
        cohort._recompute_cohort_outliers()
        outlier = cohort[-1]
        self.assertTrue(outlier.score_outlier, "fixture guard")
        # Everything scored an hour ago and checked since.
        cohort.llm_scored_at = now - timedelta(hours=1)
        paper.score_outlier_checked_at = now - timedelta(minutes=30)
        self.assertNotIn(paper, Assessment._outlier_stale_papers(limit=1000),
                         "fixture guard: nothing changed since the check")

        outlier.action_reset_failed_scoring(states=("scored",))

        self.assertIn(paper, Assessment._outlier_stale_papers(limit=1000))
        Assessment._cron_recompute_subjective_results(commit=False)
        self.assertFalse(outlier.score_outlier,
                         "it is no longer in the cohort it stood out from")
