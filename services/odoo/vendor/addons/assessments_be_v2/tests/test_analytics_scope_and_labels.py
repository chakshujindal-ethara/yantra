# -*- coding: utf-8 -*-
"""Two analytics defects the dashboard made visible.

1. THE LEADERBOARD IGNORED THE ASSESSMENT FILTER. The dashboard has had an
   assessment select on it all along, and every panel narrowed with it except
   the ranking - which kept showing a cross-assessment board beside figures for
   one paper. It could not be fixed on the client: the rows are grouped by
   candidate, so by the time they leave this route the assessment dimension is
   gone. The domain below is the only place the narrowing can happen.

2. CATEGORY LABELS WERE MACHINE KEYS. `_cohort_categories` built its label by
   chopping the facet off the tag name, handing the client
   `ai-image-editing` - and the client's own fallback capitalises the first
   word only, so five surfaces read "Ai image editing". The tag model already
   carries `display`, a readable alias minted once per key and pinned forever;
   it was simply not being read.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase

from ..controllers.api.admin import _cohort_categories


class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Tag = self.env["assessments.be.tag"]
        self.Question = self.env["assessments.be.question"]
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Analytics fixture %s" % uuid4().hex[:6]})

    def _question(self, tags):
        question = self.Question.create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Answer it.",
            "generator_id": self.generator.id,
            "tag_ids": [(6, 0, tags.ids)],
        })
        return question

    def _sitting(self, assessment, question, mark, applicant=None):
        applicant = applicant or self.Applicant.create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "c_%s@example.com" % uuid4().hex[:8],
        })
        evaluator = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
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

    def _assessment(self, question):
        return self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
        })


class TestCategoryLabelsAreReadable(_Base):

    def test_the_tags_pinned_display_is_the_label(self):
        """THE fix. `display` is authored once per key and never changes, so
        every surface showing this category shows the same words."""
        # Unique for the same reason as the fallback test below: this key is in
        # the seeded vocabulary too, so a hardcoded name errors on any database
        # that carries real tags rather than testing the pinned display.
        key = "skill:ai-image-editing-%s" % uuid4().hex[:4]
        tag = self.Tag.create({"name": key, "display": "AI Image Editing"})
        question = self._question(tag)
        assessment = self._assessment(question)
        evaluator = self._sitting(assessment, question, 90.0)
        self._sitting(assessment, question, 80.0)

        rows = _cohort_categories(
            evaluator | self.Evaluator.search(
                [("assessment_id", "=", assessment.id)]))

        self.assertTrue(rows)
        row = next(r for r in rows if r["tag"] == key)
        self.assertEqual(row["label"], "AI Image Editing")
        self.assertEqual(
            row["tag"], key,
            "the machine key must survive alongside it - grouping and linking "
            "still key on it")

    def test_a_tag_with_no_display_falls_back_to_a_readable_key(self):
        """An older row, or one added by hand, has no pinned alias.

        The fallback is the model's own `_default_display`, so a label is never
        the raw hyphenated key even here.
        """
        # A UNIQUE KEY, like the two tests below already use. The name was
        # hardcoded as `skill:load-handling`, which the seeded vocabulary also
        # carries - so on any database with real data (every local rig, and CI
        # against a restored dump) `create` hit the model's own uniqueness
        # constraint and the test ERRORED with "Tag 'skill:load-handling' already
        # exists" before asserting anything. It passed only on an empty database.
        #
        # The two-word hyphenated shape is what the assertion is about, so that is
        # preserved: the suffix keeps the key unique without changing what is
        # being tested, which is that `_default_display` title-cases a hyphenated
        # machine key instead of letting it reach the screen raw.
        key = "skill:load-handling-%s" % uuid4().hex[:4]
        tag = self.Tag.create({"name": key, "display": ""})
        question = self._question(tag)
        assessment = self._assessment(question)
        evaluator = self._sitting(assessment, question, 90.0)
        self._sitting(assessment, question, 70.0)

        rows = _cohort_categories(
            evaluator | self.Evaluator.search(
                [("assessment_id", "=", assessment.id)]))

        row = next(r for r in rows if r["tag"] == key)
        self.assertTrue(row["label"].startswith("Load Handling"))
        self.assertNotIn(
            "-", row["label"],
            "a hyphenated machine key reached the screen")


class TestTheLeaderboardCanBeScoped(_Base):
    """Driven through the route, because the domain IS the feature."""

    def setUp(self):
        super().setUp()
        self.controller = self._controller()
        # The route is `@require_manager`. Without the group it answers a 403
        # envelope with no `data` key, and every assertion below would be
        # testing the gate rather than the domain.
        self.env.user.group_ids = [
            (4, self.env.ref("assessments_be_v2.group_assessment_manager").id)]

    @staticmethod
    def _controller():
        import inspect
        from odoo import http
        from ..controllers.api import admin as admin_api
        for _name, obj in vars(admin_api).items():
            if (inspect.isclass(obj) and issubclass(obj, http.Controller)
                    and obj.__module__ == admin_api.__name__
                    and hasattr(obj, "leaderboard")):
                return obj()
        raise AssertionError("the admin controller was not found")

    def _board(self, **body):
        from unittest.mock import patch
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
            return self.controller.leaderboard()

    def test_an_unscoped_board_spans_every_assessment(self):
        tag = self.Tag.create({"name": "skill:one-%s" % uuid4().hex[:4]})
        question = self._question(tag)
        first = self._assessment(question)
        second = self._assessment(question)
        self._sitting(first, question, 90.0)
        self._sitting(second, question, 40.0)

        rows = self._board(limit=200)["data"]
        names = {r["applicant_name"] for r in rows}

        self.assertGreaterEqual(
            len(names), 2,
            "the unscoped board must still rank across assessments")

    def test_scoping_to_one_assessment_drops_the_others(self):
        """THE regression. Without the domain this returned both candidates
        whatever the dashboard filter said."""
        tag = self.Tag.create({"name": "skill:two-%s" % uuid4().hex[:4]})
        question = self._question(tag)
        mine = self._assessment(question)
        theirs = self._assessment(question)
        here = self._sitting(mine, question, 90.0)
        there = self._sitting(theirs, question, 40.0)

        rows = self._board(limit=200, assessment_id=mine.id)["data"]
        names = {r["applicant_name"] for r in rows}

        self.assertIn(here.applicant_id.partner_name, names)
        self.assertNotIn(
            there.applicant_id.partner_name, names,
            "a candidate who never sat this assessment was ranked on it")

    def test_an_unknown_assessment_ranks_nobody(self):
        """Zero rows, not every row. A filter that silently falls back to
        all-up is worse than one that returns nothing: the screen would report
        the whole cohort under one assessment's name."""
        rows = self._board(limit=200, assessment_id=0x7FFFFFF)["data"]

        self.assertEqual(rows, [])

    def test_passed_counts_released_passes_only(self):
        """The pass-rate tile counts released-and-decided outcomes; the board's
        `passed` must agree, while the candidate is still ranked on every
        submitted attempt, released or not."""
        tag = self.Tag.create({"name": "skill:three-%s" % uuid4().hex[:4]})
        question = self._question(tag)
        paper = self._assessment(question)
        held = self._sitting(paper, question, 95.0)
        shown = self._sitting(paper, question, 95.0)
        self.assertEqual((held.result, shown.result), ("pass", "pass"),
                         "the fixture must produce two passes")
        shown.results_released = True

        rows = {r["applicant_name"]: r for r in
                self._board(limit=200, assessment_id=paper.id)["data"]}
        held_row = rows[held.applicant_id.partner_name]
        shown_row = rows[shown.applicant_id.partner_name]

        self.assertEqual(held_row["passed"], 0,
                         "an unreleased pass was counted")
        self.assertEqual(shown_row["passed"], 1,
                         "a released pass was not counted")
        self.assertEqual((held_row["attempts"], shown_row["attempts"]), (1, 1),
                         "attempts stay over every submitted attempt")
        self.assertEqual(held_row["avg_score"], held.score_percent,
                         "the average stays over unreleased attempts too")


