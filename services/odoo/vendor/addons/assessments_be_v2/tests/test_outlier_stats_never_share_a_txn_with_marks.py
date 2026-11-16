# -*- coding: utf-8 -*-
"""A cohort STATISTIC must never share a transaction with the MARKS.

THE DEFECT, measured over the completed scoring drain of 2026-09-03/04:

    scoring runs            1,669
    distinct evaluators     1,210
    runs that were re-work    459  (27.5%)
    outlier recompute fails   451  (27.0%)
    InFailedSqlTransaction  1,571
    wasted spend            $43.70 of $164.24

`services.scoring.score_evaluator` finished by calling
`evaluator._recompute_cohort_outliers()` inline. That writes EVERY peer row of the
cohort, so two shards scoring two candidates of the same paper collided in
Postgres.

WHY THE `try/except` AROUND IT DID NOT CONTAIN THE DAMAGE, which is the whole
lesson: `_cron_llm_auto_score` wraps the run in `with self.env.cr.savepoint()`.
A serialization failure aborts the WHOLE Postgres transaction - every later
statement raises `InFailedSqlTransaction` - so catching the exception in Python
rescues nothing. The savepoint unwound and took the marks that had just been
written with it. The old log line claimed "scores are stored and unaffected"; it
was false.

Proof it was false, from evaluator 1384's own log:

    17:23:02  scoring evaluator id=1384 todo=3 batch=8      <- 3 to grade
    17:24:00  scoring evaluator id=1384 done: scored=3/3    <- claims 3 stored
    17:39:15  scoring evaluator id=1384 todo=3 batch=20     <- 3 STILL to grade
    17:40:10  scoring evaluator id=1384 done: scored=3/3

`score_evaluator`'s `todo` filter excludes `scored`. Had anything persisted, the
second run would have found `todo=0`.

THE FIX: scoring now only sets `assessment.score_outlier_stale` - one boolean on a
row the cron already owns - and `_cron_recompute_subjective_results` does the
cohort pass ONCE PER ASSESSMENT, in its own savepoint, where a collision costs a
retried statistic and never a mark. (Since 2026-09-22 scoring does not even set
the flag - see test_grading_never_writes_the_shared_paper_row.py - but the cron
still drains one left up, which is what the tests below exercise.)

WHAT THESE TESTS PIN. A true concurrency test cannot run in a `TransactionCase` -
it is one transaction by construction. But every property that made the outage is
observable in one: that scoring no longer touches the cohort, that it raises the
flag instead, that the cron drains and clears it, and that a failing recompute
leaves the flag set rather than swallowing the request.

Sibling of test_answering_does_not_write_shared_rows.py, which covers the FIRST
contention class (stored computes on the shared paper row). This covers the
regression introduced by that fix.
"""
import inspect

from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger


