# -*- coding: utf-8 -*-
"""Grading a candidate writes that candidate's rows, and nothing another lane
is writing at the same time.

THE DEFECT, measured on prod on 2026-09-22 (`docs/ETP_PLANS_AND_STRATEGY.md`
§3.3): 348 of 707 grading calls in 24 h (~49%) were billed and then thrown
away on `SerializationFailure`. Every graded candidate raised
`score_outlier_stale` on the ONE paper row all four lanes share - flushed after
the 30-60s Vertex call, and Odoo's `write()` bumps `write_date` even when the
flag is already true - so any lane that committed in that window doomed it.
The minutely recompute cron also rewrote every evaluator row of the paper,
changed or not. And after one failure the lane kept its dead snapshot, so the
rest of its tick failed too, each after paying for its call.

HOW "WRITTEN" IS MEASURED. A row's `ctid` moves on every UPDATE, even one that
stores the same value, so comparing ctids before and after is a direct "was
this row written" check - inside one transaction, where `write_date` cannot
tell the difference.
"""
import json
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from psycopg2.errors import SerializationFailure

from odoo import fields
from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger

from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc


class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Collision gen %s" % uuid4().hex[:6]})
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.score_outlier_sigma", "2.0")
        self.answers_of = {}

    def _paper(self, raw_scores=None, pending=0):
        """A paper with one submitted candidate per entry of ``raw_scores``
        (one scored subjective answer each) plus ``pending`` candidates queued
        with one unscored answer."""
        paper = self.env["assessments.be"].create({
            "name": "Collision paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "subjective_threshold": 50.0,
        })
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric",
            "prompt": "Describe the check you applied.",
            "generator_id": self.generator.id,
            "assessment_ids": [(4, paper.id)],
        })
        entries = [(raw, True) for raw in (raw_scores or [])]
        entries += [(None, False) for _ in range(pending)]
        evaluators = self.env["assessments.be.evaluator"]
        for raw, scored in entries:
            applicant = self.env["hr.applicant"].create({
                "partner_name": "Cand %s" % uuid4().hex[:6]})
            ev = self.env["assessments.be.evaluator"].create({
                "assessment_id": paper.id, "applicant_id": applicant.id})
            self.env["assessments.be.response"].create({
                "assessment_evaluator_id": ev.id,
                "evaluator_id": applicant.id,
                "question_id": question.id,
                "assessment_id": paper.id,
                "state": "submitted",
                "justification": "An answer worth %s" % raw,
                "llm_raw_100": float(raw or 0.0),
                "llm_state": "scored" if scored else "pending",
            })
            ev.write({"state": "submitted",
                      "scoring_requested": not scored,
                      "llm_state": "scored" if scored else "pending"})
            evaluators |= ev
        # Read here, not by the judge: a parallel lane calls it on a worker
        # thread, and this test's cursor must not be used from two threads.
        self.answers_of.update(
            {ev.id: ev.response_ids.ids for ev in evaluators})
        return paper, evaluators

    def _ctids(self, records):
        self.env.flush_all()
        self.env.cr.execute(
            'SELECT id, ctid FROM "%s" WHERE id = ANY(%%s)' % records._table,
            [records.ids])
        return dict(self.env.cr.fetchall())

    def _judge(self, env, system_prompt, user_text, **kwargs):
        """Vertex, standing in: 80 for every answer of the candidate billed."""
        return json.dumps({"results": [
            {"id": rid, "score": 80}
            for rid in self.answers_of[kwargs["usage_ctx"]["evaluator_id"]]]})


