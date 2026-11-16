# -*- coding: utf-8 -*-
"""Session lifecycle for the Flutter client.

Exam media is streamed by this addon's own token-scoped routes,
`/assessments_be/exam/qimage` and `qvideo` (controllers/exam_media.py). They are
`auth="public"` and scoped by the exam token in the path, because a browser
issues `<img>` and `<video>` requests itself with no Authorization header - so
the client's bearer never reaches them and does not need to. The session cookie
is still accepted on the JSON routes.

THAT PARAGRAPH DESCRIBES THE FALLBACK, NOT THE NORMAL PATH, and is left in
place because the routes below still implement it. In practice the Flutter
client signs in at POST /api/v1/auth_token (`api_auth_gateway`, a hard
dependency since) and holds a BEARER token; `/api/v1/auth/session` is what it
falls back to on a 404, and it cannot work from a browser at all, because
reading `set-cookie` and setting a `Cookie` request header are both forbidden
to JS. `models/ir_http.py` resolves the bearer into an identity for every
`auth="user"` route here. Both credentials therefore reach these handlers, and
`/api/v1/auth/password` is the one route that has to tell them apart - see its
docstring.
"""
import logging
import re
import time
from datetime import timedelta

from odoo import fields, http
from odoo.exceptions import AccessDenied
from odoo.http import request

from . import serializers as S
from .common import (
    API_METHODS, API_TYPE, api_endpoint, arg, fail, ok, resolve_applicant,
    str_arg,
)

_logger = logging.getLogger(__name__)

# The header spellings a bearer can arrive under. Kept identical to
# `IrHttp._adopt_gateway_token`, which is what actually resolves them into an
# identity - if the two lists drift, a caller authenticates successfully and
# then gets told it did not.
BEARER_HEADERS = ("access-token", "access_token", "x-access-token")

# Floor on a new password. Deliberately a FLOOR and not a policy: if the
# deployment installs `auth_password_policy`, its own (possibly stricter) rule
# runs on the write below and its refusal reaches the client as a `rejected`
# 422 carrying the policy's own wording, which is more useful than anything
# restated here. The routes check `password_policy()['min_length']`, which is
# never below this.
MIN_PASSWORD_LEN = 8

# The character classes a password can be made to contain, keyed as the client
# reads them, each with a probe character that belongs to that class alone.
_PASSWORD_CLASSES = (("upper", "A"), ("lower", "a"), ("digit", "7"),
                     ("special", "!"))

# Mirrors `api_auth_gateway`'s own token lifetime (100 hours), so a token
# minted here expires on the same schedule as one minted at sign-in.
TOKEN_TTL_SECONDS = 360000

# THE SAME SENTENCE WHETHER OR NOT THE ACCOUNT EXISTS. Any wording that varies
# turns this route into an account-existence oracle, so it is a constant rather
# than a string built at the call site.
RESET_SENT_MESSAGE = (
    "If an account exists with this email, a password reset link has been "
    "sent."
)
RESET_DONE_MESSAGE = (
    "Password has been reset. Sign in with your new password."
)

# Where the emailed link points.
#
#     assessments_be_v2.password_reset_url = https://assessment.example.com/reset-password
#
# A PARAMETER OF OUR OWN, and the reason these routes exist at all.
# `api_auth_gateway` has the identical flow, but its
# `api_auth_gateway.password_reset_url` is a single global value shared by
# every app on this database - setting it to the assessment client would send
# Workflow Manager users here, and leaving it alone would send assessment users
# there. Falling back to `app_origins.client_app_origin` keeps a fresh install
# working without a manual step: that resolver already answers where the
# candidate app lives, and the reset page is served by the same app.
RESET_URL_PARAM = "assessments_be_v2.password_reset_url"

