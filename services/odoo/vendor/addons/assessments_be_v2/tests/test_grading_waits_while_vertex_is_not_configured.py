# -*- coding: utf-8 -*-
"""No Vertex configuration is a refusal to spend, not a failed grading attempt.

`VertexNotConfiguredError` used to take the generic path: every tick spent an
attempt and, after `llm_max_attempts`, pinned each answer to `error` at 0 - for
a setting the candidate had no part in. Now the answers stay `pending` with
their attempts untouched, the candidate says why, and the log carries a tag of
its own. The real service runs: nothing is stubbed between the cron and the
missing credential.
"""
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from ..services import vertex as vertex_svc
from .test_individual_scoring_stays_individual import _Paper

_SCORING = "odoo.addons.assessments_be_v2.services.scoring"


@tagged("-at_install", "post_install")
class TestGradingWaitsWhileVertexIsNotConfigured(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        icp = self.env["ir.config_parameter"].sudo()
        for key in ("vertex_api_key", "vertex_access_token",
                    "vertex_service_account_json"):
            icp.set_param("assessments_be_v2.%s" % key, "")

    def test_no_configuration_spends_no_attempt_and_says_why(self):
        asha = self._candidate(1, requested=True)
        answer = self._answers(asha)[0]

        with patch.object(vertex_svc, "_httpx",
                          side_effect=AssertionError("no network")), \
                self.assertLogs(_SCORING, level="WARNING") as logged:
            for _tick in range(4):   # more ticks than llm_max_attempts (3)
                asha._action_llm_score()

        self.assertEqual(answer.llm_state, "pending")
        self.assertEqual(answer.llm_attempts, 0,
                         "a missing setting is not the answer's attempt")
        self.assertIn("Settings > Assessments v2 > Vertex AI", asha.llm_error)
        tagged = [l for l in logged.output if "VERTEX_NOT_CONFIGURED" in l]
        self.assertTrue(tagged, logged.output)
        self.assertIn("evaluator %s" % asha.id, tagged[0])
