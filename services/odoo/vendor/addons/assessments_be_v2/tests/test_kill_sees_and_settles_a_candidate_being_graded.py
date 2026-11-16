# -*- coding: utf-8 -*-
"""Kill Scoring must see a candidate being graded, and park it `cancelled`.

TWO DEFECTS, from the 2026-09-22 regression review
(`docs/ETP_PLANS_AND_STRATEGY.md` §2.5, W3.6):

  1. KILL COULD NOT SEE THE CANDIDATE ON THE WIRE. The lane wrote `scoring`
     inside its grading transaction and committed it only after the Vertex
     call. `action_kill_scoring` runs in a web request on another connection,
     so it read `pending`, parked the row the lane was about to write, and -
     seeing nothing `scoring` - lowered the flag. The in-flight call went
     ahead. Only a second connection can show this, so one test here uses two.
  2. A CALL REFUSED BY THE KILL LEFT THE CANDIDATE `pending`. The refusal is
     stored as "no attempt spent" and the rollup then wrote `pending` - with
     `scoring_requested` already cleared by the settle, which is a candidate no
     drainer will ever select again.
"""
from concurrent.futures import Future
from unittest.mock import patch
from uuid import uuid4

from odoo import SUPERUSER_ID, api
from odoo.tests.common import TransactionCase, tagged

from ..models.assessment import _lane_lock
from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc


def _killed(*args, **kwargs):
    raise vertex_svc.VertexCancelledError(
        "Scoring was cancelled by an admin; this call was not made.")


@tagged("-at_install", "post_install")
class TestARefusedCallParksTheCandidateCancelled(TransactionCase):

    def setUp(self):
        super().setUp()
        self.paper = self.env["assessments.be"].create(
            {"name": "Kill %s" % uuid4().hex[:6]})
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric",
            "prompt": "Describe",
            "assessment_ids": [(4, self.paper.id)],
        })
        applicant = self.env["hr.applicant"].create(
            {"partner_name": "Cand %s" % uuid4().hex[:6]})
        self.ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id})
        self.answer = self.env["assessments.be.response"].create({
            "assessment_evaluator_id": self.ev.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "assessment_id": self.paper.id,
            "state": "submitted",
            "justification": "an answer",
            "llm_state": "pending",
        })
        self.ev.write({"state": "submitted", "scoring_requested": True,
                       "llm_state": "pending"})

    def _assert_parked(self):
        self.assertEqual(self.ev.llm_state, "cancelled")
        self.assertFalse(self.ev.scoring_requested)
        self.assertEqual(self.answer.llm_state, "pending")
        self.assertFalse(self.answer.llm_attempts,
                         "a refused call is not a spent attempt")

    def test_a_serial_lane(self):
        with patch.object(vertex_svc, "_call_vertex", _killed):
            self.ev._action_llm_score()
        self._assert_parked()

    def test_a_parallel_lane(self):
        with patch.object(vertex_svc, "_call_vertex", _killed), \
                patch.object(scoring_svc, "_grade_on_own_cursor",
                             lambda registry, uid, ctx, job:
                             scoring_svc._grade_outcome(self.env, job)), \
                patch.object(self.env.cr, "commit", self.env.flush_all):
            self.env["assessments.be"]._drain_in_parallel(self.ev, workers=2)
        self._assert_parked()

    def test_a_candidate_settled_while_its_call_was_out_stays_cancelled(self):
        """The lane's own checkpoint settles the paper while this candidate's
        call is still out; the refused call then comes back."""
        def _dispatch(job):
            future = Future()
            future.set_result((None, vertex_svc.VertexCancelledError(
                "killed while this call was out")))
            return future

        run = self.ev._llm_score_begin(_dispatch)
        self.paper._settle_scoring_cancelled("the drainer found it flagged")
        self.ev._llm_score_finish(run)

        self._assert_parked()


@tagged("-at_install", "post_install")
class TestKillSeesACandidateBeingGraded(TransactionCase):
    """Two real connections: a lane, and the web request that presses Kill.

    The fixture is committed (a second connection cannot see this test's
    uncommitted rows) and removed again in cleanup.
    """

    def _purge(self, paper_id, applicant_id):
        with self.registry.cursor() as cr:
            env = api.Environment(cr, SUPERUSER_ID, {})
            paper = env["assessments.be"].browse(paper_id)
            paper.assessment_evaluator_ids.unlink()
            paper.with_context(**{
                paper.CONFIRMED_DESTROY_CTX: True}).unlink()
            env["hr.applicant"].browse(applicant_id).unlink()

    def test_kill_leaves_the_graded_candidate_to_its_lane(self):
        with self.registry.cursor() as lane_cr:
            lane = api.Environment(lane_cr, SUPERUSER_ID, {})
            paper = lane["assessments.be"].create(
                {"name": "Kill two connections %s" % uuid4().hex[:6]})
            applicant = lane["hr.applicant"].create(
                {"partner_name": "Cand %s" % uuid4().hex[:6]})
            ev = lane["assessments.be.evaluator"].create({
                "assessment_id": paper.id, "applicant_id": applicant.id})
            ev.write({"state": "submitted", "scoring_requested": True,
                      "llm_state": "pending"})
            lane_cr.commit()
            self.addCleanup(self._purge, paper.id, applicant.id)

            # A running lane holds its shard's lock for the whole tick...
            shard = ev.id % lane["assessments.be"]._scoring_shard_count()
            lane_cr.execute("SELECT pg_try_advisory_lock(%s)",
                            [_lane_lock(shard)])
            if not lane_cr.fetchone()[0]:
                self.skipTest("a real grading lane holds that shard")
            try:
                # ...and this is what it does before its first call goes out.
                lane["assessments.be"]._auto_score_mark_scoring(ev)

                with self.registry.cursor() as kill_cr:
                    kill = api.Environment(kill_cr, SUPERUSER_ID, {})
                    kill["assessments.be"].browse(
                        paper.id).action_kill_scoring()
                    kill.flush_all()
                    seen = kill["assessments.be.evaluator"].browse(ev.id)
                    raised = kill["assessments.be"].browse(
                        paper.id).scoring_cancel_requested
                    state, requested = seen.llm_state, seen.scoring_requested
                    kill_cr.rollback()
            finally:
                lane_cr.execute("SELECT pg_advisory_unlock(%s)",
                                [_lane_lock(shard)])

        self.assertEqual(
            (state, requested), ("scoring", True),
            "Kill parked the candidate a lane is grading - the lane's write "
            "then collides with it, and the flag drops with the call out")
        self.assertTrue(raised,
                        "the flag stays up so the lane's next call is refused")
