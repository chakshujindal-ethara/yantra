# -*- coding: utf-8 -*-
"""HTTP behaviour for the /api/v1 surface: CORS with credentials, and auth
failures that answer in the API's own envelope.

Both problems have the same root: the Flutter client is a BROWSER app served
from a different origin (a static server on :8100) than Odoo (:7070), and it
authenticates with a session COOKIE - the strictest case the fetch spec has,
and one Odoo does not handle on its own.

WHY A WILDCARD IS NOT ENOUGH. Odoo's ``cors="*"`` routing option emits
``Access-Control-Allow-Origin: *``, which is INVALID on a credentialed request:
the browser refuses the response and the app sees an opaque "Failed to fetch"
while curl sees a perfectly good 200. A credentialed request needs a specific
echoed origin plus ``Access-Control-Allow-Credentials: true``.

THE FAILURE MODE TO KEEP IN MIND THROUGHOUT: every CORS mistake here is
invisible server-side. The request arrives, Odoo answers 200, the BROWSER
discards the response, and the app shows empty screens over a healthy log.

Every override below is gated on the prefixes in CORS_MANAGED_PREFIXES, so the
HTML portal, the backend and the login page keep Odoo's stock behaviour.
"""

import logging
import re

from odoo import SUPERUSER_ID, http, models
from odoo.http import request

_logger = logging.getLogger(__name__)

API_PREFIX = "/api/v1/"

# Upstream's ACL-checked admin media proxies: admin_qimage, admin_qvideo,
# admin_draft_qimage, admin_draft_qvideo. The bank and the review queue link
# straight at these, so a bearer client has to be able to reach them.
ADMIN_MEDIA_PREFIX = "/assessments_be/admin_"

# The candidate-facing media proxies: exam/qimage, exam/qvideo. Scoped by the
# exam token IN the path, so auth="public" - but still fetched CROSS-ORIGIN by
# the Flutter runner, and these routes declare no `cors=` option, so without
# this prefix they carried no CORS headers at all and every candidate stimulus
# was blank.
EXAM_MEDIA_PREFIX = "/assessments_be/exam/"

# Every path whose CORS headers this module owns end to end.
#
# WHY MEDIA BELONGS HERE AND NOT JUST ON /api/v1. Odoo's `cors="*"` routing
# option writes Access-Control-Allow-Origin onto `request.future_response`,
# merged into the finished response with `headers.extend(...)` AFTER
# `_post_dispatch` has run - so `_apply_cors` narrowing the value does not
# REPLACE the wildcard, it precedes it, and the response ships BOTH:
#
#     Access-Control-Allow-Origin: http://localhost:8200
#     Access-Control-Allow-Origin: *
#
# A multi-valued Allow-Origin is a hard CORS failure ("contains multiple values,
# but only one is allowed"), so every question image rendered as an empty plate
# while curl fetched the same URL as a perfectly good PNG. The WSGI wrapper
# below is the only hook that runs after that merge, which is why it, not
# `_apply_cors`, has to cover these paths.
CORS_MANAGED_PREFIXES = (API_PREFIX, ADMIN_MEDIA_PREFIX, EXAM_MEDIA_PREFIX)


def _is_cors_managed(path):
    """True when this module, not Odoo's routing option, owns the CORS headers."""
    return any(path.startswith(prefix) for prefix in CORS_MANAGED_PREFIXES)

# Origins allowed to send credentials. A specific list, never a wildcard.
#
# Localhost AND 127.0.0.1 are both listed because a browser treats them as
# different origins.
#
# DEVELOPMENT ONLY, and gated at runtime by `_localhost_origins` below - never
# unioned into the allow-list unconditionally. A production deployment that
# trusts these is trusting ANY page a signed-in user happens to be serving on
# their own machine, and combined with
# `Access-Control-Allow-Credentials: true` that page could read this API's
# authenticated responses as the user - every candidate, every result. A
# deployment adds its real origins with CORS_ORIGINS_PARAM instead.
#
# EVERY PORT THE FRONT-END REPO SERVES ON HAS TO BE HERE. ethara-assessment-fe's
# Makefile serves one bundle per environment on its own port - 8200 local, 8201
# stage, 8202 prod - so all three can be up at once. 8201 and 8202 were missing,
# which made `make serve-stage` against this backend fail at CORS. That
# Makefile's `test-env-parity` target now greps this set and warns on a port it
# cannot find here.
LOCALHOST_ORIGINS = {
    "http://localhost:8100",
    "http://127.0.0.1:8100",
    "http://localhost:8200",
    "http://127.0.0.1:8200",
    "http://localhost:8201",
    "http://127.0.0.1:8201",
    "http://localhost:8202",
    "http://127.0.0.1:8202",
    "http://localhost:3000",
    "http://127.0.0.1:3000",
    "http://localhost:8080",
    "http://127.0.0.1:8080",
}

