# -*- coding: utf-8 -*-
"""Self-service password reset: /api/v1/auth/forgot_password and
/api/v1/auth/reset_password.

WHY THIS ADDON HAS ITS OWN. `api_auth_gateway` already implements the same
flow, and the token model these routes use IS its model - reused, not forked.
What could not be reused is the emailed link:
`api_auth_gateway.password_reset_url` is one global system parameter shared by
every app on the database, so pointing it at the assessment client would send
Workflow Manager users here and vice versa.

The two properties worth pinning are the ones that are easy to lose in a
refactor and silent when lost:

  * THE ANSWER IS IDENTICAL whether or not an account exists. Any wording that
    varies turns an unauthenticated route into an account-existence oracle.
  * A USED LINK IS DEAD, and so is every other link outstanding for that user.

The routes are exercised through the controller rather than over HTTP, matching
this suite's convention (see test_candidate_identity's note on the same
choice): what is being tested is the decision, not werkzeug.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase

from ..controllers.api import auth as auth_api
from ..controllers.api import common as api_common


class _FakeRequest:
    """Just enough request for these two handlers."""

    def __init__(self, env, body):
        self.env = env
        self.params = dict(body)
        self.jsonrequest = dict(body)
        self.responses = []

    def make_json_response(self, payload, headers=None, status=200):
        self.responses.append((payload, status))
        return {"__status": status, **payload}


class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        self.controller = auth_api.AssessmentsBeAuthApi() \
            if hasattr(auth_api, "AssessmentsBeAuthApi") else None
        # The class name is not part of the contract; find it rather than
        # hard-coding one, so a rename does not silently skip these tests.
        if self.controller is None:
            import inspect
            from odoo import http
            for _name, obj in vars(auth_api).items():
                if (inspect.isclass(obj) and issubclass(obj, http.Controller)
                        and obj.__module__ == auth_api.__name__):
                    self.controller = obj()
                    break
        self.assertIsNotNone(
            self.controller, "the auth controller class was not found")

        self.email = "reset_%s@example.com" % uuid4().hex[:8]
        self.user = self.env["res.users"].create({
            "name": "Reset candidate",
            "login": self.email,
            "password": "OriginalPass1",
            "group_ids": [(6, 0, [self.env.ref("base.group_portal").id])],
        })
        # The limiter is process-global, so tests would otherwise poison each
        # other in whatever order they happen to run.
        auth_api._RESET_ATTEMPTS.clear()

    def _call(self, handler, **body):
        # BOTH modules. `str_arg`/`arg`/`fail` live in `common` and hold their
        # own reference to `request`; patching only the handler's module leaves
        # them reading the real (unbound) proxy, which raises "object is not
        # bound" out of every argument read.
        fake = _FakeRequest(self.env, body)
        with patch.object(auth_api, "request", fake), \
                patch.object(api_common, "request", fake):
            return handler()

    def forgot(self, **body):
        return self._call(
            lambda: self.controller.auth_forgot_password(), **body)

    def reset(self, **body):
        return self._call(
            lambda: self.controller.auth_reset_password(), **body)


class TestForgotPasswordCannotBeUsedToFindAccounts(_Base):

    def test_a_known_and_an_unknown_address_answer_identically(self):
        """THE property. Anything that differs - wording, shape, status - is an
        oracle for who holds an account on this deployment."""
        known = self.forgot(email=self.email)
        unknown = self.forgot(email="nobody_%s@example.com" % uuid4().hex[:8])

        self.assertEqual(known, unknown)
        self.assertTrue(known.get("ok"))
        self.assertEqual(known["data"]["message"],
                         auth_api.RESET_SENT_MESSAGE)

    def test_a_malformed_address_is_refused_before_anything_happens(self):
        res = self.forgot(email="not-an-email")

        self.assertFalse(res.get("ok"))
        self.assertEqual(res["error"]["code"], "invalid_email")
        self.assertFalse(
            self.env["api.password_reset_token"].sudo().search(
                [("user_id", "=", self.user.id)]),
            "a malformed address must not mint a token for anybody")

    def test_the_route_is_rate_limited(self):
        """`api_auth_gateway`'s equivalent is not, and this one is public: each
        call for a real login mints a token and sends an SMTP message."""
        for _ in range(auth_api.RESET_MAX_PER_WINDOW):
            self.assertTrue(self.forgot(email=self.email).get("ok"))

        blocked = self.forgot(email=self.email)

        self.assertFalse(blocked.get("ok"))
        self.assertEqual(blocked["error"]["code"], "too_many_requests")

    def test_the_limiter_cannot_be_probed_for_an_account_either(self):
        """It runs BEFORE the lookup, so an unknown address is throttled the
        same way - otherwise the 429 itself says "this one is real"."""
        stranger = "stranger_%s@example.com" % uuid4().hex[:8]
        for _ in range(auth_api.RESET_MAX_PER_WINDOW):
            self.forgot(email=stranger)

        self.assertEqual(
            self.forgot(email=stranger)["error"]["code"], "too_many_requests")


class TestResettingAPassword(_Base):

    def _token(self):
        return self.env["api.password_reset_token"].sudo(
        ).generate_reset_token(self.user.id)

    def _accepts(self, plaintext):
        """True when `plaintext` would actually sign this account in.

        Verified against the stored hash rather than through
        `_check_credentials`, which needs a request context this test does not
        have. The hash is read over SQL because `user.password` computes to ''
        for everybody - the same reason `test_candidate_password` reads it that
        way.
        """
        self.env.flush_all()
        self.env.cr.execute(
            "SELECT password FROM res_users WHERE id = %s", (self.user.id,))
        row = self.env.cr.fetchone()
        hashed = (row[0] if row else None) or ""
        if not hashed:
            return False
        valid, _ = self.user._crypt_context().verify_and_update(
            plaintext, hashed)
        return bool(valid)

    def test_a_valid_token_sets_the_password(self):
        token = self._token()

        res = self.reset(token=token, new_password="BrandNewPass1",
                         confirm_password="BrandNewPass1")

        self.assertTrue(res.get("ok"), res)
        self.assertEqual(res["data"]["message"],
                         auth_api.RESET_DONE_MESSAGE)
        # The stored hash is what proves it. A route that answered "ok" without
        # writing would pass every other assertion in this file.
        self.assertTrue(self._accepts("BrandNewPass1"),
                        "the new password does not actually sign the user in")
        self.assertFalse(self._accepts("OriginalPass1"),
                         "the old password still works after a reset")

    def test_a_used_link_is_dead(self):
        token = self._token()
        self.reset(token=token, new_password="BrandNewPass1",
                   confirm_password="BrandNewPass1")

        again = self.reset(token=token, new_password="ThirdPassword1",
                           confirm_password="ThirdPassword1")

        self.assertFalse(again.get("ok"))
        self.assertEqual(again["error"]["code"], "invalid_token")

    def test_every_other_outstanding_link_dies_with_it(self):
        """Two clicks on "forgot password" leave two live links. Using either
        must retire the other, or a mail sitting in an inbox stays a working
        credential after the account has been recovered."""
        first = self._token()
        second = self._token()

        # `generate_reset_token` already retires the previous one on issue.
        self.assertFalse(
            self.reset(token=first, new_password="BrandNewPass1",
                       confirm_password="BrandNewPass1").get("ok"),
            "issuing a second link must retire the first")

        self.assertTrue(
            self.reset(token=second, new_password="BrandNewPass1",
                       confirm_password="BrandNewPass1").get("ok"))
        self.assertFalse(
            self.env["api.password_reset_token"].sudo().search(
                [("user_id", "=", self.user.id), ("used", "=", False)]),
            "no link may survive a completed reset")

    def test_an_unknown_token_is_refused(self):
        res = self.reset(token="not-a-real-token",
                         new_password="BrandNewPass1",
                         confirm_password="BrandNewPass1")

        self.assertEqual(res["error"]["code"], "invalid_token")

    def test_an_expired_token_is_refused(self):
        from datetime import datetime, timedelta

        token = self._token()
        record = self.env["api.password_reset_token"].sudo().search(
            [("token", "=", token)], limit=1)
        record.expiry = datetime.now() - timedelta(minutes=1)

        res = self.reset(token=token, new_password="BrandNewPass1",
                         confirm_password="BrandNewPass1")

        self.assertEqual(res["error"]["code"], "invalid_token")

    def test_the_floor_matches_the_signed_in_change_password_route(self):
        """One account cannot have two different minimums depending on which
        screen set the password. The gateway's own reset allows 6."""
        token = self._token()
        short = "a" * (auth_api.MIN_PASSWORD_LEN - 1)

        res = self.reset(token=token, new_password=short,
                         confirm_password=short)

        self.assertEqual(res["error"]["code"], "weak_password")
        self.assertGreaterEqual(auth_api.MIN_PASSWORD_LEN, 8)

    def test_a_mismatched_confirmation_is_refused(self):
        token = self._token()

        res = self.reset(token=token, new_password="BrandNewPass1",
                         confirm_password="DifferentPass1")

        self.assertEqual(res["error"]["code"], "password_mismatch")

    def test_a_missing_token_says_so_rather_than_expired(self):
        """A truncated link and a stale one need different advice."""
        res = self.reset(token="", new_password="BrandNewPass1",
                         confirm_password="BrandNewPass1")

        self.assertEqual(res["error"]["code"], "missing_token")


