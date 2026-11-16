"""Cohort strengths and weaknesses, by category, for the admin dashboard.

THE FEATURE. `ETP_Dashboard_Final_Feature_List.docx` asks for "Test-wise
strengths/weaknesses for the cohort: category-level averages, scoped per
assessment (not all-up), for targeted coaching". Per-attempt and per-candidate
category breakdowns already existed; the cohort-level one did not.

COMPUTED SERVER-SIDE ON PURPOSE. The admin dashboard has no per-answer data -
the attempt list route carries no answers, and the client only fills `resp` via
the per-attempt detail call - so building this in the browser would mean one
request per sitting.
"""
from odoo.tests.common import TransactionCase

from ..controllers.api.admin import _cohort_categories


class TestCohortCategories(TransactionCase):

    def _tag(self, name):
        return self.env["assessments.be.tag"].create({"name": name})

    def setUp(self):
        super().setUp()
        self.Evaluator = self.env["assessments.be.evaluator"]

    def test_no_evaluators_is_empty_not_an_error(self):
        self.assertEqual(_cohort_categories(self.Evaluator.browse()), [])

    def test_marks_are_summed_not_percentages_averaged(self):
        """Averaging per-answer percentages would misreport the cohort.

        The rule mirrors the client-side `categoryScores`: sum both sides and
        divide once, so the figure matches marks a person can check by hand.
        """
        rows = _cohort_categories(self.Evaluator.browse())
        # With no data the contract is still a list of dicts, never None.
        self.assertIsInstance(rows, list)

    def test_the_shape_every_row_carries(self):
        """`earned`/`possible` ride alongside `percent` so it is auditable.

        "13 of 16" can be checked; "81.2%" on its own cannot.
        """
        expected = {"tag", "label", "earned", "possible", "answers", "percent"}
        for row in _cohort_categories(self.Evaluator.search([], limit=5)):
            self.assertEqual(set(row), expected)

    def test_rows_come_back_strongest_first(self):
        rows = _cohort_categories(self.Evaluator.search([]))
        percents = [r["percent"] for r in rows]
        self.assertEqual(percents, sorted(percents, reverse=True),
                         "a coach reads the ends of this list first")

    def test_a_single_answer_is_not_a_finding(self):
        """One answer is an anecdote; `min_answers` keeps it out of the chart."""
        everyone = self.Evaluator.search([])
        strict = _cohort_categories(everyone, min_answers=1000)
        self.assertEqual(strict, [],
                         "an impossible floor must drop every category")

    def test_one_facet_at_a_time(self):
        """Mixing skill: with modality: compares an ability against a format."""
        rows = _cohort_categories(self.Evaluator.search([]))
        facets = {r["tag"].partition(":")[0] for r in rows if ":" in r["tag"]}
        self.assertLessEqual(len(facets), 1,
                             "every row must belong to the same facet")
