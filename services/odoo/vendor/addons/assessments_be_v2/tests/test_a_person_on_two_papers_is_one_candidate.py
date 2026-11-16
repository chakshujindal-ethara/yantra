"""The "Candidates" figure counts PEOPLE; every other figure counts sittings.

THE DEFECT (SNo 162), reported from stage 2026-09-07 as arithmetically
impossible numbers:

    CANDIDATES 1330, but Passed 1466 ALONE exceeds it
    decided 2248 (1466 + 782) > SUBMITTED 1251
    the cohort bar summed to 2342 under its own caption "1330 sittings"

Neither half was miscounting. There were TWO DENOMINATORS on one screen:

  * `/api/v1/analytics` returned `assigned = len(everyone)`, one row per
    SITTING, and passed/failed/decided were counted from that same recordset.
  * The client's "Candidates" tile summed each assessment's own
    `assignedCount` (dashboard_screen.dart), a different walk over the same
    people.

A candidate who sits two papers is one person and two sittings. Read as
"Candidates", the sittings figure is inflated; compared against passed/failed
counted per sitting, it is inconsistent. Either number alone is defensible -
using one for the other is not.

Measured on etp_local: 198 sittings across 159 distinct people, 11 people
holding more than one, and one candidate (Priya Sharma) counted 14 times.
There are ZERO per-assessment duplicates - the (assessment_id, applicant_id)
unique index guarantees that - so the inflation comes entirely from summing
ACROSS assessments, which is why a per-assessment count looks correct in
isolation.

THE FIX. `totals.people` is added beside `totals.assigned`, so the route states
both and the tile that says "Candidates" divides by the right one. `assigned`
KEEPS its meaning, because `completion_rate` and the score bands are per-sitting
figures and must not silently change - `test_assigned_still_counts_sittings`
pins that.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAPersonOnTwoPapersIsOneCandidate(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Counting fixture %s" % uuid4().hex[:6]})
        self.controller = self._controller()
        # The route is `@require_staff`; without the group every assertion
        # below would be testing the gate rather than the arithmetic.
        self.env.user.group_ids = [
            (4, self.env.ref(
                "assessments_be_v2.group_assessment_manager").id)]
        # WHAT THE DATABASE ALREADY HELD, taken before this test creates a
        # single row. The unscoped route counts every sitting in the tenancy -
        # a clone of etp_local carries ~200 - so the fixture's own contribution
        # can only be asserted as a DELTA. Absolute assertions here would be
        # measuring the seed data, and they would pass or fail depending on
        # which database the suite happened to run against.
        self._baseline = self._totals()

    @staticmethod
    def _controller():
        import inspect

        from odoo import http

        from ..controllers.api import admin as admin_api
        for _name, obj in vars(admin_api).items():
            if (inspect.isclass(obj) and issubclass(obj, http.Controller)
                    and obj.__module__ == admin_api.__name__
                    and hasattr(obj, "analytics")):
                return obj()
        raise AssertionError("the admin controller was not found")

    # ── fixtures ──────────────────────────────────────────────────────

    def _question(self):
        question = self.Question.create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "Pick one",
            "difficulty": "easy",
            "generator_id": self.generator.id,
        })
        self.QDim.create({
            "question_id": question.id,
            "name": "Dim",
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": j * 10, "is_correct": j == 0})
                for j, n in enumerate(("Alpha", "Bravo"))
            ],
        })
        return question

    def _assessment(self, question):
        return self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
            "state": "in_progress",
        })

    def _applicant(self, name):
        return self.Applicant.create({
            "partner_name": name,
            "email_from": "%s@example.com" % uuid4().hex[:10],
        })

    def _sitting(self, assessment, applicant):
        return self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })

    def _totals(self, **body):
        from ..controllers.api import admin as admin_api
        from ..controllers.api import common as api_common

        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = params

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(self.env, dict(body))
        with patch.object(admin_api, "request", fake), \
                patch.object(api_common, "request", fake):
            response = self.controller.analytics()
        self.assertIn(
            "data", response,
            "the route answered without data: %r" % (response,))
        return response["data"]["totals"]

    # ── the defect ────────────────────────────────────────────────────

    def test_one_person_on_two_papers_counts_as_one_candidate(self):
        """THE HEADLINE. Two sittings, one human."""
        question = self._question()
        first = self._assessment(question)
        second = self._assessment(question)
        person = self._applicant("Repeat Sitter")
        self._sitting(first, person)
        self._sitting(second, person)

        # Scoped, because an unscoped call counts every row already in the
        # database (etp_local carries ~200) and the assertion would be about
        # the fixture data rather than the arithmetic. Each paper holds exactly
        # one of this person's two sittings.
        for paper in (first, second):
            scoped = self._totals(assessment_id=paper.id)
            self.assertEqual(
                scoped["people"], 1,
                "a candidate on two papers is still one candidate")
            self.assertEqual(
                scoped["assigned"], 1,
                "and one sitting on each paper")

        # And unscoped, the pair contributes TWO sittings but only ONE person -
        # asserted as a delta so pre-existing rows cannot affect it.
        both = self._totals()
        self.assertEqual(
            both["assigned"] - self._baseline["assigned"], 2,
            "two sittings were added")
        self.assertEqual(
            both["people"] - self._baseline["people"], 1,
            "but only one new person - the inflation this fixes")

    def test_assigned_still_counts_sittings(self):
        """THE GUARD ON THE FIX.

        `completion_rate` and the score bands are per-SITTING figures. If
        `assigned` were quietly redefined as people, every one of them would
        change meaning without a single test failing.
        """
        question = self._question()
        first = self._assessment(question)
        second = self._assessment(question)
        person = self._applicant("Repeat Sitter")
        self._sitting(first, person)
        self._sitting(second, person)
        self._sitting(first, self._applicant("Somebody Else"))

        totals = self._totals()

        self.assertEqual(
            totals["assigned"] - self._baseline["assigned"], 3,
            "three sittings added")
        self.assertEqual(
            totals["people"] - self._baseline["people"], 2,
            "two people added")

    def test_the_two_figures_agree_when_nobody_repeats(self):
        """The common case must not read as an anomaly: with one sitting each,
        the tile and the sittings count are the same number, and the client
        renders 'one sitting each' rather than a confusing note."""
        question = self._question()
        assessment = self._assessment(question)
        for name in ("Alpha", "Bravo", "Charlie"):
            self._sitting(assessment, self._applicant(name))

        totals = self._totals(assessment_id=assessment.id)

        self.assertEqual(totals["people"], 3)
        self.assertEqual(totals["assigned"], 3)

    def test_people_never_exceeds_sittings(self):
        """The invariant that makes the impossible dashboard impossible.

        Every sitting belongs to exactly one person, so people <= sittings
        always. This is the assertion that fails if `people` is ever computed
        from a wider domain than `assigned`.
        """
        question = self._question()
        first = self._assessment(question)
        second = self._assessment(question)
        shared = self._applicant("On Both")
        self._sitting(first, shared)
        self._sitting(second, shared)
        self._sitting(second, self._applicant("On One"))

        totals = self._totals()

        # The invariant holds over the WHOLE database, which is the point.
        self.assertLessEqual(totals["people"], totals["assigned"])
        self.assertEqual(totals["people"] - self._baseline["people"], 2)
        self.assertEqual(totals["assigned"] - self._baseline["assigned"], 3)

    def test_passed_can_never_exceed_the_sittings_it_is_counted_from(self):
        """THE REPORTED SYMPTOM, as an invariant.

        "Passed 1466 > CANDIDATES 1330" was possible only because the two came
        from different walks. Both now come from `everyone`, so passed, failed
        and decided are bounded by `assigned` by construction.
        """
        question = self._question()
        first = self._assessment(question)
        second = self._assessment(question)
        person = self._applicant("Repeat Sitter")
        self._sitting(first, person)
        self._sitting(second, person)

        totals = self._totals()

        for key in ("submitted", "decided", "passed", "failed"):
            self.assertLessEqual(
                totals[key], totals["assigned"],
                "%s exceeded the sittings it is counted from" % key)

    def test_scoping_to_one_assessment_narrows_both_figures(self):
        """The dashboard's assessment filter must narrow `people` too, or the
        tile would keep reporting the whole tenancy while everything beside it
        showed one paper - the same class of mismatch, by a different route."""
        question = self._question()
        first = self._assessment(question)
        second = self._assessment(question)
        person = self._applicant("On Both")
        self._sitting(first, person)
        self._sitting(second, person)
        self._sitting(second, self._applicant("Second Paper Only"))

        scoped = self._totals(assessment_id=first.id)

        self.assertEqual(scoped["assigned"], 1)
        self.assertEqual(
            scoped["people"], 1,
            "the second paper's extra candidate must not be counted here")
