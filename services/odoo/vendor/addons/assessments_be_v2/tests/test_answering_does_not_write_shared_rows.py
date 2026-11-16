# -*- coding: utf-8 -*-
"""Saving an answer must not UPDATE a row the rest of the cohort shares.

THE INVARIANT: no field on the hot answer path may be a stored compute that
writes a shared row. Two stored computes broke it -
`assessments_be.response_count` (depended on `response_ids`, so every answer
wrote the one paper row) and `assessments_be_evaluator.score_outlier` (depended
on the SIBLING evaluators, so N candidates answering issued N**2 updates). The
measured cost and the failure counts per column are recorded once, at
`models/assessment.py` on `response_count`; see there.

WHY FIELD METADATA RATHER THAN A CONCURRENCY SIMULATION. Two transactions
genuinely racing cannot be produced inside a `TransactionCase` - it is one
transaction by construction, and threads against a test cursor would be testing
the harness. The invariant is statically true or false, so restoring
`store=True` on either field fails this file immediately and names the cost.
"""
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAnsweringDoesNotWriteSharedRows(TransactionCase):

    # ------------------------------------------------------------------
    # response_count: the shared paper row
    # ------------------------------------------------------------------
    def test_response_count_is_not_stored(self):
        """THE HEADLINE, and 922 of the failures.

        Stored + `depends("response_ids")` means one UPDATE on the shared
        `assessments_be` row per answer saved, by every candidate, for a counter
        that only an admin list renders.
        """
        field = self.env["assessments.be"]._fields["response_count"]
        self.assertTrue(field.compute, "it is still a computed field")
        self.assertFalse(
            field.store,
            "storing this writes assessments_be on every candidate's every "
            "answer - 922 serialization failures at 100 concurrent candidates. "
            "Nothing searches, sorts or groups on it, so it does not need to be "
            "stored.")

    def test_response_count_still_counts_correctly(self):
        """Unstoring must not break the number. A counter that reads 0 everywhere
        would be a worse bug than the contention."""
        generator = self.env["assessments.be.prompt"].create({"name": "Gen"})
        assessment = self.env["assessments.be"].create({
            "name": "Contention probe",
            "generator_id": generator.id,
        })
        self.assertEqual(assessment.response_count, 0)

        applicant = self.env["hr.applicant"].create(
            {"partner_name": "Probe Candidate"})
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        for i in range(3):
            question = self.env["assessments.be.question"].create({
                "name": "Q%d" % i,
                "question_type": "subjective_rubric",
                "prompt": "Describe hazard %d" % i,
                "generator_id": generator.id,
                "assessment_ids": [(4, assessment.id)],
            })
            self.env["assessments.be.response"].create({
                "question_id": question.id,
                "assessment_id": assessment.id,
                "evaluator_id": applicant.id,
                "assessment_evaluator_id": evaluator.id,
                "justification": "An answer.",
            })
        assessment.invalidate_recordset()
        self.assertEqual(
            assessment.response_count, 3,
            "the grouped COUNT must agree with the rows that exist")

    def test_response_count_is_zero_for_a_paper_with_no_answers(self):
        """The `_read_group` returns no row at all for an empty assessment, so
        the default has to come from the `.get(rec, 0)` and not from a KeyError."""
        generator = self.env["assessments.be.prompt"].create({"name": "Gen2"})
        assessment = self.env["assessments.be"].create({
            "name": "Empty paper", "generator_id": generator.id})
        self.assertEqual(assessment.response_count, 0)

    def test_response_count_is_right_for_SEVERAL_papers_at_once(self):
        """The compute runs over a recordset and reads one grouped query for all
        of it. A mistake in the grouping shows up only with more than one row -
        every assessment getting the FIRST one's count, or all of them getting 0.
        """
        generator = self.env["assessments.be.prompt"].create({"name": "Gen3"})
        applicant = self.env["hr.applicant"].create(
            {"partner_name": "Multi Probe"})
        expected = {}
        for n in (1, 2, 4):
            assessment = self.env["assessments.be"].create({
                "name": "Paper of %d" % n, "generator_id": generator.id})
            evaluator = self.env["assessments.be.evaluator"].create({
                "assessment_id": assessment.id, "applicant_id": applicant.id})
            for i in range(n):
                question = self.env["assessments.be.question"].create({
                    "name": "Q%d-%d" % (n, i),
                    "question_type": "subjective_rubric",
                    "prompt": "Prompt",
                    "generator_id": generator.id,
                    "assessment_ids": [(4, assessment.id)],
                })
                self.env["assessments.be.response"].create({
                    "question_id": question.id,
                    "assessment_id": assessment.id,
                    "evaluator_id": applicant.id,
                    "assessment_evaluator_id": evaluator.id,
                    "justification": "x",
                })
            expected[assessment.id] = n

        papers = self.env["assessments.be"].browse(list(expected))
        papers.invalidate_recordset()
        self.assertEqual(
            {p.id: p.response_count for p in papers}, expected,
            "each paper must get ITS OWN count from the grouped read")

    # ------------------------------------------------------------------
    # score_outlier: the sibling-candidate dependency
    # ------------------------------------------------------------------
    def test_score_outlier_does_not_depend_on_sibling_candidates(self):
        """355 of the failures, and the O(N**2) one.

        The flag is cohort-relative, so watching every peer is honest about the
        maths - and as an INVALIDATION rule it means one candidate's write
        dirties every candidate's row. It stays stored (it is searched by the
        flagged-review queue) and is recomputed explicitly when scoring finishes.
        """
        field = self.env["assessments.be.evaluator"]._fields["score_outlier"]
        # `_depends`, not `depends`: the public-looking name does not exist on a
        # Field in Odoo 19 and raises AttributeError, which would have made this
        # test an error rather than a pass or a failure.
        depends = " ".join(getattr(field, "_depends", None) or ())
        self.assertNotIn(
            "assessment_evaluator_ids", depends,
            "a depends reaching the sibling candidates makes one answer write N "
            "evaluator rows, and N concurrent candidates write N**2 - see "
            "_recompute_cohort_outliers, which is where the cohort maths is "
            "re-run instead")

    def test_score_outlier_is_still_STORED_because_it_is_searched(self):
        """The other half of the same decision. `admin._attempt_domain` puts this
        field in a search domain for the flagged-review queue and
        `assessment_views.xml` offers it as a filter - a non-stored boolean cannot
        be searched without a hand-written `search=`, and writing one for a
        cohort-relative z-score means reimplementing the statistics in SQL."""
        field = self.env["assessments.be.evaluator"]._fields["score_outlier"]
        self.assertTrue(field.store)
        self.assertTrue(
            self.env["assessments.be.evaluator"].search_count(
                [("score_outlier", "=", False)]) >= 0,
            "the field must remain searchable")

    def test_the_cohort_recompute_exists_and_is_safe_to_call(self):
        """The replacement for the peer-depends. It must exist, must tolerate an
        empty recordset, and must not raise on a cohort too small to flag
        anybody - it runs inside the scoring cron, where an exception would be
        logged against work that has already succeeded."""
        Evaluator = self.env["assessments.be.evaluator"]
        self.assertTrue(hasattr(Evaluator, "_recompute_cohort_outliers"))
        Evaluator.browse()._recompute_cohort_outliers()      # empty: no-op

        generator = self.env["assessments.be.prompt"].create({"name": "Gen4"})
        assessment = self.env["assessments.be"].create({
            "name": "Tiny cohort", "generator_id": generator.id})
        applicant = self.env["hr.applicant"].create(
            {"partner_name": "Lonely Candidate"})
        evaluator = Evaluator.create({
            "assessment_id": assessment.id, "applicant_id": applicant.id})
        evaluator._recompute_cohort_outliers()
        self.assertFalse(
            evaluator.score_outlier,
            "a cohort of one cannot have an outlier, and asking must not raise")

    # ------------------------------------------------------------------
    # The class guard: nothing else on the hot path may do this
    # ------------------------------------------------------------------
    def test_NO_stored_compute_on_the_shared_row_watches_candidate_writes(self):
        """The sweep, so the next field of this shape is caught by a test rather
        than by a cohort losing their answers.

        `assessments.be` is ONE row per paper. Any stored computed field on it
        that depends on a candidate-written collection is the defect this file
        exists for, whatever it is called.
        """
        CANDIDATE_WRITTEN = ("response_ids", "line_ids")
        offenders = []
        for name, field in self.env["assessments.be"]._fields.items():
            if not (field.compute and field.store):
                continue
            depends = " ".join(getattr(field, "_depends", None) or ())
            if any(d in depends for d in CANDIDATE_WRITTEN):
                offenders.append("%s (depends: %s)" % (name, depends))
        self.assertFalse(
            offenders,
            "these stored computes on the SHARED assessment row are recomputed "
            "by a candidate's answer, so every candidate's every answer UPDATEs "
            "one row and they serialise against each other: %s" % offenders)