class TestTheResetLinkPointsAtThisApp(_Base):

    def test_the_parameter_wins_when_it_is_set(self):
        self.env["ir.config_parameter"].sudo().set_param(
            auth_api.RESET_URL_PARAM, "https://assess.example.com/reset")

        self.assertEqual(
            auth_api._reset_base_url(self.env),
            "https://assess.example.com/reset")

    def test_it_falls_back_to_the_candidate_app_rather_than_odoo(self):
        """A fresh install must mail a working link without a manual step, and
        an Odoo backend URL is not one a candidate can use."""
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param(auth_api.RESET_URL_PARAM, "")
        icp.set_param("assessments_be_v2.candidate_app_base_url",
                      "https://assess.example.com/")

        self.assertEqual(
            auth_api._reset_base_url(self.env),
            "https://assess.example.com" + auth_api.RESET_PATH)

    def test_an_unconfigured_deployment_still_mails_a_reachable_link(self):
        """THE PRODUCTION BUG, pinned at the route's own level.

        Neither parameter set - which is every database nobody configured by
        hand, production included. This used to resolve to
        `https://projects.ethara.ai/reset-password`: the Odoo host, which serves
        its reset flow at `/web/reset_password` and answers the hyphenated path
        with the website's 404. The user got the email, clicked, and hit a dead
        page with no way to finish.

        The pairing table has known the answer all along; the reset link now
        asks it, through the same resolver the exam links use.
        """
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param(auth_api.RESET_URL_PARAM, "")
        icp.set_param("assessments_be_v2.candidate_app_base_url", "")
        icp.set_param("web.base.url", "https://projects.ethara.ai")

        self.assertEqual(
            auth_api._reset_base_url(self.env),
            "https://assessment.ethara.ai" + auth_api.RESET_PATH)

    def test_a_local_clone_mails_a_link_to_the_local_client(self):
        """Port 8069 is Odoo, not the client - a developer's link must not
        point at it either, for the same reason the exam link must not."""
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param(auth_api.RESET_URL_PARAM, "")
        icp.set_param("assessments_be_v2.candidate_app_base_url", "")
        icp.set_param("web.base.url", "http://localhost:8069")

        self.assertEqual(
            auth_api._reset_base_url(self.env),
            "http://localhost:8200" + auth_api.RESET_PATH)

    def test_the_link_that_is_actually_MAILED_points_at_the_app(self):
        """THE GAP THAT LET THE 404 SHIP, closed at the level it happened.

        Every other test in this class calls `_reset_base_url` in isolation. The
        resolver is not what reached the user - `_send_reset_link` is, at
        `auth.py`'s `link = "%s?token=%s" % (_reset_base_url(...), token)` - and
        nothing exercised that line. Reintroduce the bug one line BELOW the
        fixed helper and every unit test here still passes, because none of them
        goes through the route.

        So this one drives the real route and reads the real message.
        """
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param(auth_api.RESET_URL_PARAM, "")
        icp.set_param("assessments_be_v2.candidate_app_base_url", "")
        icp.set_param("web.base.url", "https://projects.ethara.ai")

        self.forgot(email=self.email)

        mail = self.env["mail.mail"].sudo().search(
            [("email_to", "=", self.email)], limit=1, order="id desc")
        self.assertTrue(mail, "the route sent no mail at all")
        body = mail.body_html or ""
        self.assertIn("https://assessment.ethara.ai/reset-password?token=",
                      body)
        self.assertNotIn(
            "projects.ethara.ai", body,
            "the Odoo host has no /reset-password route - this is the 404")

    def test_the_template_actually_renders_the_link_it_is_handed(self):
        """The link travels as a CONTEXT key, which nothing type-checks.

        `_send_reset_link` passes `reset_link` through `with_context`, and the
        template reads `ctx.get('reset_link')`. Rename either side and the mail
        still sends, still looks right in a log, and carries a dead `#` href.
        Rendering the real template is the only thing that catches it.
        """
        template = self.env.ref(
            "assessments_be_v2.mail_template_password_reset")
        link = "https://x.test/reset-password?token=abc123"

        body = template.sudo().with_context(
            reset_link=link, user_name="Reset candidate",
        )._render_field("body_html", [self.user.id])[self.user.id]

        self.assertIn(link, body)
        self.assertNotIn(
            '"#"', body,
            "the button fell back to its placeholder href, so ctx did not "
            "reach the template")

    def test_a_real_address_is_mailed_and_a_stranger_is_not(self):
        """The send path is PROVEN, without weakening the enumeration property.

        `_send_reset_link` swallows every exception on purpose - the answer must
        not vary - so a total failure to send is invisible in the response. The
        response is what stays identical; the DATABASE is where the difference
        is allowed to show, and where a test may look.
        """
        before = self.env["mail.mail"].sudo().search_count([])

        self.forgot(email=self.email)
        self.assertTrue(
            self.env["mail.mail"].sudo().search_count(
                [("email_to", "=", self.email)]),
            "a known address produced no mail, and the route cannot say so")

        stranger = "nobody_%s@example.com" % uuid4().hex[:8]
        after_known = self.env["mail.mail"].sudo().search_count([])
        self.forgot(email=stranger)

        self.assertEqual(
            self.env["mail.mail"].sudo().search_count([]), after_known,
            "an unknown address must mint nothing")
        self.assertGreater(after_known, before)

    def test_it_never_borrows_the_gateway_parameter(self):
        """The whole reason these routes exist. Reading the gateway's value
        would send assessment users to the Workflow Manager."""
        import inspect

        source = inspect.getsource(auth_api._reset_base_url)
        self.assertNotIn("api_auth_gateway", source)