@tagged("-at_install", "post_install")
class TestOutlierStatsNeverShareATxnWithMarks(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Outlier-txn generator"})
        self.assessment = self.env["assessments.be"].create({
            "name": "Outlier txn isolation",
            "generator_id": self.generator.id,
        })
        self.applicant = self.env["hr.applicant"].create(
            {"partner_name": "Outlier Candidate"})
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": self.applicant.id,
        })

    # ------------------------------------------------------------------
    # The static invariant: the hot path must not touch the cohort
    # ------------------------------------------------------------------
    def test_scoring_does_not_recompute_the_cohort_inline(self):
        """THE HEADLINE. This one line cost 451 failed runs and $43.70.

        Comment-stripped, because the fix's own account of the bug names the
        method it removed.
        """
        from odoo.addons.assessments_be_v2.services import scoring

        code = "\n".join(
            line for line in inspect.getsource(scoring).splitlines()
            if not line.lstrip().startswith("#")
        )
        self.assertNotIn(
            "_recompute_cohort_outliers", code,
            "services.scoring recomputes the cohort inline again. That writes "
            "every peer row inside the savepoint holding the marks, so a "
            "collision between two shards DISCARDS the scores just written - "
            "451 of 1,669 runs on 2026-09-03. Set score_outlier_stale and let "
            "_cron_recompute_subjective_results do it once per cohort.")

    def test_the_flag_exists_and_is_not_copied(self):
        """`copy=False`: duplicating a paper must not inherit a stale request."""
        field = self.env["assessments.be"]._fields.get("score_outlier_stale")
        self.assertIsNotNone(
            field, "score_outlier_stale is how scoring hands the cohort pass "
                   "to the cron; without it the recompute never happens")
        self.assertFalse(field.copy, "a copied paper starts with no stale flag")
        self.assertFalse(
            self.assessment.score_outlier_stale,
            "a fresh assessment has nothing to recompute")

    # ------------------------------------------------------------------
    # The handover: scoring raises the flag, the cron drains it
    # ------------------------------------------------------------------
    def test_the_cron_clears_the_flag_it_acted_on(self):
        """A drained request must not be re-queued forever."""
        self.assessment.score_outlier_stale = True

        self.env["assessments.be"]._cron_recompute_subjective_results(commit=False)

        self.assertFalse(
            self.assessment.score_outlier_stale,
            "the cron ran the cohort pass but left the flag set, so this paper "
            "is recomputed on every tick for ever")

    @mute_logger("odoo.addons.assessments_be_v2.models.assessment")
    def test_a_failing_recompute_keeps_the_flag_for_the_next_tick(self):
        """A statistic is allowed to be LATE. It is not allowed to be LOST.

        Clearing the flag before the recompute succeeds drops the request
        silently - which is the same class of defect as the scoring crons
        sitting `active=False` for six hours while both buttons reported
        success.
        """
        self.assessment.score_outlier_stale = True
        Evaluator = type(self.env["assessments.be.evaluator"])
        original = Evaluator._recompute_cohort_outliers

        def boom(recordset):
            raise ValueError("simulated cohort write collision")

        Evaluator._recompute_cohort_outliers = boom
        try:
            self.env["assessments.be"]._cron_recompute_subjective_results(commit=False)
        finally:
            Evaluator._recompute_cohort_outliers = original

        self.assertTrue(
            self.assessment.score_outlier_stale,
            "the recompute failed and the flag was cleared anyway, so this "
            "cohort's outlier column stays wrong with nothing to retry it")

    def test_the_cohort_pass_is_still_correct_when_it_runs(self):
        """Moving it must not break it: a cohort of one has no outlier, and
        asking must not raise."""
        self.assessment.score_outlier_stale = True

        self.env["assessments.be"]._cron_recompute_subjective_results(commit=False)

        self.assertFalse(
            self.evaluator.score_outlier,
            "a cohort of one cannot contain an outlier")

    @mute_logger("odoo.addons.assessments_be_v2.models.assessment")
    def test_marks_survive_a_cohort_write_failure(self):
        """The property the outage violated, stated directly.

        Whatever the statistic does, an answer's llm_state must not be rolled
        back with it. Here the recompute raises during the cron; the response
        written beforehand must still be there afterwards.
        """
        question = self.env["assessments.be.question"].create({
            "name": "Explain the check you applied",
            "prompt": "Explain the check you applied.",
            "question_type": "subjective_rubric",
            "assessment_ids": [(4, self.assessment.id)],
        })
        response = self.env["assessments.be.response"].create({
            "assessment_id": self.assessment.id,
            "assessment_evaluator_id": self.evaluator.id,
            "evaluator_id": self.applicant.id,
            "question_id": question.id,
            "justification": "I checked the label against the reference.",
            "state": "submitted",
            "llm_state": "scored",
        })
        self.assessment.score_outlier_stale = True
        Evaluator = type(self.env["assessments.be.evaluator"])
        original = Evaluator._recompute_cohort_outliers
        Evaluator._recompute_cohort_outliers = lambda rs: (_ for _ in ()).throw(
            ValueError("simulated cohort write collision"))
        try:
            self.env["assessments.be"]._cron_recompute_subjective_results(commit=False)
        finally:
            Evaluator._recompute_cohort_outliers = original

        self.assertEqual(
            response.llm_state, "scored",
            "a failed cohort statistic rolled back a stored mark - this is "
            "exactly the 2026-09-03 defect, where 459 runs re-graded answers "
            "whose scores had been discarded by the savepoint unwinding")