@tagged("-at_install", "post_install")
class TestGradingWritesOnlyTheCandidatesOwnRows(_Base):

    def _assert_only_graded_rows_moved(self, paper, graded, peers):
        self.assertEqual(
            self._ctids(paper), self.before_paper,
            "grading wrote the paper row every lane shares - the "
            "SerializationFailure that threw away ~49% of prod's calls")
        self.assertEqual(self._ctids(peers), self.before_peers,
                         "grading wrote another candidate's attempt")
        self.assertEqual(self._ctids(peers.response_ids),
                         self.before_peer_answers,
                         "grading wrote another candidate's answers")
        self.assertEqual(graded.llm_state, "scored",
                         "fixture guard: the candidate really was graded")

    def _snapshot(self, paper, peers):
        self.before_paper = self._ctids(paper)
        self.before_peers = self._ctids(peers)
        self.before_peer_answers = self._ctids(peers.response_ids)

    def test_a_serial_lane_writes_only_the_candidate_it_graded(self):
        paper, cohort = self._paper(pending=3)
        graded, peers = cohort[0], cohort[1:]
        self._snapshot(paper, peers)

        with patch.object(vertex_svc, "_call_vertex", self._judge):
            graded._action_llm_score()

        self._assert_only_graded_rows_moved(paper, graded, peers)

    def test_a_parallel_lane_writes_only_the_candidates_it_graded(self):
        paper, cohort = self._paper(pending=3)
        graded, peers = cohort[:2], cohort[2:]
        self._snapshot(paper, peers)

        with patch.object(vertex_svc, "_call_vertex", self._judge), \
                patch.object(scoring_svc, "_grade_on_own_cursor",
                             lambda registry, uid, ctx, job:
                             scoring_svc._grade_outcome(self.env, job)), \
                patch.object(self.env.cr, "commit", self.env.flush_all):
            self.env["assessments.be"]._drain_in_parallel(graded, workers=2)

        for ev in graded:
            self._assert_only_graded_rows_moved(paper, ev, peers)


@tagged("-at_install", "post_install")
class TestTheOutlierPassWritesOnlyWhatChanged(_Base):
    """The cohort pass used to rewrite every evaluator row of the paper each
    minute, so a candidate mid-grade collided with it too."""

    def setUp(self):
        super().setUp()
        self.paper, self.cohort = self._paper([50, 52, 48, 51, 49, 99])
        self.cohort._recompute_cohort_outliers()
        self.assertEqual(
            self.cohort.filtered("score_outlier").mapped(
                "subjective_raw_percent"), [99.0],
            "fixture guard: exactly the 99 is an outlier")

    def _pass(self):
        # A new cron transaction starts with nothing cached.
        self.env.invalidate_all()
        before = self._ctids(self.cohort)
        self.cohort._recompute_cohort_outliers()
        after = self._ctids(self.cohort)
        return {i for i in before if before[i] != after[i]}

    def test_a_second_pass_writes_no_row(self):
        self.assertEqual(self._pass(), set(),
                         "nothing changed, so nothing may be written")

    def test_only_the_row_whose_flag_flips_is_written(self):
        wrong = self.cohort[0]
        self.env.cr.execute(
            "UPDATE assessments_be_evaluator SET score_outlier = true "
            "WHERE id = %s", [wrong.id])

        written = self._pass()

        self.assertEqual(written, {wrong.id})
        self.assertFalse(wrong.score_outlier)
        self.assertTrue(self.cohort[-1].score_outlier,
                        "the real outlier keeps its flag, unwritten")