class TestAnUngradedSittingIsNotAScore(_Base):
    """Stage, 2026-10-13: paper 71 had AI grading OFF and attempt 2638 was
    submitted with one written answer nobody scored. Its `score_percent` is
    0.0 and its result `pending` - "not marked yet", not a mark - yet the
    leaderboard ranked it #1 at 0.0, the score bands put it in 0-49 and the
    paper offered to release it. One graded sitting beside it shows each
    aggregate still counts what IS scored."""

    def setUp(self):
        super().setUp()
        self.controller = TestTheLeaderboardCanBeScoped._controller()
        self.env.user.group_ids = [
            (4, self.env.ref("assessments_be_v2.group_assessment_manager").id)]

    def _call(self, method, **body):
        from unittest.mock import patch
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
            return getattr(self.controller, method)()["data"]

    def test_leaderboard_bands_categories_and_release_skip_it(self):
        tag = self.Tag.create({"name": "skill:ungraded-%s" % uuid4().hex[:4]})
        question = self._question(tag)
        paper = self._assessment(question)
        graded = self._sitting(paper, question, 90.0)
        ungraded = self.Evaluator.create({
            "assessment_id": paper.id,
            "applicant_id": self.Applicant.create({
                "partner_name": "Ungraded %s" % uuid4().hex[:6],
                "email_from": "u_%s@example.com" % uuid4().hex[:8],
            }).id,
        })
        self.Response.create({
            "assessment_evaluator_id": ungraded.id,
            "evaluator_id": ungraded.applicant_id.id,
            "question_id": question.id,
            "assessment_id": paper.id,
            "state": "submitted",
            "justification": "Never graded.",
            "llm_state": "pending",
        })
        ungraded.state = "submitted"
        # GUARD THE FIXTURE: attempt 2638's exact shape, beside a real pass.
        self.assertFalse(paper.llm_auto_score)
        self.assertEqual((ungraded.result, ungraded.score_percent),
                         ("pending", 0.0))
        self.assertEqual(graded.result, "pass")

        ranked = {r["applicant_id"]
                  for r in self._call("leaderboard", assessment_id=paper.id)}
        self.assertIn(graded.applicant_id.id, ranked)
        self.assertNotIn(ungraded.applicant_id.id, ranked,
                         "an ungraded sitting was ranked at 0.0")

        data = self._call("analytics", assessment_id=paper.id)
        bands = {b["label"]: b["count"] for b in data["score_bands"]}
        self.assertEqual(bands["0-49"], 0, "an ungraded 0.0 filled the 0-49 bar")
        self.assertEqual(sum(bands.values()), 1, "the graded sitting is counted")
        categories = _cohort_categories(
            paper.assessment_evaluator_ids, min_answers=1)
        self.assertEqual([c["percent"] for c in categories], [100.0],
                         "an unscored answer was averaged in as 0 marks")

        paper.invalidate_recordset()
        self.assertEqual(paper.releasable_count, 1,
                         "only the graded result is releasable")
        self.assertEqual(data["by_assessment"][0]["releasable"], 1)

    def test_the_applicant_rates_skip_it(self):
        """The HR applicant's average and pass rate read DECIDED results: a
        pending one is neither a 0.0 score nor a fail."""
        tag = self.Tag.create({"name": "skill:rate-%s" % uuid4().hex[:4]})
        question = self._question(tag)
        graded = self._sitting(self._assessment(question), question, 90.0)
        ungraded = self._sitting(self._assessment(question), question, 0.0,
                                 applicant=graded.applicant_id)
        ungraded.response_ids.llm_state = "pending"
        self.assertEqual((graded.result, ungraded.result), ("pass", "pending"))

        applicant = graded.applicant_id
        applicant.invalidate_recordset()
        self.assertEqual(applicant.be_submitted_count, 2)
        self.assertEqual(applicant.be_pass_rate, 100.0,
                         "a pending result counted as a fail")
        self.assertEqual(applicant.be_avg_score, graded.score_percent,
                         "a pending 0.0 was averaged in")
