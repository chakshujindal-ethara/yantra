# -*- coding: utf-8 -*-
"""W1 - a browser set to British English must still be signed in.

THE DEFECT, from prod logs (284 failures in 72 h, every one ending in
`UserError: Invalid language code: en_GB`). A Flutter request carries a bearer
and no session cookie, so Odoo builds a fresh session whose language is the
browser's `Accept-Language` (`odoo/http.py`, `best_lang`) - never checked
against the installed languages. `en-GB` becomes `en_GB`, which prod does not
have. `_adopt_gateway_token` then calls `user._is_public()`; on a cold group
cache that rebuilds `_get_group_definitions`, which reads `implied_ids` in the
groups' translated order, which asks `env.lang`, which raises. The adopter
swallowed the error, the request stayed anonymous, and every route answered
401 "Your session has expired" - `/auth/me` included, which the app reads as
"no assessment role".

It came and went because the group cache is per process: a cold pod after a
deploy failed every en-GB user until some other request warmed it.

HttpCase for the headline, because the language arrives as a header and the
failure lives in the dispatcher's auth hook. The language choices themselves
are pinned against the helper, which is cheaper and says more.
"""
from datetime import timedelta
from uuid import uuid4

from odoo import fields
from odoo.tests import tagged
from odoo.tests.common import HttpCase, TransactionCase

from ..models import ir_http

_JSON = {"Content-Type": "application/json"}


def _lang_active(env, code):
    return bool(env["res.lang"]._get_data(code=code).code)


@tagged("-at_install", "post_install")
class TestABritishBrowserIsSignedIn(HttpCase):

    def setUp(self):
        super().setUp()
        if "api.access_token" not in self.env:
            self.skipTest("api_auth_gateway is not installed")
        if _lang_active(self.env, "en_GB"):
            self.skipTest("en_GB is installed here, so the defect cannot occur")
        login = "w1_%s@example.com" % uuid4().hex[:8]
        self.user = self.env["res.users"].sudo().with_context(
            no_reset_password=True, mail_create_nolog=True,
            tracking_disable=True,
        ).create({
            "name": "W1 fixture", "login": login, "password": login,
            "group_ids": [(6, 0, [self.env.ref("base.group_user").id])],
        })
        self.token = self.env["api.access_token"].sudo().create({
            "user_id": self.user.id,
            "expiry": fields.Datetime.now() + timedelta(hours=1),
            "access_token": uuid4().hex,
            "refresh_token": uuid4().hex,
        }).access_token

    def _me(self, accept_language):
        # A COLD GROUP CACHE is the precondition, and it is the prod state
        # after every deploy. Warm, `_is_public()` never reaches the ordering
        # that reads the language, so the bug hides.
        self.env.registry.clear_cache("groups")
        response = self.url_open(
            "/api/v1/auth/me",
            headers=dict(_JSON, **{
                "Authorization": "Bearer %s" % self.token,
                "Accept-Language": accept_language,
            }),
            timeout=30)
        return response.status_code, response.json()

    def test_an_en_gb_browser_is_adopted_and_answered(self):
        status, payload = self._me("en-GB,en;q=0.9")
        self.assertEqual(
            status, 200,
            "a valid bearer from an en-GB browser was answered %s - the "
            "uninstalled language broke the token adoption: %s"
            % (status, payload))
        self.assertEqual(payload["data"]["user"]["uid"], self.user.id)

    def test_an_installed_language_is_unaffected(self):
        status, payload = self._me("en-US")
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["user"]["uid"], self.user.id)


class _Request:
    """The three things `_adopt_gateway_token` reads off `request`."""

    def __init__(self, env, headers):
        self.env = env
        self.httprequest = type("R", (), {"headers": headers})()

    def update_env(self, user=None, context=None, su=None):
        self.env = self.env(user=user, context=context, su=su)


@tagged("-at_install", "post_install")
class TestTheLanguageIsReplacedNotTrusted(TransactionCase):

    def setUp(self):
        super().setUp()
        if _lang_active(self.env, "en_GB"):
            self.skipTest("en_GB is installed here, so the defect cannot occur")
        # Activating fr_FR below is rolled back with the test, but the cached
        # list of installed languages is not.
        self.addCleanup(self.env.registry.clear_cache, "stable")

    def test_an_uninstalled_language_falls_back_to_en_us(self):
        self.assertEqual(ir_http._installed_lang(self.env, "en_GB"), "en_US")
        self.assertEqual(ir_http._installed_lang(self.env, "xx_YY"), "en_US")

    def test_an_installed_variant_of_the_same_language_wins(self):
        """fr_BE on a server that has fr_FR reads French, not English."""
        self.env["res.lang"]._activate_lang("fr_FR")
        self.assertEqual(ir_http._installed_lang(self.env, "fr_BE"), "fr_FR")

    def test_installed_and_empty_languages_pass_through(self):
        self.assertEqual(ir_http._installed_lang(self.env, "en_US"), "en_US")
        self.assertFalse(ir_http._installed_lang(self.env, False))

    def test_the_request_language_is_fixed_before_the_token_is_read(self):
        """No token at all - a candidate's public route, signed out. The
        request still must not carry a language nothing can resolve."""
        env = self.env(context=dict(self.env.context, lang="en_GB",
                                    tz="Asia/Kolkata"))
        fake = _Request(env, {})
        original = ir_http.request
        ir_http.request = fake
        try:
            ir_http.IrHttp._adopt_gateway_token()
        finally:
            ir_http.request = original
        self.assertEqual(fake.env.context["lang"], "en_US")
        self.assertEqual(fake.env.context["tz"], "Asia/Kolkata",
                         "the time zone is not the language's to change")

    def test_the_adopted_user_speaks_their_own_language(self):
        if "api.access_token" not in self.env:
            self.skipTest("api_auth_gateway is not installed")
        self.env["res.lang"]._activate_lang("fr_FR")
        user = self.env["res.users"].sudo().with_context(
            no_reset_password=True).create({
                "name": "W1 French", "login": "w1fr_%s" % uuid4().hex[:8],
                "lang": "fr_FR",
                "group_ids": [(6, 0, [self.env.ref("base.group_user").id])],
            })
        raw = uuid4().hex
        self.env["api.access_token"].sudo().create({
            "user_id": user.id,
            "expiry": fields.Datetime.now() + timedelta(hours=1),
            "access_token": raw, "refresh_token": uuid4().hex,
        })
        env = self.env(context=dict(self.env.context, lang="en_GB",
                                    tz="Asia/Kolkata"))
        fake = _Request(env, {"Authorization": "Bearer %s" % raw})
        original = ir_http.request
        ir_http.request = fake
        try:
            ir_http.IrHttp._adopt_gateway_token()
        finally:
            ir_http.request = original
        self.assertEqual(fake.env.uid, user.id)
        self.assertEqual(fake.env.context["lang"], "fr_FR")
        self.assertEqual(fake.env.context["tz"], "Asia/Kolkata")