@tagged("-at_install", "post_install")
class TestAStalePaperIsFoundFromTheData(_Base):
    """Stale = a candidate scored after the paper's last check (10-minute
    overlap), or the old flag still up. Nothing a grading lane writes."""

    def setUp(self):
        super().setUp()
        self.now = fields.Datetime.now()
        # Every paper already in the database is checked "tomorrow", so only
        # this test's papers can be stale.
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be SET score_outlier_stale = false, "
            "score_outlier_checked_at = %s", [self.now + timedelta(days=1)])
        self.env.invalidate_all()
        self.icp = self.env["ir.config_parameter"].sudo()
        self.Assessment = self.env["assessments.be"]
        self.icp.set_param(self.Assessment.OUTLIER_CHECKS_SINCE_PARAM,
                           fields.Datetime.to_string(
                               self.now - timedelta(hours=6)))

    def _scored_paper(self, scored_ago, checked_ago=None):
        paper, cohort = self._paper([60])
        cohort.llm_scored_at = self.now - scored_ago
        if checked_ago is not None:
            paper.score_outlier_checked_at = self.now - checked_ago
        return paper

    def _stale(self):
        return self.Assessment._outlier_stale_papers(limit=1000)

    def test_a_candidate_scored_after_the_check_makes_the_paper_stale(self):
        """Also the catch-up after a pause: a cron that did not run for two
        hours still finds everything scored in them."""
        paused = self._scored_paper(timedelta(hours=1), timedelta(hours=2))
        quiet = self._scored_paper(timedelta(hours=3), timedelta(hours=2))

        stale = self._stale()

        self.assertIn(paused, stale)
        self.assertNotIn(quiet, stale)

    def test_a_score_saved_while_a_check_ran_is_caught_by_the_overlap(self):
        late = self._scored_paper(timedelta(minutes=5), timedelta(0))
        settled = self._scored_paper(timedelta(minutes=20), timedelta(0))

        stale = self._stale()

        self.assertIn(late, stale)
        self.assertNotIn(settled, stale)

    def test_a_paper_never_checked_is_stale_once_scored_after_deploy(self):
        after = self._scored_paper(timedelta(hours=1))
        before = self._scored_paper(timedelta(days=3))
        flagged = self._scored_paper(timedelta(days=3))
        flagged.score_outlier_stale = True

        stale = self._stale()

        self.assertIn(after, stale)
        self.assertNotIn(before, stale)
        self.assertIn(flagged, stale, "the old flag is still honoured")

    def test_the_first_run_writes_no_historical_paper(self):
        self.icp.search([
            ("key", "=", self.Assessment.OUTLIER_CHECKS_SINCE_PARAM)]).unlink()
        historical = self._scored_paper(timedelta(days=3))
        recomputed = []
        Evaluator = type(self.env["assessments.be.evaluator"])
        original = Evaluator._recompute_cohort_outliers

        def _spy(records):
            recomputed.extend(records.mapped("assessment_id").ids)
            return original(records)

        with patch.object(Evaluator, "_recompute_cohort_outliers", _spy):
            self.Assessment._cron_recompute_subjective_results(commit=False)

        self.assertTrue(
            self.icp.get_param(self.Assessment.OUTLIER_CHECKS_SINCE_PARAM),
            "the first run records when checking began")
        self.assertNotIn(historical.id, recomputed)
        self.assertFalse(historical.score_outlier_checked_at)

    def test_the_cron_stamps_its_check_and_lowers_the_old_flag(self):
        paper = self._scored_paper(timedelta(minutes=1), timedelta(hours=1))
        paper.score_outlier_stale = True

        self.Assessment._cron_recompute_subjective_results(commit=False)

        self.assertFalse(paper.score_outlier_stale)
        self.assertGreaterEqual(paper.score_outlier_checked_at, self.now)


@tagged("-at_install", "post_install")
class TestALaneStartsAFreshSnapshotAfterACollision(_Base):

    def _tick(self, fail_with):
        paper, cohort = self._paper(pending=2)
        first, second = cohort
        graded = []
        Assessment = type(self.env["assessments.be"])
        Evaluator = type(self.env["assessments.be.evaluator"])

        def _score(records):
            if records == first:
                raise fail_with
            graded.extend(records.ids)
            return 0

        with patch.object(self.env.cr, "commit", self.env.flush_all), \
                patch.object(self.env.cr, "rollback") as rollback, \
                patch.object(Evaluator, "_action_llm_score", _score), \
                patch.object(Assessment, "_scoring_shard_evaluators",
                             lambda self, *a, **k: cohort):
            self.env["assessments.be"]._cron_llm_auto_score(shard=0)
        self.assertEqual(graded, [second.id],
                         "the next candidate is still graded")
        return rollback

    @mute_logger("odoo.addons.assessments_be_v2.models.assessment")
    def test_a_serialization_failure_rolls_back_before_the_next_one(self):
        rollback = self._tick(SerializationFailure(
            "could not serialize access due to concurrent update"))
        rollback.assert_called_once_with()

    @mute_logger("odoo.addons.assessments_be_v2.models.assessment")
    def test_an_ordinary_failure_keeps_the_transaction(self):
        rollback = self._tick(ValueError("grader reply did not parse"))
        rollback.assert_not_called()


@tagged("-at_install", "post_install")
class TestTheBearerIsMintedOnItsOwnCursor(_Base):
    """Minting on the lane's cursor held the refresh lock and the
    `ir.config_parameter` writes for the whole Vertex call."""

    def test_minting_uses_a_short_cursor_of_its_own(self):
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.vertex_access_token", "")
        cursors = []

        def _mint(env):
            cursors.append(env.cr)
            return "minted-token"

        with patch.object(vertex_svc, "_side_cursor_is_safe",
                          return_value=True), \
                patch.object(vertex_svc, "_minted_bearer", _mint):
            token = vertex_svc._vertex_bearer(self.env)

        self.assertEqual(token, "minted-token")
        self.assertIsNot(cursors[0], self.env.cr)
        self.assertTrue(cursors[0].closed, "and it is closed straight away")