# HYPHEN, AND NOT `/web/reset_password`. This is the FLUTTER CLIENT's page -
# `resetTokenFrom` in the front-end repo's `lib/deep_link.dart` reads it, and
# `main.dart` hands the token to the reset form at startup. Odoo's own
# `auth_signup` flow is a different path (`/web/reset_password`) on a different
# host, and nothing on the Odoo host answers this one.
#
# Worth stating because getting it backwards is what produced a live 404: see
# `_reset_base_url` below.
RESET_PATH = "/reset-password"

# Rate limiting. `api_auth_gateway`'s equivalent has none, and the route is
# `auth="public"`: every call for a real login mints a token and sends an SMTP
# message, so an unthrottled one is a mail-bomb aimed at whoever's address is
# supplied and a free token-churn against our own database.
#
# IN PROCESS, DELIBERATELY. A shared counter would need a table and a vacuum
# cron for a defence whose whole job is to make abuse tedious. With several
# workers the effective allowance is per worker, which is still a hard ceiling
# and still orders of magnitude below what an unthrottled route permits.
RESET_MAX_PER_WINDOW = 3
RESET_WINDOW_SECONDS = 900
_RESET_ATTEMPTS = {}


def password_policy(env):
    """The rules a new password is checked against, for a form to show before
    it submits: {"min_length": int, "require": [subset of _PASSWORD_CLASSES]}.

    `min_length` is the highest floor any layer enforces: MIN_PASSWORD_LEN,
    `auth_password_policy.minlength`, and etp_security's own when installed.
    `require` is etp_security's character rules, only when it is installed.
    Its code is imported here, at call time, never with this module.
    """
    try:
        configured = int(env["ir.config_parameter"].sudo().get_param(
            "auth_password_policy.minlength") or 0)
    except (TypeError, ValueError):
        configured = 0
    floors = [MIN_PASSWORD_LEN, configured]
    require = []
    if env["ir.module.module"].sudo().search_count([
            ("name", "=", "etp_security"),
            ("state", "in", ("installed", "to upgrade"))]):
        from odoo.addons.etp_security.models import res_users as etp_security
        floors.append(etp_security._PASSWORD_MIN_LENGTH)
        require = [key for key, probe in _PASSWORD_CLASSES
                   if any(rule.search(probe)
                          for rule, _label in etp_security._PASSWORD_RULES)]
    return {"min_length": max(floors), "require": require}