# Extra origins, comma-separated, from Odoo's own settings:
#
#     assessments_be_v2.cors_origins = https://assess.example.com
#
# WHY THIS EXISTS. When the Flutter app is served from its own domain, every API
# call is cross-origin, and a hardcoded list means shipping a code change to add
# a domain.
CORS_ORIGINS_PARAM = "assessments_be_v2.cors_origins"

# Opt back in to LOCALHOST_ORIGINS on a server that is not running with
# --dev:
#
#     assessments_be_v2.cors_allow_localhost = 1
#
# WHY A SWITCH AND NOT JUST dev_mode. A developer commonly runs a local Odoo
# WITHOUT --dev (it changes asset handling and reloading), and a shared staging
# box that front-end work points a local Flutter build at is never in dev mode
# either. Without an explicit opt-in the only way to get those working would be
# to add localhost to CORS_ORIGINS_PARAM on the very deployments where that
# entry is most dangerous to forget.
#
# IT IS NO LONGER NEEDED FOR THE ORDINARY LOCAL CASE - see
# `_LOCAL_BACKEND_CACHE`. It remains the answer for the SECOND case above: a
# shared box whose own `web.base.url` is a real hostname, being pointed at from a
# developer's browser.
CORS_LOCALHOST_PARAM = "assessments_be_v2.cors_allow_localhost"

# Last known value of those parameters. The WSGI wrapper below runs before Odoo
# builds a request, so it cannot query the database itself; `_refresh_cors_cache`
# updates these from the dispatch path, where an env DOES exist. Module-level
# because the wrapper is patched onto the class once, for the whole process.
_CONFIGURED_ORIGINS_CACHE = set()
# Defaults to False, the SAFE value: a cache that has never been filled must
# refuse localhost, not admit it. Dev mode is answered separately by
# `_dev_mode`, which needs no database at all.
_ALLOW_LOCALHOST_CACHE = False

# The Flutter client origin deployed alongside this backend, derived from
# `web.base.url` by `services/app_origins.py`.
#
# WHY IT IS TRUSTED WITHOUT BEING CONFIGURED. Not a wildcard and not guessed:
# one specific origin from a table of environments this addon is deployed in,
# and reaching it requires already controlling this server's own `web.base.url`.
# The alternative was every new deployment starting out broken with empty
# screens as the only symptom.
#
# Cached at module level for the same reason as the two above.
_PAIRED_APP_ORIGIN_CACHE = ""

# True when THIS server's own `web.base.url` is a developer's localhost.
#
# WHY THIS EXISTS. `cors_allow_localhost` had to be set by hand on every cloned
# database, and forgetting it fails in the least helpful way available: the
# preflight is refused, the browser discards the response, the Odoo log looks
# perfectly healthy, and the client shows an empty screen with a CORS error
# buried in the console. That is a setting nobody remembers until they have lost
# twenty minutes to it.
#
# WHY IT IS SAFE TO DERIVE. This is not "the caller is localhost" - that would be
# trusting whatever a browser claims. It is "the SERVER I am is localhost", read
# from a parameter only an administrator of this database can write. Production
# and stage answer `https://projects.ethara.ai` and
# `https://projects-stage.ethara.ai`, so this is False there and the allow-list
# is exactly what it was.
#
# Defaults to False for the same reason as `_ALLOW_LOCALHOST_CACHE`: a cache that
# has never been filled must refuse.
_LOCAL_BACKEND_CACHE = False


def _truthy(value):
    """Interpret a system-parameter value as a flag.

    Odoo stores every parameter as text, so the value is "0", "False" or "" as
    often as it is "1" - and all three are truthy as Python strings. Reading
    this one with a bare bool() would make DISABLING it impossible.
    """
    return str(value or "").strip().lower() in ("1", "true", "yes", "on", "t")


def _dev_mode():
    """True when this server was started with --dev.

    Imported as `from odoo.tools import config` because `import odoo` alone does
    not bind the `tools` submodule, so `odoo.tools.config` raises
    AttributeError. See `_refresh_cors_cache`.
    """
    try:
        from odoo.tools import config as odoo_config
        return bool(odoo_config.get("dev_mode"))
    except Exception:
        # A CORS lookup must never take the API down; assume production.
        return False


