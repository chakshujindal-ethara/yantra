# -*- coding: utf-8 -*-
"""Draft from SOP with no Vertex configuration names the setting.

`VertexNotConfiguredError` is a ValueError, and the route caught every other
refusal but not this one, so the admin got a generic 500 "Unexpected server
error" and a traceback. It now answers in the route's own refusal shape, with
the error's own words: what is missing and where to set it. The real draft
service runs; only the network is cut.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..services import vertex
from . import test_the_template_routes_refuse_a_non_manager as _routes


@tagged("-at_install", "post_install")
class TestDraftFromSopSaysVertexIsNotConfigured(TransactionCase):

    _call = _routes.TestTheTemplateRoutesRefuseANonManager._call
    _code = staticmethod(_routes.TestTheTemplateRoutesRefuseANonManager._code)
    _manager_user = (
        _routes.TestTheTemplateRoutesRefuseANonManager._manager_user)

    def setUp(self):
        super().setUp()
        from ..controllers.api import task_templates as api
        self.controller = api.AssessmentsBeTaskTemplateApi()
        icp = self.env["ir.config_parameter"].sudo()
        for key in ("vertex_api_key", "vertex_access_token",
                    "vertex_service_account_json"):
            icp.set_param("assessments_be_v2.%s" % key, "")
        self.gen = self.env["assessments.be.prompt"].create({
            "name": "Unconfigured %s" % uuid4().hex[:6],
            "source_text": "Compare two AI images against a prompt."})

    def test_the_admin_is_told_what_to_set(self):
        with patch.object(vertex, "_httpx",
                          side_effect=AssertionError("no network")):
            reply = self._call("task_template_draft", self._manager_user(),
                               generator_id=self.gen.id)

        self.assertEqual((reply["__status"], self._code(reply)),
                         (503, "not_configured"), reply)
        message = reply["error"]["message"]
        self.assertIn("not configured", message)
        self.assertIn("Settings > Assessments v2 > Vertex AI", message)
