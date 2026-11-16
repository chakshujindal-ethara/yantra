# -*- coding: utf-8 -*-
"""W1, the half that was missed: the gateway's `auth='none'` sign-in routes.

`test_a_browser_language_the_server_lacks_still_signs_in.py` covers the routes
that resolve a bearer - `_auth_method_user` / `_auth_method_public` call
`_adopt_gateway_token`, which fixes the language before any ORM call.

`/api/v1/auth_token`, `refresh_token`, `forgot_password` and `reset_password`
are `auth='none'`. That method resolves no identity and calls no adopter, so a
cold no-cookie request keeps `lang` = `Accept-Language` = `en_GB` all the way
into `request.session.authenticate`, whose `has_group` rebuilds
`_get_group_definitions` - a read ordered by a TRANSLATED field, which asks
`env.lang` and raises "Invalid language code: en_GB". The route's own
`except Exception` then reports it as "Login failed. Please check your
credentials.", which sends a candidate whose password was right to Forgot
Password: the reset-email storm W1 exists to stop.

A COLD GROUP CACHE is the precondition and it is the prod state after every
deploy, so each request clears it first - warm, the ordering is never reached
and the defect hides.
"""
from uuid import uuid4

from odoo import api, http
from odoo.tests import tagged
from odoo.tests.common import HttpCase, TransactionCase
from odoo.tools import mute_logger

_JSON = {"Content-Type": "application/json"}


def _lang_active(env, code):
    return bool(env["res.lang"]._get_data(code=code).code)


@tagged("-at_install", "post_install")
class TestTheSignInRouteSpeaksAnInstalledLanguage(HttpCase):

    def setUp(self):
        super().setUp()
        if "api.access_token" not in self.env:
            self.skipTest("api_auth_gateway is not installed")
        if _lang_active(self.env, "en_GB"):
            self.skipTest("en_GB is installed here, so the defect cannot occur")
        self.password = "w1auth-%s" % uuid4().hex[:10]
        self.login = "w1auth_%s@example.com" % uuid4().hex[:8]
        self.env["res.users"].sudo().with_context(
            no_reset_password=True, mail_create_nolog=True,
            tracking_disable=True,
        ).create({
            "name": "W1 sign-in fixture", "login": self.login,
            "password": self.password,
            "group_ids": [(6, 0, [self.env.ref("base.group_user").id])],
        })

    def _auth_token(self, accept_language, password=None):
        # NO SESSION COOKIE, which is the whole point: `HttpCase.setUp` seeds
        # one whose context already says `en_US`, and a seeded language is
        # never taken from `Accept-Language` (`http.py:1779`). A candidate
        # signing in has no cookie yet, so Odoo builds the session from the
        # header - which is how `en_GB` gets in.
        self.opener.cookies.clear()
        self.env.registry.clear_cache("groups")
        response = self.url_open(
            "/api/v1/auth_token",
            data='{"login": "%s", "password": "%s"}'
                 % (self.login, password or self.password),
            headers=dict(_JSON, **{"Accept-Language": accept_language}),
            timeout=30)
        return response.status_code, response.json()

    @mute_logger("odoo.sql_db")
    def test_an_en_gb_browser_is_signed_in(self):
        status, payload = self._auth_token("en-GB,en;q=0.9")
        self.assertEqual(
            status, 200,
            "a correct password from an en-GB browser was refused %s - the "
            "uninstalled language broke sign-in on a cold pod: %s"
            % (status, payload))
        self.assertTrue(payload["data"]["access_token"], payload)

    @mute_logger("odoo.sql_db")
    def test_an_installed_language_is_unaffected(self):
        status, payload = self._auth_token("en-US")
        self.assertEqual(status, 200, payload)
        self.assertTrue(payload["data"]["access_token"], payload)

    def test_a_wrong_password_is_still_a_wrong_password(self):
        """The guard fixes the language, never the verdict."""
        status, payload = self._auth_token("en-GB", password="not-the-one")
        # 429 when the shared per-IP cooldown has tripped on this run; either
        # way it is a refusal, and neither is a server-side language fault.
        self.assertIn(status, (400, 429), payload)


class _Request:
    """The three things the auth hooks read off `request`."""

    def __init__(self, env, path):
        self.env = env
        self.httprequest = type(
            "R", (), {"headers": {}, "path": path})()

    def update_env(self, user=None, context=None, su=None):
        self.env = self.env(user=user, context=context, su=su)


@tagged("-at_install", "post_install")
class TestAuthNoneFixesTheLanguage(TransactionCase):
    """The hook itself, which is where the end-to-end case cannot reach.

    `ir.http._pre_dispatch` (core) normalises the language for every matched
    route, but it runs AFTER `_authenticate` - so the HttpCase above passes
    either way on Odoo 19 and only guards the round trip. What the fix
    actually changes is the language DURING authentication, and that is what
    this pins: without the `_auth_method_none` override the context comes back
    still saying `en_GB`.
    """

    def setUp(self):
        super().setUp()
        if _lang_active(self.env, "en_GB"):
            self.skipTest("en_GB is installed here, so the defect cannot occur")

    def _authenticate_none(self, path):
        env = self.env(user=None, context=dict(self.env.context, lang="en_GB",
                                               tz="Asia/Kolkata"))
        fake = _Request(env, path)
        # ON THE REQUEST STACK, not as a module attribute: the stock
        # `_auth_method_none` reads `request` through core's own import, which
        # is the same LocalProxy this stack feeds.
        #
        # The stock method also re-points the transaction's default
        # environment at its uid-less one; the rest of this test case still
        # wants its own.
        default_env = env.transaction.default_env
        http._request_stack.push(fake)
        try:
            # Through the REGISTRY class, not the one in the module: `super()`
            # only resolves on the class Odoo builds from every override.
            self.env.registry["ir.http"]._auth_method_none()
        finally:
            http._request_stack.pop()
            env.transaction.default_env = default_env
        return fake

    def test_an_api_sign_in_route_is_given_an_installed_language(self):
        fake = self._authenticate_none("/api/v1/auth_token")
        self.assertEqual(
            fake.env.context["lang"], "en_US",
            "an auth='none' API route still authenticates under a language "
            "this server does not have")
        self.assertEqual(fake.env.context["tz"], "Asia/Kolkata",
                         "the time zone is not the language's to change")

    def test_a_non_api_route_is_left_exactly_as_it_was(self):
        fake = self._authenticate_none("/web/login")
        self.assertEqual(fake.env.context["lang"], "en_GB")

    def test_the_environment_is_still_the_one_auth_none_builds(self):
        fake = self._authenticate_none("/api/v1/auth_token")
        self.assertIsNone(fake.env.uid)
        self.assertIsInstance(fake.env, api.Environment)