def _localhost_origins():
    """The localhost defaults, but only where they are meant to be trusted.

    An empty set on production is the point: see LOCALHOST_ORIGINS.

    THREE WAYS IN, and the third is what makes a cloned database work with no
    configuration: `--dev`, the explicit parameter, or this server's own
    `web.base.url` being localhost. All three are statements about the SERVER,
    never about the caller - none of them reads the request's Origin - so a
    deployment on a real hostname admits nothing extra however it is called.
    """
    if _dev_mode() or _ALLOW_LOCALHOST_CACHE or _LOCAL_BACKEND_CACHE:
        return LOCALHOST_ORIGINS
    return set()


def _is_api_request():
    """True when the request in flight targets the JSON API.

    ADMIN MEDIA COUNTS. `bank_question_detail` and `draft_detail` hand the
    client `/assessments_be/admin_qimage/<id>` URLs, and those routes are
    `auth="user"` - Odoo's stock check looks for a session cookie, finds none on
    a bearer-only client, and answers 303 to the login page. `Image.network`
    follows the redirect, gets HTML, fails to decode, and retries on the next
    rebuild: every image in the question bank and the review queue was broken,
    with the retry loop visible as a flicker.

    Widening the prefix here rather than adding proxy routes keeps ONE way in:
    the same `api.access_token` identity, the same record rules, and the media
    handler itself still enforces `_be_is_staff()` and `check_access` before
    streaming a byte.

    EXAM MEDIA COUNTS TOO, for the CORS half rather than the auth half:
    `_post_dispatch` consults this predicate to attach the credentialed headers.
    """
    if not request or not request.httprequest:
        return False
    return _is_cors_managed(request.httprequest.path or "")


def _configured_origins():
    """Origins from the system parameter. Also refreshes the localhost flag.

    Read per request rather than cached at import: an operator adding a domain
    in Settings must not have to restart Odoo.

    Never fatal. This runs for EVERY API request, so a database mid-upgrade must
    degrade to the defaults rather than take the API down.
    """
    global _CONFIGURED_ORIGINS_CACHE, _ALLOW_LOCALHOST_CACHE
    try:
        icp = request.env["ir.config_parameter"].sudo()
        raw = icp.get_param(CORS_ORIGINS_PARAM, "") or ""
        # Read on the same trip as the origins: both feed the WSGI wrapper,
        # and refreshing them apart would let a preflight and its request
        # disagree about whether localhost is allowed.
        _ALLOW_LOCALHOST_CACHE = _truthy(
            icp.get_param(CORS_LOCALHOST_PARAM, ""))
    except Exception:
        # Keep the last good value: a transient failure must not narrow the
        # allow-list and start blocking a front end that was working.
        return _CONFIGURED_ORIGINS_CACHE
    parsed = {o.strip().rstrip("/") for o in raw.split(",") if o.strip()}
    # Feed the WSGI-level wrapper, which has no env of its own.
    _CONFIGURED_ORIGINS_CACHE = parsed
    # DELIBERATELY AFTER the assignment above, and in its own try. Folded into
    # the block above, a failure here would take that `except`'s early `return`
    # and DROP the origins an operator configured by hand. The derived origin is
    # a convenience; the configured list is the contract.
    _refresh_paired_origin(icp)
    return parsed


def _refresh_paired_origin(icp):
    """Re-derive what `web.base.url` says about this deployment. Never raises.

    Two facts from one read: which client origin is paired with this backend, and
    whether this backend is a developer's own machine. They come from the same
    parameter on the same trip so a preflight and its request cannot disagree
    about either - the reason `_ALLOW_LOCALHOST_CACHE` is read alongside the
    origins rather than separately.
    """
    global _PAIRED_APP_ORIGIN_CACHE, _LOCAL_BACKEND_CACHE
    try:
        # Imported here, not at module level: the addon's `__init__` loads
        # `models` BEFORE `services` on purpose (the ir.http override has to be
        # registered before any route dispatches), so a module-level import
        # would invert that order.
        from ..services import app_origins
        base = icp.get_param("web.base.url", "")
        _PAIRED_APP_ORIGIN_CACHE = app_origins.paired_app_origin(base)
        _LOCAL_BACKEND_CACHE = app_origins.is_local_backend(base)
    except Exception:
        # Keep the last good value, for the same reason as above.
        _logger.debug("Could not derive the paired app origin", exc_info=True)


