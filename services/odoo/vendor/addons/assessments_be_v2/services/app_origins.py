"""Which front end belongs to this backend.

THE PAIRING. One Odoo instance serves the Odoo UI on its own origin and the
Flutter assessment client on a DIFFERENT one, and the two are deployed together
per environment:

    backend (web.base.url)          front end (the Flutter client)
    https://projects.ethara.ai      https://assessment.ethara.ai
    https://projects-stage.ethara.ai  https://assessment-stage.ethara.ai
    http://localhost:8069           http://localhost:8200 (and friends)

WHY THIS FILE EXISTS. That pairing was operator knowledge, entered by hand into
`assessments_be_v2.cors_origins` and `assessments_be_v2.candidate_app_base_url`
on every database. Forgetting either does not fail loudly:

  * A missing CORS origin means the request reaches Odoo, Odoo answers
    correctly, and the BROWSER discards the response. The server log looks
    perfectly healthy while the app shows empty screens.
  * A missing `candidate_app_base_url` means every invited candidate is emailed
    a link to the Odoo portal instead of the client that runs the exam.

So the pairing is DERIVED from `web.base.url`, which Odoo already maintains, and
the explicit parameters remain an override for any topology this table does not
describe.

MIRRORS `lib/assessment/data/environment.dart` in the ethara-assessment-fe repo,
which does the same derivation in the opposite direction so the client can find
its backend. Change one and the other has to follow: if they disagree, the
client calls an origin the server will not answer, and it fails at CORS.
"""
from urllib.parse import urlsplit, urlunsplit

# Backend host -> the front-end origin deployed alongside it.
#
# Keyed on the NETLOC (host and port), not the host alone, because the local
# entry has to distinguish Odoo's 8069 from the client's port - they are the
# same machine.
#
# A hostname is case-insensitive, so keys are lowercase and lookups are folded.
PAIRED_APP_ORIGINS = {
    "projects.ethara.ai": "https://assessment.ethara.ai",
    "projects-stage.ethara.ai": "https://assessment-stage.ethara.ai",
}

# The local client, which is served by `tool/serve.py` out of the front-end repo
# rather than by Odoo, so it is a different origin on the same machine.
#
# NOT part of PAIRED_APP_ORIGINS, because the two questions have different
# answers for localhost. For the CORS ALLOW-LIST, localhost is many origins and
# a single guess would name the wrong port most of the time - so
# `models/ir_http.py` owns the full localhost set and admits all of them at once.
# For a LINK, exactly one origin is needed, and 8200 is the one the front-end
# repo's Makefile serves `build/web-local` on (`LOCAL_PORT`), so it is the right
# default rather than a guess.
# THE HOST DECIDES, NOT THE PORT.
#
# This was an enumerated netloc set - `localhost:8069`, `127.0.0.1:8069` and the
# bare hosts - and the port is exactly the part that varies. Odoo writes
# `web.base.url` from the first request it serves, so a developer who started on
# `--http-port=8199` (or 8075, or anything else, which is routine when 8069 is
# already taken) got `http://localhost:8199` and was NOT recognised as local. A
# fresh install reproduced it immediately.
#
# Nothing about being a developer's machine depends on the port, so the check is
# on the hostname alone and any port is accepted.
LOCAL_BACKEND_HOSTS = frozenset({
    "localhost",
    "127.0.0.1",
    "::1",
    "[::1]",
})

# Where `make serve-local` puts the client. See LOCAL_APP_ORIGIN's use in
# `local_app_origin` for why one default is safe here.
LOCAL_APP_ORIGIN = "http://localhost:8200"


def _normalise(url):
    """A comparable origin: scheme + netloc, lowercased, no path, no slash."""
    raw = (url or "").strip()
    if not raw:
        return ""
    # A bare host ("projects.ethara.ai") has no scheme, and urlsplit would read
    # the whole thing as a path. Odoo's own `web.base.url` always carries one,
    # but a hand-edited parameter does not always.
    if "://" not in raw:
        raw = "https://" + raw
    parts = urlsplit(raw)
    if not parts.netloc:
        return ""
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), "", "", ""))


