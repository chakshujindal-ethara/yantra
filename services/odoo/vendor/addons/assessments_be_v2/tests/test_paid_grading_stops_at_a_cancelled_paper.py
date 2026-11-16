# -*- coding: utf-8 -*-
"""Paid grading cannot be started by hand on a cancelled paper, or over RPC.

pm-ux-admin-13 - "Retry Failed Scoring" and "Run Subjective Evaluation" refuse
a cancelled paper: each click spends an LLM call per answer, and a cohort
somebody called off is abandoned work. The guard is in the model, where both
consoles meet (`POST /scoring/queue` goes through the same actions).

swe-grading-11 - the serial grading pass grades INSIDE the request and checks
no `_being_graded`, so it is `_action_llm_score`: a leading underscore is what
`service/model.get_public_method` refuses, so no manager reaches it through
`/web/dataset/call_kw`.
"""
from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged

from .test_individual_scoring_stays_individual import _Paper


@tagged("-at_install", "post_install")
class TestACancelledPaperIsNotRegraded(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.ev = self._candidate(1, errored=(0,))
        self.paper.state = "cancelled"

    def test_run_subjective_evaluation_is_refused(self):
        with self.assertRaisesRegex(UserError, "cancelled"):
            self.paper.action_llm_score_all()
        self.assertFalse(self.ev.scoring_requested)

    def test_retry_failed_scoring_is_refused(self):
        with self.assertRaisesRegex(UserError, "cancelled"):
            self.paper.action_llm_score_failed()
        self.assertEqual(self._answers(self.ev).llm_state, "error",
                         "a refused retry resets nothing")

    def test_an_active_paper_is_unaffected(self):
        self.paper.state = "in_progress"
        self.paper.action_llm_score_all()
        self.assertTrue(self.ev.scoring_requested)


@tagged("-at_install", "post_install")
class TestGradingIsNotCallableOverRpc(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_the_serial_grading_pass_is_private(self):
        Evaluator = self.env["assessments.be.evaluator"]
        self.assertFalse(
            hasattr(Evaluator, "action_llm_score"),
            "a public `action_llm_score` is reachable by any manager through "
            "/web/dataset/call_kw, which grades inside the web worker and "
            "collides with the lane that owns the candidate")
        self.assertTrue(hasattr(Evaluator, "_action_llm_score"))

    def test_call_kw_refuses_it(self):
        from odoo.service.model import get_public_method
        ev = self._candidate(1)
        with self.assertRaises(Exception):
            get_public_method(ev, "_action_llm_score")
