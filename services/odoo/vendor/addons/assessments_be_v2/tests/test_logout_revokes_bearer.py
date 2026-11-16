# -*- coding: utf-8 -*-
"""Signing out actually revokes the bearer.

THE BUG THIS EXISTS FOR. `ApiClient.logout` branched on which credential it
held and sent a bearer session to the gateway's `/api/v1/auth_token_unlink`.
That route is declared GET-only and reads a custom `access_token` request
header, while the Flutter client always POSTs and only ever sends
`Authorization: Bearer` - so the call was a 405, and correcting only the verb
would have turned it into a 401. Nothing in `api_auth_gateway` accepts a
bearer at all; its `validate_token` decorator reads the same custom header.

The client clears its local state in a `finally`, so the failure was invisible
from the outside: the user was returned to the login screen while their token
stayed valid on the server until it expired. A copied token from a shared
machine kept working after the person had "signed out".

`/api/v1/auth/logout` now revokes it, so one route cleans up whichever
credential arrived and the gateway's own route is left alone for its callers.

These drive the helper rather than the HTTP route, following
`test_api_invariants`: the assertion is about what happens to the token row,
not about transport.
"""
from datetime import timedelta
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import auth as A


class _FakeHeaders(dict):
    """`werkzeug` headers are case-insensitive; a plain dict is not, and the
    helper reads both `Authorization` and the lowercase gateway spellings."""

    def get(self, key, default=None):
        for k, v in self.items():
            if k.lower() == key.lower():
                return v
        return default


class _FakeRequest:
    """Enough of `odoo.http.request` for the helper: the headers it reads and
    the env it looks the token up in."""

    def __init__(self, env, headers):
        self.env = env
        self.httprequest = type("R", (), {"headers": _FakeHeaders(headers)})()


@tagged("-at_install", "post_install")
class TestLogoutRevokesBearer(TransactionCase):

    def setUp(self):
        super().setUp()
        if "api.access_token" not in self.env:
            self.skipTest("api_auth_gateway is not installed")
        self.Token = self.env["api.access_token"]

    def _mint(self, user=None):
        return self.Token.sudo().create({
            "user_id": (user or self.env.user).id,
            "expiry": fields.Datetime.now() + timedelta(seconds=3600),
            "access_token": uuid4().hex,
            "refresh_token": uuid4().hex,
        })

    def _revoke_with(self, headers):
        """Run the helper against a request carrying `headers`."""
        original = A.request
        A.request = _FakeRequest(self.env, headers)
        try:
            return A._revoke_bearer()
        finally:
            A.request = original

    def test_an_authorization_bearer_is_revoked(self):
        token = self._mint()
        raw = token.access_token

        self.assertTrue(
            self._revoke_with({"Authorization": "Bearer %s" % raw}))

        self.assertFalse(
            self.Token.sudo().search([("access_token", "=", raw)]),
            "the row must be gone, or the token still authenticates")

    def test_the_gateway_header_spellings_are_accepted_too(self):
        """`BEARER_HEADERS` is what the gateway's own clients send. Sign-out
        has to revoke those as well, or a caller that authenticates fine
        cannot log out."""
        for spelling in A.BEARER_HEADERS:
            token = self._mint()
            raw = token.access_token
            self.assertTrue(
                self._revoke_with({spelling: raw}),
                "%r presented a valid token and it was not revoked" % spelling)
            self.assertFalse(
                self.Token.sudo().search([("access_token", "=", raw)]))

    def test_only_the_presented_token_is_revoked(self):
        """Signing out on one device must not sign the person out everywhere.

        `find_one_or_create_token` hands the same user a row per session, so a
        blanket delete by user would end sittings on other machines - including
        a candidate mid-exam."""
        mine = self._mint()
        theirs = self._mint()
        raw_mine, raw_theirs = mine.access_token, theirs.access_token

        self._revoke_with({"Authorization": "Bearer %s" % raw_mine})

        self.assertFalse(
            self.Token.sudo().search([("access_token", "=", raw_mine)]))
        self.assertTrue(
            self.Token.sudo().search([("access_token", "=", raw_theirs)]),
            "another session's token was revoked with it")

    def test_an_unknown_token_is_a_silent_no_op(self):
        """Logout must never refuse. The client has already thrown its state
        away by the time it hears back, so a raise here would surface as a
        failed sign-out the user cannot act on."""
        self.assertFalse(
            self._revoke_with({"Authorization": "Bearer %s" % uuid4().hex}))

    def test_a_cookie_only_request_is_a_silent_no_op(self):
        """The session lane presents no bearer; the route still has to work."""
        self.assertFalse(self._revoke_with({}))
        self.assertFalse(self._revoke_with({"Authorization": "Basic abc"}))

    def test_an_empty_bearer_is_not_treated_as_a_token(self):
        """`Bearer ` with nothing after it must not become a search for the
        empty string, which could match a row whose token was never set."""
        blank = self.Token.sudo().create({
            "user_id": self.env.user.id,
            "expiry": fields.Datetime.now() + timedelta(seconds=3600),
            "access_token": "",
            "refresh_token": "",
        })
        self.assertFalse(self._revoke_with({"Authorization": "Bearer "}))
        self.assertTrue(blank.exists(), "an empty presented token matched a row")
        blank.sudo().unlink()
