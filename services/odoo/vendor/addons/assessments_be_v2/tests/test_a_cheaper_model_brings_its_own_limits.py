# -*- coding: utf-8 -*-
"""W14: the catalog knows each model's limits, so a scoring-model swap is config.

A 20-answer grading call asks for 54,000 output tokens. A model whose ceiling
is lower refuses every such request, so the Vertex call clamps to the model's
own maximum. Caching needs each model's minimum cache size and storage price;
an unknown model is priced pessimistically and never cached. Nothing here
calls Vertex: the HTTP layer is a stub that records the request.
"""
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import admin as admin_api
from odoo.addons.assessments_be_v2.controllers.api import common as api_common
from odoo.addons.assessments_be_v2.services import model_catalog, vertex

UNKNOWN = "acme-grader-1"


@tagged("-at_install", "post_install")
class TestTheCatalogKnowsEachModelsLimits(TransactionCase):

    def test_3_1_pro_carries_its_cache_and_output_limits(self):
        model = "gemini-3.1-pro-preview"
        self.assertEqual(model_catalog.max_output_tokens(model), 65536)
        self.assertEqual(model_catalog.cache_min_tokens(model), 4096)
        self.assertEqual(model_catalog.cache_storage_rate(model), 4.50)

    def test_gemini_2_caches_from_2048_tokens(self):
        self.assertEqual(model_catalog.cache_min_tokens("gemini-2.5-pro"), 2048)
        self.assertEqual(model_catalog.cache_min_tokens("gemini-2.0-flash"),
                         2048)

    def test_an_unknown_model_is_priced_pessimistically_and_never_cached(self):
        self.assertFalse(model_catalog.price_is_known(UNKNOWN))
        self.assertEqual(model_catalog.price_for(UNKNOWN),
                         model_catalog.DEFAULT_TEXT_PRICE)
        self.assertIsNone(model_catalog.cache_min_tokens(UNKNOWN))
        self.assertIsNone(model_catalog.cache_storage_rate(UNKNOWN))
        self.assertIsNone(model_catalog.max_output_tokens(UNKNOWN))

    def test_a_model_with_no_cache_size_is_never_cached(self):
        self.assertIsNone(model_catalog.cache_min_tokens("gemini-1.5-pro"))
        self.assertIsNone(model_catalog.cache_storage_rate("gemini-1.5-pro"))

    def test_output_is_clamped_only_where_the_ceiling_is_known(self):
        self.assertEqual(
            model_catalog.clamp_output_tokens("gemini-2.0-flash", 54000), 8192)
        self.assertEqual(model_catalog.clamp_output_tokens(
            "gemini-3.1-pro-preview", 54000), 54000)
        self.assertEqual(model_catalog.clamp_output_tokens(UNKNOWN, 54000),
                         54000)


class _Reply:
    status_code = 200
    text = ""

    def __init__(self, finish="STOP"):
        self.finish = finish

    def json(self):
        return {"candidates": [{"finishReason": self.finish, "content": {
            "parts": [{"text": '{"results": []}'}]}}], "usageMetadata": {}}


@tagged("-at_install", "post_install")
class TestTheVertexCallStaysUnderTheModelsCeiling(TransactionCase):

    def _call(self, model, max_tokens, finish="STOP"):
        sent = []

        class _Client:
            def post(self, url, json=None, headers=None):
                sent.append(json["generationConfig"]["maxOutputTokens"])
                return _Reply(finish)

        with patch.object(vertex, "_vertex_creds",
                          return_value=("p", "global", model, "")), \
                patch.object(vertex, "_gemini_request",
                             return_value=("https://vertex.invalid", {})), \
                patch.object(vertex, "_httpx", return_value=_Client()), \
                patch.object(vertex, "_log_usage"), \
                patch.object(vertex, "_check_budget"), \
                patch.object(vertex, "_check_cancelled"), \
                patch.object(vertex, "_check_scoring_cancelled"):
            vertex._call_vertex_single(self.env, "sys", "hi", model=model,
                                       max_tokens=max_tokens,
                                       response_json=True)
        return sent

    def test_a_20_answer_call_is_clamped_to_a_small_models_maximum(self):
        self.assertEqual(self._call("gemini-2.0-flash", 54000), [8192])

    def test_the_current_model_is_not_clamped(self):
        self.assertEqual(self._call("gemini-3.1-pro-preview", 54000), [54000])

    def test_an_unknown_model_is_sent_what_was_asked(self):
        self.assertEqual(self._call(UNKNOWN, 54000), [54000])

    def test_a_cut_off_reply_is_not_retried_above_the_ceiling(self):
        """The retry doubles the budget; at the model's ceiling there is no
        larger request to make, so it is not re-sent at all."""
        self.assertEqual(self._call("gemini-2.0-flash", 8192, "MAX_TOKENS"),
                         [8192])


class _StubRequest:

    def __init__(self, env):
        self.env = env
        self.params = {}

    def make_json_response(self, payload, headers=None, status=200):
        return dict(payload, _status=status)


@tagged("-at_install", "post_install")
class TestSettingsShowTheModelScoringResolvesTo(TransactionCase):

    def _scoring_settings(self):
        self.env.ref("assessments_be_v2.group_assessment_manager").sudo() \
            .write({"user_ids": [(4, self.env.user.id)]})
        stub = _StubRequest(self.env)
        with patch.object(admin_api, "request", stub), \
                patch.object(api_common, "request", stub):
            answer = admin_api.EtpAssessmentApiAdmin().settings()
        return answer["data"]["scoring"]["resolved_model"]

    def test_a_known_model_reports_its_data(self):
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.scoring_model", "gemini-3.1-pro-preview")
        info = self._scoring_settings()
        self.assertEqual(info["model"], "gemini-3.1-pro-preview")
        self.assertTrue(info["price_known"])
        self.assertTrue(info["capabilities_known"])
        self.assertEqual(info["cache_min_tokens"], 4096)

    def test_an_unknown_model_says_so(self):
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.scoring_model", UNKNOWN)
        info = self._scoring_settings()
        self.assertEqual(info["model"], UNKNOWN)
        self.assertFalse(info["price_known"])
        self.assertFalse(info["capabilities_known"])
        self.assertIsNone(info["cache_min_tokens"])
