# -*- coding: utf-8 -*-
"""The SCORE header orders the roster by the number printed in the SCORE cell.

WHY THIS FILE EXISTS. `_SORTABLE["score"]` pointed at `total_score`, which is
the OBJECTIVE sub-total and nothing else - `objective_total` is a stored alias
of the very same field, and `_compute_progress` builds it by summing
`assessments.be.response.score`, which is 0 for every question type that is not
`mcq`/`msq`. The cell beside that header renders `score_marks`
(`score_marks_display` = earned `final_mark` over the paper's component count,
objective AND graded subjective), and the RESULT pill beside THAT is decided by
`score_percent` over the same fraction.

So on any paper with rubric-graded components - the module's main use - the
column sorted by a number that was neither displayed in it nor the basis of the
verdict next to it. A candidate showing "16 / 20 Pass" sat below one showing
"5 / 20 Fail" under a descending caret, with nothing on screen to say why. A
sort is a confident answer to "who did best"; answering it with a different
quantity than the one on display is worse than not offering the sort.

`score_percent` is also the only key that is NORMALISED, which matters for a
second reason: the denominator is per candidate (papers are drawn per person,
so component counts differ), and a bare numerator cannot rank two candidates
who sat different-sized papers at all.

THE FIXTURE IS BUILT SO THE TWO ORDERS DISAGREE. A cohort where objective and
combined happen to agree would pass this file on the unfixed code - the first
test asserts the disagreement before anything else is asserted about it. The
stored computed columns are stamped in SQL, the same way
`test_a_sorted_walk_returns_every_row_once` stamps `total_score`: what is under
test is the route's ORDER BY, not the scoring pipeline that fills the columns.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ._paging_harness import call_route

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"

#: (objective sub-total, rendered marks, percent). Candidate A is the MCQ
#: specialist who failed the written half; B is the reverse. Sorting by
#: `total_score` puts A on top, sorting by what the cell shows puts B there.
OBJECTIVE_ONLY = (5, "5 / 20", 25.0)
SUBJECTIVE_HEAVY = (1, "16 / 20", 80.0)


@tagged("-at_install", "post_install")
class TestTheRosterSortsByTheScoreItShows(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.controller = api_admin.EtpAssessmentApiAdmin()
        self.Evaluator = self.env["assessments.be.evaluator"]
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        self.assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
        })
        self.objective = self._candidate("Objective", OBJECTIVE_ONLY)
        self.subjective = self._candidate("Subjective", SUBJECTIVE_HEAVY)

    def _candidate(self, label, marks):
        applicant = self.env["hr.applicant"].with_context(
            tracking_disable=True, mail_create_nolog=True,
            mail_notrack=True).create({
                "partner_name": "%s %s" % (label, uuid4().hex[:6]),
                "email_from": "%s.%s@example.com" % (label, uuid4().hex[:8]),
            })
        evaluator = self.Evaluator.create({
            "assessment_id": self.assessment.id,
            "applicant_id": applicant.id,
        })
        evaluator.write({"state": "submitted"})
        # Stored COMPUTED columns, stamped in SQL. Flush first so the ORM's own
        # recompute lands before these values and cannot overwrite them;
        # invalidate after so the next read comes from the column.
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be_evaluator SET total_score = %s, "
            "score_marks_display = %s, score_percent = %s WHERE id = %s",
            (marks[0], marks[1], marks[2], evaluator.id))
        self.env.invalidate_all()
        return evaluator

    def _roster(self, **params):
        response = call_route(
            api_admin, self.controller, "assessment_candidates", self.env,
            path={"assessment_id": self.assessment.id}, limit=50, **params)
        self.assertTrue(response.get("ok"), response)
        return response["data"]

    def test_the_fixture_really_makes_the_two_orders_disagree(self):
        """GUARD THE GUARD. Without this the assertions below could pass on a
        cohort where the objective sub-total happens to rank correctly."""
        self.assertGreater(
            self.objective.total_score, self.subjective.total_score,
            "the objective-only specialist must lead on total_score")
        self.assertLess(
            self.objective.score_percent, self.subjective.score_percent,
            "and trail on the score the cell actually renders")

    def test_descending_puts_the_higher_printed_score_first(self):
        """The operator clicking SCORE twice to shortlist the top of a
        cohort. Before the fix this returned "5 / 20" above "16 / 20"."""
        rows = self._roster(sort="score", sort_desc=True)

        self.assertEqual(
            [row["score_marks"] for row in rows],
            [SUBJECTIVE_HEAVY[1], OBJECTIVE_ONLY[1]],
            "the SCORE column sorted by a number it does not display")
        self.assertEqual(rows[0]["id"], self.subjective.id)

    def test_ascending_is_the_exact_inverse(self):
        rows = self._roster(sort="score")

        self.assertEqual(
            [row["id"] for row in rows],
            [self.objective.id, self.subjective.id])

    def test_the_order_matches_the_percent_on_the_same_row(self):
        """Stated as the property rather than as two ids, so it still holds
        for any cohort: the sequence is monotonic in the number sent."""
        percents = [row["score_percent"]
                    for row in self._roster(sort="score", sort_desc=True)]

        self.assertEqual(percents, sorted(percents, reverse=True))

    def test_the_verdict_column_agrees_with_the_order(self):
        """`result` is decided by `score_percent`, so a sort on a different
        quantity puts a Pass below a Fail - which is what an operator sees."""
        rows = self._roster(sort="score", sort_desc=True)

        self.assertGreaterEqual(
            rows[0]["score_percent"], rows[-1]["score_percent"])