def _looks_like_email(value):
    """Deliberately loose: this is a shape check, not a deliverability one.

    The address is looked up as a `login` immediately afterwards, so anything
    that is not a real account goes no further whatever this thinks of it. A
    strict pattern here would only reject valid addresses.
    """
    text = (value or "").strip()
    return bool(re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", text))


def _reset_base_url(env):
    """Where a password-reset email points.

    `RESET_URL_PARAM` first, then `app_origins.client_app_origin` - the one
    resolver that also answers the candidate's exam link and front door, so the
    two cannot disagree about where the app lives.

    THIS USED TO STOP AT `app_base_url`, which reads the configured parameter
    and nothing else, and then fell through to `web.base.url`. On production,
    where `candidate_app_base_url` has never been set, that mailed
    `https://projects.ethara.ai/reset-password` - the ODOO host. Nothing there
    answers that path: `/reset-password` is the Flutter client's own page
    (`lib/deep_link.dart`), while Odoo's reset flow is `/web/reset_password`.
    Every reset link sent from an unconfigured database was a 404, and the
    failure was invisible server-side because the mail sent perfectly.

    The reset page is served by the SAME app as the candidate front door, so
    resolving it the same way is not a convenience - it is the invariant.
    """
    icp = env["ir.config_parameter"].sudo()
    configured = (icp.get_param(RESET_URL_PARAM, "") or "").strip()
    if configured:
        return configured.rstrip("/")
    from ...services import app_origins
    return "%s%s" % (app_origins.client_app_origin(env), RESET_PATH)


def _reset_allowed(email):
    """Whether this address may request another link right now.

    Called BEFORE the account lookup, so the limiter cannot be probed for the
    existence of an account either - the answer is the same for an address
    that has one and an address that does not.
    """
    now = time.monotonic()
    cutoff = now - RESET_WINDOW_SECONDS
    # Sweep on the way past rather than on a timer: the map is only ever
    # touched here, and without this it grows once per distinct address for the
    # life of the worker.
    for key in [k for k, stamps in _RESET_ATTEMPTS.items()
                if not [t for t in stamps if t > cutoff]]:
        _RESET_ATTEMPTS.pop(key, None)

    recent = [t for t in _RESET_ATTEMPTS.get(email, []) if t > cutoff]
    if len(recent) >= RESET_MAX_PER_WINDOW:
        _RESET_ATTEMPTS[email] = recent
        return False
    recent.append(now)
    _RESET_ATTEMPTS[email] = recent
    return True


def _presented_bearer():
    """True when this request authenticated with a token rather than a cookie.

    The two credentials are renewed in completely different ways after a
    password change, and the route has no other way to tell which one it is
    holding: by the time it runs, both have already been resolved to the same
    `request.env.user`.
    """
    headers = request.httprequest.headers
    if any(headers.get(name) for name in BEARER_HEADERS):
        return True
    authorization = headers.get("Authorization") or ""
    return authorization[:7].lower() == "bearer "


def _mint_bearer(user):
    """Issue a fresh `api.access_token` pair for ``user``.

    Written out rather than calling the gateway's own
    `find_one_or_create_token(create=True)`, which is otherwise exactly this:
    that method ends with `self._cr.commit()`, and committing from inside a
    route ends the request's transaction early - it would make the password
    write unrollbackable by anything that failed afterwards and defeat Odoo's
    `retrying` wrapper for the rest of the request.

    Returns ``(None, None)`` when the gateway is absent. It is a hard
    dependency, so that is a partially-loaded registry rather than a supported
    deployment - but a cookie client would still be fine, and answering "no
    token" beats raising.
    """
    if "api.access_token" not in request.env:
        return None, None
    try:
        from odoo.addons.api_auth_gateway.models.access_token import nonce
    except ImportError:                                         # noqa: BLE001
        _logger.warning("api_auth_gateway is unavailable; no token was minted")
        return None, None
    token = request.env["api.access_token"].sudo().create({
        "user_id": user.id,
        "expiry": fields.Datetime.now() + timedelta(seconds=TOKEN_TTL_SECONDS),
        "access_token": nonce(),
        "refresh_token": nonce(),
    })
    return token.access_token, token.refresh_token


def _presented_token():
    """The bearer this request actually arrived with, or ``""``.

    Reads the same spellings `_presented_bearer` tests for, in the same order,
    so "this request holds a token" and "this is the token it holds" can never
    disagree.
    """
    headers = request.httprequest.headers
    for name in BEARER_HEADERS:
        value = (headers.get(name) or "").strip()
        if value:
            return value
    authorization = headers.get("Authorization") or ""
    if authorization[:7].lower() == "bearer ":
        return authorization[7:].strip()
    return ""


def _revoke_bearer():
    """Delete the `api.access_token` this request authenticated with.

    The mirror of `_mint_bearer`, and written out for the same reason: the
    gateway's own helpers commit, and committing from inside a route ends the
    request's transaction early.

    SIGN-OUT USED TO LEAVE THE TOKEN LIVE. The client called the gateway's
    `/api/v1/auth_token_unlink`, which is declared GET-only and reads a custom
    `access_token` header - while the client POSTs and sends
    `Authorization: Bearer`. So the call was a 405, and correcting only the verb
    would have made it a 401. `ApiClient.logout` clears its local state in a
    `finally`, so the failure was invisible: the user was shown a login screen
    while their token stayed valid until it expired.

    Silent on every miss. A caller signing out with a stale or already-revoked
    credential has nothing to act on, and logout is the one route that must not
    refuse - the client has thrown its state away by the time it hears back.
    """
    token = _presented_token()
    if not token:
        return False
    if "api.access_token" not in request.env:
        return False
    row = request.env["api.access_token"].sudo().search(
        [("access_token", "=", token)], limit=1)
    if not row:
        return False
    row.unlink()
    return True


class EtpAssessmentApiAuth(http.Controller):

    @http.route("/api/v1/auth/session", type=API_TYPE, auth="public",
                methods=["POST"], csrf=False, cors="*", save_session=True)
    @api_endpoint
    def auth_session(self, **kw):
        """Log in and return the session plus the caller's portal role.

        Deliberately thin: it delegates to ``request.session.authenticate``,
        the same call /web/session/authenticate makes, so password policy,
        MFA and login rate limiting all behave identically to the web client
        and none of it is reimplemented here.
        """
        login = str_arg("login", max_len=254)
        password = str_arg("password", max_len=1024)
        if not login or not password:
            return fail("missing_credentials",
                        "login and password are required", status=400)
        db = str_arg("db") or request.db
        if not db:
            return fail("no_database", "No database resolved for this host",
                        status=400)
        if not http.db_filter([db]):
            return fail("no_database", "Database not found", status=400)
        # `session.authenticate` matches the login case-sensitively
        # (`_get_login_domain`), so resolve the STORED spelling first or this
        # route refuses a candidate the gateway route would have let in - the
        # same lockout, on the other of this product's two sign-in endpoints.
        # No match falls through with what was typed, so authenticate still
        # produces the one indistinguishable failure and no enumeration oracle.
        needle = login.replace("\\", "\\\\").replace("_", "\\_").replace("%", "\\%")
        stored = request.env["res.users"].sudo().search(
            [("login", "=ilike", needle)], limit=1, order="id desc")
        credential = {"login": stored.login or login, "password": password,
                      "type": "password"}
        try:
            auth_info = request.session.authenticate(request.env, credential)
        except AccessDenied:
            # Never distinguish "no such login" from "bad password": that is a
            # user-enumeration oracle.
            return fail("invalid_credentials",
                        "Wrong login or password", status=401)
        uid = auth_info.get("uid")
        if not uid or uid != request.session.uid:
            # An MFA-enabled account cannot finish here: session.authenticate
            # leaves a PARTIAL session when a second factor is outstanding, and
            # this API has no second-factor step. Send them to the web login
            # rather than hand back a half-authenticated session.
            return fail("mfa_required",
                        "This account needs multi-factor authentication. "
                        "Sign in through the web portal.", status=401)
        request.session.db = db
        request._save_session()
        user = request.env["res.users"].sudo().browse(uid)
        applicant = resolve_applicant(user)
        return ok({
            "session_id": request.session.sid,
            "user": S.session_user(user, applicant),
        })

    @http.route("/api/v1/auth/me", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    def auth_me(self, **kw):
        """Who am I, on the session I am already holding.

        The client calls this on cold start to decide whether its stored
        cookie is still good and which navigation tree to build.
        """
        user = request.env.user
        return ok({"user": S.session_user(user, resolve_applicant(user))})

    @http.route("/api/v1/auth/password", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*", save_session=True)
    @api_endpoint
    def auth_password(self, **kw):
        """Set a new password for the caller's own account.

        WHOSE ACCOUNT: always `request.env.user`'s. The route takes no user id
        and has no way to name anyone else, so there is no path here for one
        candidate to reach another's account, and none for an Evaluator to
        reach a Manager's.

        NO CURRENT PASSWORD IS ASKED FOR. That is a deliberate product
        decision, and it is the one thing worth knowing about this route:
        Odoo's own `res.users.change_password` requires the old password
        specifically "to prevent hijacking an existing user session", and this
        does not. Whoever holds a live session or bearer token can therefore
        take the account over permanently rather than only until the
        credential expires. Requiring it is one argument and one extra field -
        see the ``current_password`` handling below, which already verifies it
        whenever a client chooses to send it.

        THE CALLER IS LOGGED OUT BY THIS WRITE, twice over, which is why the
        response carries fresh credentials:

          * `password` is one of `res.users._get_session_token_fields`, so
            every Odoo session for this user - including the one making this
            request - stops validating the moment the hash changes.
          * `api_auth_gateway` inherits `res.users.write` and unlinks EVERY
            `api.access_token` row for a user whose password is written.

        Both are correct behaviour (a password change should end other
        people's sessions) and both would otherwise strand the caller on the
        next request with a 401 they did nothing to earn. So the credential
        the caller actually presented is re-established, and only that one:
        every other device stays signed out.
        """
        new_password = str_arg("new_password", max_len=1024)
        # Optional on the wire. The UI sends it and a mismatch is refused here
        # as well as in the client, because a client-side-only check is not a
        # check.
        confirm = str_arg("confirm_password", max_len=1024)
        current = str_arg("current_password", max_len=1024)

        if not new_password:
            return fail("missing_password", "Enter a new password", status=400)
        min_length = password_policy(request.env)["min_length"]
        if len(new_password) < min_length:
            return fail(
                "weak_password",
                "Your new password must be at least %d characters"
                % min_length, status=400)
        # `arg` rather than the coerced `str_arg`, so an omitted key and an
        # empty string are distinguishable: only a client that SENT a
        # confirmation has one to check.
        if arg("confirm_password") is not None and confirm != new_password:
            return fail("password_mismatch",
                        "The two passwords do not match", status=400)

        user = request.env.user
        if arg("current_password") is not None:
            # Verified when offered even though it is not required, so a client
            # that does ask for it gets a real check rather than a decorative
            # field.
            try:
                user.sudo()._check_credentials(
                    {"login": user.login, "password": current,
                     "type": "password"}, {"interactive": True})
            except AccessDenied:
                return fail("invalid_credentials",
                            "Your current password is wrong", status=401)

        bearer_call = _presented_bearer()
        login = user.login

        # An explicit write(), not `user.password = ...`: both reach `write`,
        # but only the explicit form makes it obvious that the gateway's
        # `res.users.write` override - the thing that revokes the tokens - is
        # what runs next, and that the mint below therefore has to come after.
        user.sudo().write({"password": new_password})
        _logger.info("Password changed for %r (uid=%s) over /api/v1/auth",
                     login, user.id)

        payload = {
            "changed": True,
            "user": S.session_user(user, resolve_applicant(user)),
        }

        if bearer_call:
            # The caller's token has just been unlinked. Mint its replacement
            # AFTER the write, never before, or this one is revoked too.
            token, refresh = _mint_bearer(user)
            payload["access_token"] = token
            payload["refresh_token"] = refresh
            payload["reauthenticated"] = bool(token)
        else:
            # Cookie caller: re-run the same `session.authenticate` the sign-in
            # route uses, which rotates the session and recomputes the session
            # token against the new hash.
            try:
                request.session.authenticate(
                    request.env,
                    {"login": login, "password": new_password,
                     "type": "password"})
                request._save_session()
                payload["session_id"] = request.session.sid
                payload["reauthenticated"] = True
            except Exception:                                   # noqa: BLE001
                # The password IS changed; only the convenience of staying
                # signed in was lost (an MFA account cannot finish here, for
                # instance). Say so rather than reporting a failure the user
                # would act on by trying again with a password that already
                # works.
                _logger.info(
                    "Password changed for %r but the session could not be "
                    "renewed; the client must sign in again", login,
                    exc_info=True)
                payload["reauthenticated"] = False

        return ok(payload)

    # ── Password reset, by email ─────────────────────────────────────────
    #
    # WHY THIS ADDON OWNS THESE AND `api_auth_gateway` DOES NOT SERVE THEM.
    # The gateway already implements the same flow at /api/v1/forgot_password
    # and /api/v1/reset_password, and the token model below is ITS model,
    # reused rather than forked. What could not be reused is the emailed link:
    # `api_auth_gateway.password_reset_url` is ONE global system parameter
    # shared with every other app on this database, so pointing it at the
    # assessment client would send Workflow Manager users here and vice versa.
    # A parameter of our own is the whole reason these two routes exist.
    #
    # Three other things differ, and each is deliberate:
    #   * the envelope is this addon's `ok()`/`fail()`, so the client parses
    #     these two calls with the code it already has for every other one;
    #   * the password floor is `password_policy()`'s (never below 8), matching
    #     `/api/v1/auth/password` above rather than the gateway's 6 - one
    #     account cannot have two different minimums depending on which screen
    #     set the password;
    #   * requests are rate limited. The gateway's are not, and the route is
    #     `auth="public"`, mints a token and sends an SMTP message on every
    #     call for a real login.

    @http.route("/api/v1/auth/forgot_password", type=API_TYPE, auth="public",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    def auth_forgot_password(self, **kw):
        """Email a password-reset link. Always answers the same way.

        ENUMERATION-SAFE BY CONSTRUCTION: the success payload is identical
        whether or not an account exists, so this route cannot be used to
        discover who holds one. That is also why a send failure is NOT
        reported as such - "we could not email you" is only ever true for an
        address that exists, which leaks exactly what the identical message
        was protecting.
        """
        email = str_arg("email", max_len=254).lower()
        if not _looks_like_email(email):
            return fail("invalid_email", "Enter a valid email address",
                        status=400)

        # Rate limited BEFORE the lookup, so the limiter cannot be probed for
        # the existence of an account either.
        if not _reset_allowed(email):
            return fail(
                "too_many_requests",
                "Too many reset requests. Wait a few minutes and try again.",
                status=429)

        user = request.env["res.users"].sudo().search(
            [("login", "=", email), ("active", "=", True)], limit=1)
        if user:
            self._send_reset_link(user, email)
        else:
            # Logged, never answered. An operator debugging "the email never
            # arrived" needs to know the address matched nothing; the caller
            # must not be told the same thing.
            _logger.info(
                "Password reset requested for %r, which matches no active "
                "account; answering as though it did.", email)
        # INSIDE `data`, not beside it. `ok(data, **extra)` puts extras at the
        # top of the envelope, and the client's `_call` returns `body["data"]`
        # whenever it is a map - so a message passed as an extra is parsed
        # successfully and then thrown away, and the screen has nothing to
        # show.
        return ok({"sent": True, "message": RESET_SENT_MESSAGE})

    def _send_reset_link(self, user, email):
        """Mint a token and mail it. Never raises into the route.

        A failure here must not change the response - see the route's
        docstring - so it is logged loudly and swallowed.
        """
        try:
            token = request.env["api.password_reset_token"].sudo(
            ).generate_reset_token(user.id)
            link = "%s?token=%s" % (_reset_base_url(request.env), token)
            template = request.env.ref(
                "assessments_be_v2.mail_template_password_reset",
                raise_if_not_found=False)
            if not template:
                _logger.error(
                    "PASSWORD RESET: the mail template is missing, so %r was "
                    "sent no link. Reinstall or upgrade assessments_be_v2.",
                    email)
                return
            template.sudo().with_context(
                reset_link=link, user_name=user.name or email,
            ).send_mail(user.id, force_send=True, email_values={
                # FORCE THE RECIPIENT. The link must reach the address that was
                # validated, which is the LOGIN - a partner with a blank or
                # different `email` field would otherwise silently redirect it
                # or drop it. `recipient_ids` is cleared so it cannot also go
                # to the partner's followers.
                "email_to": email,
                "recipient_ids": [(5, 0, 0)],
                "auto_delete": False,
            })
            _logger.info("Password reset link sent to %r (uid=%s)",
                         email, user.id)
        except Exception:  # noqa: BLE001 - the answer is fixed, see above
            _logger.exception(
                "PASSWORD RESET: could not send a link to %r", email)

    @http.route("/api/v1/auth/reset_password", type=API_TYPE, auth="public",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    def auth_reset_password(self, **kw):
        """Set a new password from an emailed token.

        SIGNS THE ACCOUNT OUT EVERYWHERE, on purpose. A reset is what somebody
        does when they believe their password is compromised, so every existing
        credential for that user is revoked: `password` is one of
        `res.users._get_session_token_fields`, and `api_auth_gateway` unlinks
        every `api.access_token` on a password write. The caller signs in
        again with the password they just chose.

        The token is burned first and the siblings with it, so a link cannot be
        replayed and a second link mailed before this one landed cannot be used
        either.
        """
        token = str_arg("token", max_len=256)
        new_password = str_arg("new_password", max_len=1024)
        confirm = str_arg("confirm_password", max_len=1024)

        if not token:
            return fail("missing_token",
                        "This reset link is incomplete. Request a new one.",
                        status=400)
        if not new_password:
            return fail("missing_password", "Enter a new password", status=400)
        min_length = password_policy(request.env)["min_length"]
        if len(new_password) < min_length:
            return fail(
                "weak_password",
                "Your new password must be at least %d characters"
                % min_length, status=400)
        # Same rule as `/api/v1/auth/password`: only a client that SENT a
        # confirmation has one to check.
        if arg("confirm_password") is not None and confirm != new_password:
            return fail("password_mismatch",
                        "The two passwords do not match", status=400)

        Token = request.env["api.password_reset_token"].sudo()
        record = Token.validate_reset_token(token)
        if not record or not record.user_id or not record.user_id.active:
            return fail(
                "invalid_token",
                "This reset link has expired or has already been used. "
                "Request a new one.", status=400)

        user = record.user_id
        login = user.login
        # BURN BEFORE WRITING. If the password write raises, a link that has
        # already been acted on must not still be live.
        record.write({"used": True})
        Token.search([("user_id", "=", user.id),
                      ("used", "=", False)]).write({"used": True})

        user.sudo().write({"password": new_password})
        _logger.info("Password reset completed for %r (uid=%s)",
                     login, user.id)

        # Belt and braces: the gateway's own `res.users.write` override unlinks
        # these, but this route's promise is that a reset ends every session -
        # and that promise must not depend on another addon's implementation.
        if "api.access_token" in request.env:
            request.env["api.access_token"].sudo().search(
                [("user_id", "=", user.id)]).unlink()

        return ok({"reset": True, "message": RESET_DONE_MESSAGE})

    @http.route("/api/v1/auth/password_policy", type=API_TYPE, auth="public",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    def auth_password_policy(self, **kw):
        """The password rules, so the set and reset forms can say them before
        a submit is refused. Public, because the reset form is filled in signed
        out; read-only, and says nothing about any account."""
        return ok(password_policy(request.env))

    @http.route("/api/v1/auth/logout", type=API_TYPE, auth="public",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    def auth_logout(self, **kw):
        """Destroy whichever credential the caller holds.

        Public auth so a stale session can still log out cleanly instead of
        getting a 401 it cannot act on.

        BOTH LANES, because the client cannot be relied on to pick. It signs in
        at the gateway and holds a bearer, or it holds a cookie session, and it
        used to call a different route for each - sending the bearer one to
        `api_auth_gateway`, where the route is GET-only and reads a header the
        client never sends. Revoking here means one endpoint cleans up whatever
        arrived, and the gateway's route is left alone for its own callers.
        """
        revoked = _revoke_bearer()
        request.session.logout(keep_db=True)
        return ok({"logged_out": True, "token_revoked": revoked})