def _paired_origins():
    """The derived client origin, as a set so it unions cleanly.

    Empty on any deployment whose host is in no table, which keeps this from
    widening the allow-list anywhere it was not designed to.
    """
    paired = (_PAIRED_APP_ORIGIN_CACHE or "").rstrip("/")
    return {paired} if paired else set()


def _allowed_origins():
    """Every origin this deployment accepts credentialed requests from."""
    # _configured_origins() first: it is what refreshes BOTH the localhost flag
    # and the derived pairing that the next two calls read.
    configured = _configured_origins()
    return _localhost_origins() | _paired_origins() | configured


def _allowed_origin():
    """The request's Origin, if we are willing to accept credentials from it."""
    if not request or not request.httprequest:
        return None
    origin = request.httprequest.headers.get("Origin")
    if not origin:
        return None
    # Trailing slash stripped on both sides: a browser never sends one, but a
    # human configuring "https://app.example.com/" would otherwise produce a
    # list entry that can never match.
    return origin if origin.rstrip("/") in _allowed_origins() else None


def _apply_cors(headers, origin):
    """Set the credentialed CORS headers on a response.

    Remove-then-set rather than append, for the multi-valued Allow-Origin reason
    spelled out at CORS_MANAGED_PREFIXES.
    """
    for name in (
        "Access-Control-Allow-Origin",
        "Access-Control-Allow-Credentials",
        "Access-Control-Allow-Methods",
        "Access-Control-Allow-Headers",
        "Access-Control-Expose-Headers",
        "Vary",
    ):
        try:
            headers.remove(name)
        except KeyError:
            pass

    headers["Access-Control-Allow-Origin"] = origin
    headers["Access-Control-Allow-Credentials"] = "true"
    headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    headers["Access-Control-Allow-Headers"] = (
        "Origin, X-Requested-With, Content-Type, Accept, Authorization, Range"
    )
    # A cross-origin page reads only the simple headers unless named here; the
    # client's retry ladder needs Retry-After on a 429 or 503.
    headers["Access-Control-Expose-Headers"] = "Retry-After"
    # The response is origin-specific now; without Vary a shared cache can hand
    # one origin's response to another.
    headers["Vary"] = "Origin"


def _refresh_cors_cache(environ):
    """Reload the configured origins straight from the database.

    WHY NOT rely on the dispatch path to keep the cache warm: a PREFLIGHT never
    reaches dispatch. Odoo aborts OPTIONS early, so `_configured_origins` is
    never called for exactly the request that decides whether a browser will
    talk to us.

    Cheap enough to do here: one indexed read on `ir_config_parameter`, only for
    managed-prefix requests carrying an Origin that is not already known.
    """
    global _CONFIGURED_ORIGINS_CACHE, _ALLOW_LOCALHOST_CACHE
    global _PAIRED_APP_ORIGIN_CACHE
    try:
        # Imported explicitly, NOT as `odoo.tools.config`: `import odoo` alone
        # does not bind the `tools` submodule, so the dotted form raises
        # AttributeError - which this function used to swallow, leaving the cache
        # permanently cold and the setting looking dead.
        from odoo.tools import config as odoo_config
        from odoo.modules.registry import Registry
        dbname = odoo_config.get("db_name")
        # `db_name` is a LIST on Odoo 19 (it accepts a comma-separated set),
        # and `Registry(...)` needs a plain string - passing the list raises
        # "unhashable type: 'list'" deep inside the registry's LRU.
        if isinstance(dbname, (list, tuple)):
            dbname = dbname[0] if len(dbname) == 1 else None
        if not dbname:
            # Either no database is pinned, or several are. Multi-database
            # deployments resolve the name from the host; not supported here on
            # purpose, because guessing wrong would silently apply one tenant's
            # allow-list to another.
            return
        registry = Registry(dbname)
        with registry.cursor() as cr:
            # All three keys in one statement: separate round trips are separate
            # chances to fail halfway and leave the flag disagreeing with the
            # origin list. `web.base.url` is in the list because the derived
            # client origin has to be known on the PREFLIGHT too - deriving it
            # only on dispatch would allow the request and refuse the preflight
            # in front of it, which a browser reports as never allowed at all.
            cr.execute(
                "SELECT key, value FROM ir_config_parameter WHERE key IN %s",
                ((CORS_ORIGINS_PARAM, CORS_LOCALHOST_PARAM,
                  "web.base.url"),))
            values = dict(cr.fetchall())
        raw = values.get(CORS_ORIGINS_PARAM) or ""
        _CONFIGURED_ORIGINS_CACHE = {
            o.strip().rstrip("/") for o in raw.split(",") if o.strip()}
        _ALLOW_LOCALHOST_CACHE = _truthy(values.get(CORS_LOCALHOST_PARAM))
        # Its own try, for the reason in `_configured_origins`. Here that also
        # means not falling into the outer `except`, which would log a failure to
        # refresh the whole cache when the configured half succeeded.
        try:
            from ..services import app_origins
            _PAIRED_APP_ORIGIN_CACHE = app_origins.paired_app_origin(
                values.get("web.base.url") or "")
        except Exception:
            _logger.debug("Could not derive the paired app origin",
                          exc_info=True)
    except Exception:
        # Never let a CORS lookup break a request. The cache keeps its last
        # good value, so a front end that was working stays working.
        _logger.warning(
            "Could not refresh the CORS origin cache; "
            "a newly configured origin will be refused until restart",
            exc_info=True)


