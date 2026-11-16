"""Cohort aggregates count the assessments the operator can actually see.

THE DEFECT, found during the pre-handover walkthrough on a migrated clone of
the live database. The dashboard printed two different sitting counts, side by
side, for the same quantity:

    header strip:  "30 assessments  ·  any date  ·  194 sittings"
    CANDIDATES tile subtitle: "198 sittings between them"

and the cohort bar's segments summed to 198 under a caption reading "17 of 194
sittings have not been started yet".

Neither half was miscounting its own population. `assessment_id` is a many2one
to a model with `active`, and Odoo's `active_test` only filters the model being
SEARCHED - so `Evaluator.search([])` reached sittings whose assessment is
ARCHIVED, while `/api/v1/assessments` (and this same route's own
`by_assessment` list) leave archived rows out. The client folded 194 from the
assessments it holds; the server returned 198.

Measured on the clone: 198 sittings on 194 active + 4 archived, the four
belonging to one archived paper, "DEMO Safety Refresher - Results Held". The
leak moved every unscoped total, not just the visible one:

    sittings   198 -> 194        people      159 -> 157
    submitted  181 -> 177        decided     179 -> 175
    passed      39 ->  37

So the PASS RATE was computed over a cohort the operator cannot open, and the
leaderboard ranked people from it.

This is SNo 162's bug class one layer down. There, two client-side denominators
disagreed about what "candidate" meant; here the server and the client disagree
about which POPULATION is in scope. The fix is the same shape: state one
population, and let a caller who wants the other one ask for it - a scoped call
names its assessment explicitly, so an operator reading an archived paper's own
analytics still gets its figures.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAnArchivedPaperIsOutOfTheCohort(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Archive cohort fixture %s" % uuid4().hex[:6]})
        self.controller = self._controller()
        # Both routes under test are staff-gated; without the group every
        # assertion below would be exercising the gate, not the arithmetic.
        self.env.user.group_ids = [
            (4, self.env.ref(
                "assessments_be_v2.group_assessment_manager").id)]

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
        # subjective_rubric, matching `test_analytics_scope_and_labels`: a
        # scored response on one of these drives `result` through its REAL
        # compute. `result` is a STORED COMPUTE (`_compute_result`), so writing
        # "pass" onto the sitting directly is overwritten on the next
        # recomputation - a first draft of this file did exactly that and the
        # pass-rate test measured nothing.
        return self.Question.create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Answer it.",
            "difficulty": "easy",
            "generator_id": self.generator.id,
        })

    def _assessment(self, question):
        return self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
            "state": "in_progress",
        })

    def _sitting(self, assessment, name, question=None, mark=None):
        """One sitting. With `mark`, a SUBMITTED and SCORED one.

        The scored path goes through a real response so `_compute_result`
        reaches its own verdict; `mark` is the LLM's 0-100, and 90 clears the
        default subjective threshold.
        """
        applicant = self.Applicant.create({
            "partner_name": name,
            "email_from": "%s@example.com" % uuid4().hex[:10],
        })
        evaluator = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        if mark is not None:
            self.Response.create({
                "assessment_evaluator_id": evaluator.id,
                "evaluator_id": applicant.id,
                "question_id": question.id,
                "assessment_id": assessment.id,
                "state": "submitted",
                "justification": "An answer.",
                "llm_raw_100": mark,
                "llm_state": "scored",
            })
            evaluator.state = "submitted"
        return evaluator

    def _call(self, method, **body):
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
            response = getattr(self.controller, method)()
        self.assertIn(
            "data", response,
            "%s answered without data: %r" % (method, response))
        return response["data"]

    def _totals(self, **body):
        return self._call("analytics", **body)["totals"]

    # ── the defect ────────────────────────────────────────────────────

    def test_archiving_a_paper_removes_its_sittings_from_the_totals(self):
        """THE HEADLINE. The same rows, before and after the archive.

        Asserted as a DELTA across the archive of one paper, so whatever the
        database already holds cannot affect the result - which matters because
        this route is unscoped and a clone of the live database carries ~200
        sittings of its own.
        """
        question = self._question()
        paper = self._assessment(question)
        for i in range(3):
            self._sitting(paper, "Archived Sitter %d" % i)

        before = self._totals()
        paper.action_archive()
        # The recordset the route searches is rebuilt per call, but the cache
        # is not - without this the second call can answer from rows fetched
        # while the paper was still active and the test would pass vacuously.
        self.Evaluator.invalidate_model()
        after = self._totals()

        self.assertEqual(
            before["assigned"] - after["assigned"], 3,
            "archiving a paper must remove its 3 sittings from the cohort; "
            "they were still counted (this is the reported defect)")
        self.assertEqual(
            before["people"] - after["people"], 3,
            "and its candidates with them")

    def test_an_archived_paper_does_not_move_the_pass_rate(self):
        """WHY IT MATTERS: the rate was computed over unreachable rows.

        A submitted, passed sitting on an archived paper counted in `passed`
        and in `decided`, so the headline pass rate described a cohort the
        operator cannot open - and cannot audit when the figure is questioned.
        """
        question = self._question()
        paper = self._assessment(question)
        sitting = self._sitting(paper, "Archived Passer", question, mark=90.0)
        # Released: the outcome figures count released results only.
        sitting.results_released = True
        # GUARD THE FIXTURE. If the sitting is not actually a pass, both deltas
        # below are 0 - 0 and the test passes while measuring nothing.
        self.assertEqual(
            sitting.result, "pass",
            "the fixture did not reach a pass, so the deltas below would be "
            "vacuous")

        before = self._totals()
        paper.action_archive()
        self.Evaluator.invalidate_model()
        after = self._totals()

        self.assertEqual(
            before["passed"] - after["passed"], 1,
            "an archived paper's pass was still counted")
        self.assertEqual(
            before["decided"] - after["decided"], 1,
            "and still in the pass-rate denominator")

    def test_the_leaderboard_does_not_rank_an_archived_cohort(self):
        """THE SWEEP. The neighbouring aggregate had the same defect.

        `leaderboard` groups by applicant, so by the time the rows reach a
        client the assessment dimension is gone and no client-side filter can
        recover it. Left unfixed, the board would rank people the dashboard
        beside it does not count - the same disagreement between two panels on
        one screen that this route's release gate was fixed for.
        """
        question = self._question()
        paper = self._assessment(question)
        sitting = self._sitting(paper, "Archived Ranker", question, mark=88.0)
        # The board only counts SUBMITTED sittings, so a fixture that never
        # submitted would be absent for a reason unrelated to the archive.
        self.assertEqual(sitting.state, "submitted")

        def ranked_ids():
            # `data` is a BARE LIST for this route, and the row's person key is
            # `applicant_id` - reading `id` would collect a set of Nones and
            # every assertion below would pass without measuring anything.
            rows = self._call("leaderboard", limit=500)
            self.assertIsInstance(rows, list, "leaderboard data is a list")
            return {row["applicant_id"] for row in rows}

        self.assertIn(
            sitting.applicant_id.id, ranked_ids(),
            "the fixture is not on the board at all, so the assertion below "
            "would pass for the wrong reason")

        paper.action_archive()
        self.Evaluator.invalidate_model()
        self.assertNotIn(
            sitting.applicant_id.id, ranked_ids(),
            "an archived paper's candidate is still ranked")

    # ── the carve-out ─────────────────────────────────────────────────

    def test_asking_for_an_archived_paper_by_id_still_answers(self):
        """NOT a blanket exclusion, and this is the line that keeps it honest.

        A caller who names an archived assessment has asked for exactly that
        paper. Filtering it out there would make an archived assessment's own
        analytics silently empty - reporting zero sittings for a paper that
        plainly has some, which is a worse failure than the one being fixed.
        """
        question = self._question()
        paper = self._assessment(question)
        for i in range(2):
            self._sitting(paper, "Scoped Sitter %d" % i)
        paper.action_archive()
        self.Evaluator.invalidate_model()

        scoped = self._totals(assessment_id=paper.id)
        self.assertEqual(
            scoped["assigned"], 2,
            "a scoped call must still report the archived paper's sittings")
        self.assertEqual(scoped["people"], 2)