def netloc_of(url):
    """Host and port of ``url``, lowercased. Empty when it cannot be read."""
    return urlsplit(_normalise(url)).netloc


def host_of(url):
    """Hostname of ``url`` with any port stripped, lowercased.

    Not `urlsplit(...).hostname`: that drops the brackets from an IPv6 literal,
    so `[::1]:8069` and `::1` come back the same, and the caller cannot tell
    which spelling it was given. Splitting on the last colon keeps both, and
    LOCAL_BACKEND_HOSTS carries both spellings.
    """
    netloc = netloc_of(url)
    if not netloc:
        return ""
    if netloc.startswith("["):          # [::1]:8069  ->  [::1]
        return netloc.split("]")[0] + "]"
    return netloc.rsplit(":", 1)[0] if ":" in netloc else netloc


def is_local_backend(url):
    """True when ``url`` is a developer's own Odoo rather than a deployment.

    PORT-INDEPENDENT, deliberately - see LOCAL_BACKEND_HOSTS for the fresh-install
    case that proved it has to be.
    """
    return host_of(url) in LOCAL_BACKEND_HOSTS


def paired_app_origin(backend_url):
    """The Flutter client origin deployed alongside ``backend_url``.

    Empty string when the backend host is in no table - a preview environment,
    a bare IP, a topology where the client is served same-origin. Empty is the
    SAFE answer: it widens no CORS allow-list and changes no email link, so an
    unrecognised deployment behaves exactly as it did before this file existed.

    LOCALHOST IS DELIBERATELY NOT IN HERE. This function feeds the CORS
    allow-list, where an origin is TRUSTED, and a developer's machine serves many
    ports. `local_app_origin` answers the link question separately.
    """
    return PAIRED_APP_ORIGINS.get(netloc_of(backend_url), "")


def local_app_origin(backend_url):
    """[LOCAL_APP_ORIGIN] when ``backend_url`` is a developer's own Odoo.

    WHY THIS IS SEPARATE FROM `paired_app_origin`, AND WHY ONE DEFAULT IS FINE
    HERE. The two callers want different things from localhost. CORS has to
    TRUST an origin, and trusting one guessed port would still leave a developer
    on 8201 broken while widening nothing usefully - so `ir_http` admits the
    whole documented localhost set instead. A LINK has to NAME one origin, there
    is no "all of them" answer, and being wrong costs a developer one config
    parameter rather than a security property.

    8200 is not a guess: it is `LOCAL_PORT` in the front-end repo's Makefile,
    which is what `make serve-local` binds `build/web-local` to.

    THIS IS WHAT MAKES A CLONE WORK WITH NO CONFIGURATION. Without it a local
    database fell through to `<web.base.url>/exam/<token>` - port 8069, which is
    Odoo and not the client - so every developer had to set
    `candidate_app_base_url` by hand, discover the redirect landing on the wrong
    host, or both. Production and stage are unaffected: `web.base.url` there is
    never localhost, so this returns "" and the pairing table answers.
    """
    return LOCAL_APP_ORIGIN if is_local_backend(backend_url) else ""


def paired_app_origin_for_env(env):
    """[paired_app_origin] for the deployment ``env`` is running on.

    Reads `web.base.url`, which Odoo keeps current, so nothing extra has to be
    configured for the pairing to be found.

    Never raises. Every caller is on a request path - CORS on every API call,
    and the mail templates - so a database mid-upgrade, or a parameter table
    that is not readable yet, must degrade to "no pairing" rather than take the
    API down.
    """
    try:
        base = env["ir.config_parameter"].sudo().get_param("web.base.url", "")
    except Exception:  # noqa: BLE001 - a lookup must never break a request
        return ""
    return paired_app_origin(base)


# Where the Flutter client lives, when an operator has said so explicitly.
#
# Still the winner over anything derived: a deployment that serves the client
# from a path, a vanity domain, or the same origin as Odoo is a topology no
# table can describe, and this is how it says so.
CANDIDATE_APP_PARAM = "assessments_be_v2.candidate_app_base_url"


