# -*- coding: utf-8 -*-
"""`/api/v1/auth/password_policy` says the rules the server really enforces.

The set and reset forms showed "8 characters" while etp_security refused
anything under 12 without an uppercase, lowercase, digit and special
character: the user learned the rules one refusal at a time. The route now
publishes them, and the routes' own length check uses the same minimum.
"""
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import auth as auth_api
from ..controllers.api import common as api_common

_PARAM = "auth_password_policy.minlength"


class _FakeRequest:

    def __init__(self, env, body):
        self.env = env
        self.params = dict(body)

    def make_json_response(self, payload, headers=None, status=200):
        return {"__status": status, **payload}


@tagged("-at_install", "post_install")
class TestThePasswordRulesArePublished(TransactionCase):

    def setUp(self):
        super().setUp()
        self.controller = auth_api.EtpAssessmentApiAuth()
        self.Param = self.env["ir.config_parameter"].sudo()
        self.Param.set_param(_PARAM, False)
        self.security = self.env["ir.module.module"].sudo().search(
            [("name", "=", "etp_security")])
        self.security.state = "uninstalled"

    def _call(self, handler, env=None, **body):
        fake = _FakeRequest(env or self.env, body)
        with patch.object(auth_api, "request", fake), \
                patch.object(api_common, "request", fake):
            return getattr(self.controller, handler)()

    def test_without_etp_security_the_controller_floor_applies(self):
        out = self._call("auth_password_policy")

        self.assertTrue(out["ok"], out)
        self.assertEqual(out["data"], {
            "min_length": auth_api.MIN_PASSWORD_LEN, "require": []})

    def test_the_configured_minimum_wins_above_the_floor_only(self):
        self.Param.set_param(_PARAM, "14")
        self.assertEqual(
            self._call("auth_password_policy")["data"]["min_length"], 14)

        self.Param.set_param(_PARAM, "4")
        self.assertEqual(
            self._call("auth_password_policy")["data"]["min_length"],
            auth_api.MIN_PASSWORD_LEN)

    def test_etp_security_adds_its_length_and_character_rules(self):
        if not self.security:
            self.skipTest("etp_security is not on this addons path")
        self.security.state = "installed"

        data = self._call("auth_password_policy")["data"]

        self.assertEqual(data["require"],
                         ["upper", "lower", "digit", "special"])
        self.assertGreaterEqual(data["min_length"], 12)

    def test_the_change_and_reset_routes_refuse_below_the_published_minimum(
            self):
        self.Param.set_param(_PARAM, "12")
        user = self.env["res.users"].create({
            "name": "Policy probe", "login": "policy_probe@example.com",
            "password": "OriginalPass1"})
        ten = "Abcdef123!"

        changed = self._call("auth_password", env=self.env(user=user),
                             new_password=ten)
        reset = self._call("auth_reset_password", token="x" * 20,
                           new_password=ten)

        for out in (changed, reset):
            self.assertEqual(out["__status"], 400, out)
            self.assertEqual(out["error"]["code"], "weak_password")
            self.assertIn("12", out["error"]["message"])