def _install_cors_middleware():
    """Wrap Odoo's WSGI entry point so it owns the FINAL CORS headers.

    Everything inside Odoo has already had its turn by this point, which is the
    whole reason this exists. Three earlier attempts failed:

      * ``_post_dispatch`` never sees an OPTIONS request. Odoo's
        ``Dispatcher.pre_dispatch`` sets its wildcard and then ``abort()``s the
        preflight, so dispatch ends before that hook.
      * ``ir.http._pre_dispatch`` DOES run on a preflight, but Odoo's own
        ``set_header('Access-Control-Allow-Origin', cors)`` executes right
        after it returns and overwrites whatever was set.
      * Replacing ``odoo.http.root`` is too late: ``service/server.py`` reads
        that attribute when it CONSTRUCTS the server, which happens before
        addons are imported, so the server keeps a reference to the original.

    Patching ``Application.__call__`` on the CLASS reaches the instance the
    server already holds. It rewrites the header list on the way out, so the
    value Odoo wrote is replaced rather than competed with. Scoped to /api/v1
    and to an allow-listed origin; every other route and origin is untouched.
    """
    from odoo.http import Application

    if getattr(Application, "_etp_cors_wrapped", False):
        return

    original_call = Application.__call__

    def __call__(self, environ, start_response):
        path = environ.get("PATH_INFO", "") or ""
        origin = environ.get("HTTP_ORIGIN")

        # Every other route keeps Odoo's stock behaviour. See
        # CORS_MANAGED_PREFIXES for why the media proxies cannot be left to the
        # routing option's `cors="*"`.
        if not (_is_cors_managed(path) and origin):
            return original_call(self, environ, start_response)

        # Read from the caches, not `request.env`: this runs at WSGI level,
        # before Odoo has built a request or bound a registry. Primed by
        # `IrHttp._register_hook` and refreshed on each dispatch.
        allowed = (_localhost_origins() | _paired_origins()
                   | _CONFIGURED_ORIGINS_CACHE)
        is_allowed = origin.rstrip("/") in allowed
        if not is_allowed:
            # Re-read before refusing: the origin may have been added in
            # Settings since this process last looked, or this may be the
            # process's first managed request, in which case the derived pairing
            # has not been read yet either.
            _refresh_cors_cache(environ)
            allowed = (_localhost_origins() | _paired_origins()
                       | _CONFIGURED_ORIGINS_CACHE)
            is_allowed = origin.rstrip("/") in allowed

        def _start_response(status, headers, exc_info=None):
            # Drop every CORS header Odoo produced, then state ours once.
            # Appending instead ships two Allow-Origin values and the browser
            # honours the wildcard - the exact failure this fixes.
            kept = [
                (k, v) for (k, v) in headers
                if k.lower() not in _CORS_HEADER_NAMES
            ]
            if not is_allowed:
                # An unlisted origin gets NO CORS headers, so the browser
                # refuses the response. Odoo's stock handler answers a preflight
                # with `Allow-Origin: *` instead - not a data leak today (the
                # spec forbids credentials to a wildcard, and these routes 401
                # without a token), but a real hole the day any managed route is
                # made public.
                kept.append(("Vary", "Origin"))
                return start_response(status, kept, exc_info)
            kept.extend([
                ("Access-Control-Allow-Origin", origin),
                ("Access-Control-Allow-Credentials", "true"),
                ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
                (
                    "Access-Control-Allow-Headers",
                    "Origin, X-Requested-With, Content-Type, Accept, "
                    "Authorization, Range",
                ),
                # The only layer that sees the pool-full 503 (load_shed.py).
                ("Access-Control-Expose-Headers", "Retry-After"),
                # Vary: Origin - see `_apply_cors`.
                ("Vary", "Origin"),
            ])
            return start_response(status, kept, exc_info)

        return original_call(self, environ, _start_response)

    Application.__call__ = __call__
    # Guards against a module reload stacking a second rewrite on this one.
    Application._etp_cors_wrapped = True
    _logger.info(
        "ETP: credentialed CORS middleware installed for %s",
        ", ".join(CORS_MANAGED_PREFIXES))