def app_base_url(env):
    """Origin of the Flutter client for this deployment, or ``""``.

    THE EXPLICIT HALF OF `client_app_origin`, and its only caller. This answers
    "did an operator name an origin" and nothing else - it reads the parameter
    and returns "" when it is unset. `client_app_origin` below adds the
    derivation, and it is what every link-builder goes through: the candidate's
    deep link and front door via `assessments.be.evaluator._candidate_app_origin`
    in `models/assessment_api.py`, the password-reset link via `_reset_base_url`
    in `controllers/api/auth.py`.

    A NEW CALLER THAT WANTS A USABLE ORIGIN WANTS THAT ONE. Calling this and
    writing its own fallback is precisely the mistake that shipped a dead reset
    link - two copies of one chain, and only one of them knew about the pairing
    table.

    WHY THE FALLBACK IS NOT HERE. Keeping this function to the parameter is what
    lets a caller ask whether an operator has configured anything AT ALL, which
    a defaulting resolver cannot answer.

    THIS DOCSTRING USED TO FORBID DERIVING AT ALL, and the reason was sound at
    the time: an unset deployment emailed
    `<web.base.url>/pro_assessment/<token>` - Odoo's own QWeb exam runner - and
    that route answered 200 on the live hosts, so inferring the app origin would
    have silently redirected every invitation. A behaviour change, not a repair.
    That runner has since been RETIRED (`controllers/legacy_redirects.py` now
    answers its paths with a redirect), so the link that reasoning protected no
    longer resolves to a page. Deriving is the accurate answer now.

    Trailing slashes are stripped, because what reads this concatenates a path.
    """
    try:
        icp = env["ir.config_parameter"].sudo()
        return (icp.get_param(CANDIDATE_APP_PARAM, "") or "").strip().rstrip("/")
    except Exception:  # noqa: BLE001 - a link must never break a transaction
        return ""


def client_app_origin(env):
    """Origin of the Flutter client, ANSWERED - configured or not.

    THE RESOLVER EVERY LINK-BUILDER ACTUALLY WANTS, as opposed to
    `app_base_url`, which reports only what an operator typed. Four steps, most
    explicit first:

      1. `assessments_be_v2.candidate_app_base_url`, when it is set. Still the
         winner over anything derived - a vanity domain, a sub-path, or a
         same-origin deployment is a topology no table can describe.
      2. `paired_app_origin(web.base.url)` - the table at the top of this file.
      3. `local_app_origin(web.base.url)` - a developer's own machine, where
         Odoo is 8069 and the client is 8200.
      4. `web.base.url` itself. A guess, but a guess at the right SHAPE: it is
         what a same-origin deployment looks like.

    WHY THIS EXISTS AT ALL. The chain above was written out inside
    `assessments.be.evaluator._candidate_app_origin`, and the password-reset
    link in `controllers/api/auth.py` used `app_base_url` instead - the
    parameter alone, then straight to `web.base.url`. So on production, where
    `candidate_app_base_url` has never been set, exam invitations correctly
    derived `https://assessment.ethara.ai` while reset emails shipped
    `https://projects.ethara.ai/reset-password`.

    THAT LINK WAS A 404. `/reset-password` is the FLUTTER CLIENT's page
    (`lib/deep_link.dart`, `resetTokenFrom`); Odoo's own reset flow is
    `/web/reset_password`, a different path on a different prefix. Nothing on
    the Odoo host answers the hyphenated one, so every reset email sent from an
    unconfigured database landed on the website's "Page Not Found".

    Two callers spelling out one fallback is how they came to disagree, so
    there is now one copy and both read it.

    Never raises: both callers are on a request path, and a parameter table
    that is not readable yet must degrade to "" rather than take the API down.
    """
    configured = app_base_url(env)
    if configured:
        return configured
    try:
        base = (env["ir.config_parameter"].sudo()
                .get_param("web.base.url", "") or "").strip().rstrip("/")
    except Exception:  # noqa: BLE001 - a link must never break a transaction
        return ""
    return paired_app_origin(base) or local_app_origin(base) or base
