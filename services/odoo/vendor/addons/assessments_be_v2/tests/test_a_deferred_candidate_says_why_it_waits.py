# -*- coding: utf-8 -*-
"""A call the grader was refused costs no attempt, and the candidate says why.

`docs/ETP_PLANS_AND_STRATEGY.md` §2.5 (W3.1 and W3.5):

  - A 429 (or the local rate ceiling, or a spend cap) leaves the answers
    `pending` with their attempts intact - correct, but silent: a refusal that
    never cleared looked exactly like a queue that never moved. The reason now
    goes in the candidate's existing `llm_error`, no new column.
  - A parallel call opens a cursor of its own. When the database pool is full
    that raised `PoolError`, which was stored like a broken reply - an attempt
    spent, and after three of them an `error` with a zero. A full pool is
    capacity, like a 429: try again next tick.
"""
from unittest.mock import patch
from uuid import uuid4

from psycopg2.pool import PoolError

from odoo.tests.common import TransactionCase, tagged

from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc


@tagged("-at_install", "post_install")
class TestADeferredCandidateSaysWhyItWaits(TransactionCase):

    def setUp(self):
        super().setUp()
        paper = self.env["assessments.be"].create(
            {"name": "Deferred %s" % uuid4().hex[:6]})
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric",
            "prompt": "Describe",
            "assessment_ids": [(4, paper.id)],
        })
        applicant = self.env["hr.applicant"].create(
            {"partner_name": "Cand %s" % uuid4().hex[:6]})
        self.ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id})
        self.answer = self.env["assessments.be.response"].create({
            "assessment_evaluator_id": self.ev.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "assessment_id": paper.id,
            "state": "submitted",
            "justification": "an answer",
            "llm_state": "pending",
        })
        self.ev.write({"state": "submitted", "scoring_requested": True,
                       "llm_state": "pending"})

    def _assert_waiting(self, because):
        self.assertEqual(self.answer.llm_state, "pending")
        self.assertFalse(self.answer.llm_attempts, "no attempt was spent")
        self.assertIn(because, self.ev.llm_error or "",
                      "the candidate does not say why it is still waiting")

    def test_a_429_that_never_clears_is_named_on_the_candidate(self):
        refused = vertex_svc.VertexQuotaError("Vertex quota exhausted [429]")
        with patch.object(vertex_svc, "_call_vertex", side_effect=refused):
            self.ev._action_llm_score()
        self._assert_waiting("429")

    def test_a_spend_cap_is_named_too(self):
        refused = vertex_svc.VertexBudgetError("Daily LLM spend cap reached")
        with patch.object(vertex_svc, "_call_vertex", side_effect=refused):
            self.ev._action_llm_score()
        self._assert_waiting("spend cap")

    def test_the_reason_clears_once_the_candidate_is_graded(self):
        refused = vertex_svc.VertexQuotaError("Vertex quota exhausted [429]")
        with patch.object(vertex_svc, "_call_vertex", side_effect=refused):
            self.ev._action_llm_score()
        with patch.object(vertex_svc, "_call_vertex",
                          return_value='{"results": [{"id": %d, "score": 80}]}'
                          % self.answer.id):
            self.ev._action_llm_score()
        self.assertEqual(self.answer.llm_state, "scored")
        self.assertFalse(self.ev.llm_error)

    def test_a_full_db_pool_is_a_deferral_not_a_spent_attempt(self):
        registry = self.env.registry
        with patch.object(registry, "cursor",
                          side_effect=PoolError("The Connection Pool Is Full")), \
                patch.object(vertex_svc, "_call_vertex",
                             side_effect=AssertionError("never reached")), \
                patch.object(self.env.cr, "commit", self.env.flush_all):
            self.env["assessments.be"]._drain_in_parallel(self.ev, workers=2)
        self._assert_waiting("pool is full")

    def test_a_full_pool_inside_the_call_is_a_deferral_too(self):
        """A side cursor the call opens (ledger, kill check, bearer) can hit
        the same full pool."""
        with patch.object(scoring_svc, "_grade_job",
                          side_effect=PoolError("The Connection Pool Is Full")):
            _results, error = scoring_svc._grade_outcome(self.env, object())
        self.assertIsInstance(error, vertex_svc.VertexQuotaError)