_CORS_HEADER_NAMES = {
    "access-control-allow-origin",
    "access-control-allow-credentials",
    "access-control-allow-methods",
    "access-control-allow-headers",
    "access-control-expose-headers",
    "vary",
}


_install_cors_middleware()


# ── keep exam tokens out of the access log ────────────────────────────────

#: The path segment right after these prefixes is a bearer-style secret.
#: `qimage`/`qvideo` are listed under BOTH media prefixes: the token sits one
#: segment further along there, and `[A-Za-z0-9._~-]{8,}` cannot cross a `/`,
#: so without naming them the 6-character `qimage` fails the length test and
#: the token behind it is never reached.
_TOKEN_IN_PATH = re.compile(
    r"(/(?:(?:assessments_be/exam|pro_assessment)/(?:qimage|qvideo)"
    r"|exam|pro_assessment)/)"
    r"[A-Za-z0-9._~-]{8,}")

#: The cheap substring test that runs in front of the pattern. IT HAS TO COVER
#: EVERY PREFIX THE PATTERN DOES, and it did not: the test was the literal
#: "/exam", and "/pro_assessment/" does not contain it, so that whole branch of
#: the pattern was unreachable and every token on the legacy portal routes
#: (`legacy_redirects.py`, seven of them, all `auth="public"`) went to the
#: access log in clear. Kept beside the pattern so the two cannot drift again.
_TOKEN_PATH_HINTS = ("/exam", "/pro_assessment")


def _may_hold_token(text):
    return any(hint in text for hint in _TOKEN_PATH_HINTS)


class _RedactExamTokens(logging.Filter):
    """Rewrite exam tokens out of a log record before it is emitted.

    AN EXAM TOKEN IS A CREDENTIAL, not an identifier: whoever holds it can sit
    that candidate's paper, with no password. Werkzeug's access log writes the
    full request line, so every media fetch during an exam put a live
    credential into the log aggregator - one line per image, per question, per
    candidate. This addon's own 404 logger was deliberately written so it could
    not receive a token; the access log underneath it was writing them anyway.

    FILTERING RATHER THAN SILENCING. The access log is the only per-request
    record there is, and dropping it to protect one field would cost more than
    it saves. The path shape is preserved, so a URL stays recognisable.

    Never raises. A logging filter that throws takes the log line with it, and
    a redaction bug must not become an outage.
    """

    def filter(self, record):
        try:
            # A CHEAP SUBSTRING TEST BEFORE THE REGEX, on both paths. This
            # filter runs once per HTTP REQUEST - every asset, every poll, every
            # health check - and almost none of them are exam media. Running the
            # pattern unconditionally put a regex on the hot path of the whole
            # server to catch a case that is a rounding error of the traffic.
            # `in` is a C-level scan and short-circuits the overwhelming
            # majority before the pattern is ever touched.
            if record.args:
                args = (record.args if isinstance(record.args, tuple)
                        else (record.args,))
                if any(isinstance(a, str) and _may_hold_token(a)
                       for a in args):
                    record.args = tuple(
                        _TOKEN_IN_PATH.sub(r"\1<redacted>", a)
                        if isinstance(a, str) and _may_hold_token(a) else a
                        for a in args)
            if isinstance(record.msg, str) and _may_hold_token(record.msg):
                record.msg = _TOKEN_IN_PATH.sub(r"\1<redacted>", record.msg)
        except Exception:  # noqa: BLE001
            pass
        return True


def _install_token_redaction():
    logger = logging.getLogger("werkzeug")
    if getattr(logger, "_etp_token_redaction", False):
        return
    logger.addFilter(_RedactExamTokens())
    logger._etp_token_redaction = True
    _logger.info("ETP: exam tokens redacted from the werkzeug access log")


_install_token_redaction()


def _installed_lang(env, code):
    """`code` if it is installed, else its closest installed variant, else
    `en_US`. Falsy passes through: an empty language is valid, a bogus one is
    not.

    `_get_data` is the lookup `env.lang` itself validates with, so asking it
    cannot raise the error this exists to avoid.
    """
    if not code or code == "en_US":
        return code
    Lang = env["res.lang"]
    if Lang._get_data(code=code).code:
        return code
    prefix = code.partition("_")[0] + "_"
    return next((c for c, _name in Lang.get_installed()
                 if c.startswith(prefix)), "en_US")


class IrHttp(models.AbstractModel):
    _inherit = "ir.http"

    def _register_hook(self):
        """Prime the CORS cache as soon as the registry is built.

        Without this the FIRST cross-origin request from a configured domain
        arrives before any dispatch has populated the cache, so its preflight is
        refused and the app looks broken until something else warms it.
        """
        res = super()._register_hook()
        global _CONFIGURED_ORIGINS_CACHE, _ALLOW_LOCALHOST_CACHE
        try:
            icp = self.env["ir.config_parameter"].sudo()
            raw = icp.get_param(CORS_ORIGINS_PARAM, "") or ""
            _CONFIGURED_ORIGINS_CACHE = {
                o.strip().rstrip("/") for o in raw.split(",") if o.strip()}
            _ALLOW_LOCALHOST_CACHE = _truthy(
                icp.get_param(CORS_LOCALHOST_PARAM, ""))
            # Primed here too, so the client's very first preflight after a
            # restart is answered rather than refused.
            _refresh_paired_origin(icp)
        except Exception:
            # Never block a registry load over a CORS nicety.
            _logger.debug("Could not prime the CORS origin cache", exc_info=True)
        return res

    @classmethod
    def _auth_method_user(cls):
        """Let an api_auth_gateway bearer token satisfy ``auth="user"``.

        WHY: the Ethara portal signs in ONCE, at /api/v1/auth_token, and then
        holds a BEARER token - no Odoo session cookie. Odoo's stock check only
        looks at the session, so every assessment call from the signed-in portal
        answered 401. This runs BEFORE the stock check because that check
        raises; there is no later hook to recover in.

        Identity comes from ``api.access_token``, the model the gateway issues
        and the same one workflow_management resolves, so all three modules agree
        on who someone is and one sign-out revokes everywhere. ``update_env``
        then runs the request AS that user, so record rules scope the rows
        exactly as they do for a cookie session.

        This widens how a caller PROVES identity, never what they may do: the
        group checks on each route still decide that.
        """
        if _is_api_request() and request.env.uid in [None] + cls._get_public_users():
            cls._adopt_gateway_token()
        return super()._auth_method_user()

    @classmethod
    def _auth_method_public(cls):
        """Adopt a bearer token on ``auth="public"`` routes too.

        WHY: a public route means "no login REQUIRED", not "no login POSSIBLE".
        `/api/v1/exam/<token>/state` is public so an unauthenticated visitor gets
        a `login_required` gate instead of a 401 - but it then branches on
        `request.env.user`, and without this the bearer was never resolved, so a
        properly signed-in candidate was reported public and could never sit the
        exam. The stock `_auth_method_user` hook does not run for a public route,
        so there is no other place to recover the identity.

        Still only about PROVING identity: a public route stays reachable with no
        token, and authorisation remains the route's own
        (`may_view_attempt`, the token scope, the group checks).

        Order matters: the stock method installs the PUBLIC user whenever
        ``uid`` is None, so it has to run FIRST and the adopted identity has to
        replace it afterwards. Adopting before the call had the bearer resolve
        correctly and then get overwritten by the public user one line later.
        """
        result = super()._auth_method_public()
        if _is_api_request() and request.env.uid in [None] + cls._get_public_users():
            cls._adopt_gateway_token()
        return result

    @classmethod
    def _auth_method_none(cls):
        """Fix the language on the gateway's `auth="none"` sign-in routes.

        `/api/v1/auth_token`, `refresh_token`, `forgot_password` and
        `reset_password` resolve no identity, so no adopter runs for them and a
        no-cookie request carries `Accept-Language` verbatim (`en_GB`) into
        `_authenticate`, whose group-cache rebuild orders by a TRANSLATED
        field. The route reports any exception as "Login failed", which sends a
        candidate with the right password to Forgot Password.

        Core's `_pre_dispatch` normalises the language as well, but only AFTER
        `_authenticate`. `_is_api_request()` keeps this off non-API routes.
        """
        super()._auth_method_none()
        if _is_api_request():
            cls._use_installed_lang()

    @classmethod
    def _use_installed_lang(cls):
        """Replace an uninstalled request language with one this server has.

        Call it before any ORM read. With no session cookie Odoo takes the
        language from `Accept-Language` unchecked, so an en-GB browser arrives
        as `en_GB` on a server without it, and the first read ordered by a
        translated field raises "Invalid language code". Never raises: a
        request must not die over a language. The time zone is left alone.
        """
        try:
            lang = request.env.context.get("lang")
            # `auth="none"` leaves `uid` as None, and the installed-language
            # lookup is a `sudo()` read that wants a user. Only the LOOKUP is
            # elevated; the request's own environment is untouched but for
            # its language.
            env = request.env if request.env.uid else request.env(
                user=SUPERUSER_ID)
            usable = _installed_lang(env, lang)
            if usable != lang:
                request.update_env(
                    context=dict(request.env.context, lang=usable))
        except Exception:  # noqa: BLE001 - same rule as the adoption below
            _logger.exception("ETP: could not validate the request language")

    @classmethod
    def _adopt_gateway_token(cls):
        """Resolve a bearer token to a user, quietly doing nothing if it fails.

        Silent on failure by design: this is one of two ways to authenticate, so
        an absent, expired or unknown token must leave the request anonymous and
        let the caller's own session (or the 401 that follows) decide. Raising
        would turn "no token" into a server error for every cookie caller.

        The language is fixed first (`_use_installed_lang`): `_is_public()`
        below rebuilds the group cache, a read ordered by a translated field.
        It runs before the token check so a signed-out caller is covered too.
        """
        cls._use_installed_lang()

        headers = request.httprequest.headers
        raw = ""
        # Werkzeug drops header names containing an underscore, so the hyphen
        # spelling is the one that survives the trip. Every form
        # workflow_management accepts, so a client does not authenticate
        # differently depending on which module owns the endpoint.
        for name in ("access-token", "access_token", "x-access-token"):
            value = headers.get(name)
            if value:
                raw = value.strip()
                break
        if not raw:
            authorization = headers.get("Authorization") or ""
            if authorization[:7].lower() == "bearer ":
                raw = authorization[7:].strip()
        if not raw:
            return

        try:
            if "api.access_token" not in request.env:
                return  # api_auth_gateway is not installed: cookie-only.
            record = request.env["api.access_token"].sudo().search(
                [("access_token", "=", raw)], order="id desc", limit=1,
            )
            if not record or record.has_expired() or not record.user_id:
                return
            user = record.user_id
            if not user.active or user._is_public():
                return
            # The person's own language from here on, as a cookie session
            # would have it - guarded the same way, in case theirs has since
            # been uninstalled.
            lang = (_installed_lang(request.env, user.lang)
                    or request.env.context.get("lang"))
            request.update_env(
                user=user.id, context=dict(request.env.context, lang=lang))
        except Exception:  # noqa: BLE001 - never break the request over this
            _logger.exception("ETP: could not resolve a gateway access token")

    @classmethod
    def _post_dispatch(cls, response):
        """Attach credentialed CORS headers to every real API response."""
        origin = _allowed_origin()
        if _is_api_request() and origin and response is not None:
            headers = getattr(response, "headers", None)
            if headers is not None:
                _apply_cors(headers, origin)
        return super()._post_dispatch(response)

    @classmethod
    def _handle_error(cls, exception):
        """Answer auth failures in the API envelope, with CORS attached.

        An auth failure is raised by the DISPATCHER, before any controller method
        runs, so the ``@api_endpoint`` decorator never sees it. Left alone Odoo
        returns its generic error body, which leaks a full traceback to an
        unauthenticated caller and has none of the ``{"ok": false, "code": ...}``
        shape the client branches on. It also arrives with no CORS headers, which
        is why they are applied here and not only in `_post_dispatch`.
        """
        if _is_api_request() and isinstance(
            exception, http.SessionExpiredException
        ):
            # 401, not 403: the caller is UNAUTHENTICATED. 401 tells a client to
            # obtain credentials; 403 says "you may never", which sends the app
            # down the wrong branch on a merely expired cookie.
            response = request.make_json_response(
                {
                    "ok": False,
                    "code": "session_expired",
                    "message": "Your session has expired. Sign in again.",
                },
                status=401,
            )
            origin = _allowed_origin()
            if origin:
                _apply_cors(response.headers, origin)
            return response

        return super()._handle_error(exception)
