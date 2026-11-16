# -*- coding: utf-8 -*-
"""Shared plumbing for every /api/v1 route: envelope, auth guards, paging.

WHY a hand-rolled envelope instead of raising:
a mobile client on a flaky network needs one predictable body shape, so every
endpoint returns ``{"ok": bool, ...}`` with an HTTP status that matches. An
uncaught exception would hand the Flutter client an Odoo traceback object it
has no schema for.

WHY json2 and not the legacy ``type='json'``:
``type='json'`` is a deprecated alias for ``type='jsonrpc'`` in Odoo 19, and
JSON-RPC forces the client to wrap every call in an envelope
(``{"jsonrpc":"2.0","method":"call","params":{...}}``) and returns HTTP 200
even for failures. ``json2`` is Odoo 19's plain-JSON dispatcher: JSON body in,
JSON body out, real HTTP status codes. That is what a REST client needs. One
constant here so the whole surface can be moved in a single edit if that
changes.

NOTE on json2 and query strings: the json2 dispatcher merges the request BODY
with the path parameters and deliberately ignores the query string. Every
filter/paging argument therefore travels in the JSON body, and list endpoints
accept both GET (no body, defaults) and POST (body with filters).
"""
import functools
import logging

from psycopg2.errors import SerializationFailure, TransactionRollbackError
from psycopg2.pool import PoolError

from odoo.exceptions import AccessDenied, AccessError, UserError, \
    ValidationError
from odoo.http import request

from ...services import audit

# RE-EXPORTED, not defined here - see the note above the group constants below.
from ...constants import (  # noqa: F401 - re-export
    GROUP_CANDIDATE, GROUP_MANAGER, GROUP_MANAGER_RESTRICTED,
    ROLE_CANDIDATE, ROLE_NONE, ROLE_STAFF,
)

_logger = logging.getLogger(__name__)

# The single route type for the whole API. See the module docstring.
API_TYPE = "json2"
# Both verbs on every route: GET for a bare fetch, POST when the client has
# filters/paging/payload to send (json2 only reads the body, never the query
# string).
API_METHODS = ["GET", "POST"]

# THE THREE RUNGS, LOWEST FIRST. `has_group` resolves through `implied_ids`
# (Admin implies Manager implies Candidate), so a guard tests the LOWEST group
# that should pass and the higher ones come along for free.
#
# `GROUP_MANAGER` keeps its name and still points at the full-power group, now
# labelled "Admin" - see `require_manager` and the security file for why the
# xmlid was not repurposed.
#
# DEFINED IN `constants.py`, imported at the top of this file and re-exported
# from here. Models need them too - `res.users._be_assessment_role` and
# `assessments.be._ensure_candidate_user` - and a model importing from a
# controller is the wrong direction. Re-exporting keeps every existing
# `from .common import GROUP_MANAGER` site working unchanged.

# What a shed request is told to wait before repeating itself.
#
# Two seconds, deliberately short. This is returned when the DB connection pool
# is momentarily full, which clears as soon as in-flight requests finish - so the
# right advice is "almost immediately", not "much later". Too long and a
# candidate mid-exam sees a stall where a retry would have succeeded; too short
# and a saturated server is hammered by the very clients it just refused.
#
# The client waits exactly this long between retries: `_retryDelay` in
# `api_client.dart` takes `Retry-After` as given and falls back to exponential
# backoff with jitter only when the header is absent.
RETRY_AFTER_SECONDS = 2

# Paging guard rails. An unbounded list endpoint over the response table is a
# worker-pinning vector on a large cohort, so limit is always clamped.
DEFAULT_LIMIT = 40
MAX_LIMIT = 200

# Ceiling on the leaderboard, which is NOT a paged list and must not borrow
# MAX_LIMIT.
#
# WHY IT IS SEPARATE. The board is a whole-cohort ranking: `leaderboard` groups
# every submitted attempt by applicant in the database and holds the result in
# memory before sorting, so the limit governs only how many rows are SERIALIZED,
# not how much work was done. Clamping it at MAX_LIMIT (200) therefore bought
# nothing and silently dropped people: the 588-candidate cohort of 2026-09-03
# ranked 200 and omitted 388, with nothing in the payload saying so.
#
# 2000 is a serialization guard, not a paging rule - about 300 KB of JSON at this
# row shape, and above any cohort this platform is designed for. `meta.total` is
# returned alongside, so a client can always tell whether it holds everyone.
MAX_LEADERBOARD = 2000

# Ceiling on a CSV export, in bytes of raw file. Peak memory is roughly three
# times this (file + base64 + the JSON copy), so 20 MB is about 60 MB of
# transient worker memory - large but survivable, which unbounded is not.
MAX_EXPORT_BYTES = 20 * 1024 * 1024


# Response envelope

def ok(data=None, **extra):
    """Success envelope. ``data`` is the payload; extras ride alongside it."""
    payload = {"ok": True}
    if data is not None:
        payload["data"] = data
    payload.update(extra)
    return payload


def fail(code, message, status=400, headers=None, **extra):
    """Failure envelope with a machine-readable ``code`` and a real HTTP status.

    ``code`` is the contract the client branches on; ``message`` is for humans
    and may be reworded at any time.

    This returns a built Response rather than a dict because the status code
    has to be non-200: the json2 dispatcher passes a Response through
    untouched but json-encodes a plain dict at status 200, and a mobile
    network layer must be able to tell a 401 from a 200 without parsing the
    body (that is what drives token refresh and retry).

    ``headers`` is a NAMED parameter rather than another ``**extra`` key, and
    the distinction matters: everything in ``extra`` is merged into the JSON
    BODY, so passing headers there would have put a list of tuples in the
    payload and set no header at all. The one caller that needs it is the 503
    shed, where ``Retry-After`` is the part a client's retry ladder actually
    reads - a body field it has to parse is not a substitute.
    """
    payload = {"ok": False, "error": {"code": code, "message": message}}
    payload.update(extra)
    response = request.make_json_response(payload, status=status,
                                          headers=headers)
    # The refusal CODE, stashed where `api_endpoint` can read it back.
    #
    # Every guard in this API refuses by RETURNING this envelope, not by
    # raising - so the wrapper's except branches never see a 403 or a 422, and
    # an audit line built from the status alone cannot tell `wrong_candidate`
    # from `not_released` from `forbidden`. Those are three different
    # incidents on the same route. An attribute costs nothing and beats
    # re-parsing the body we just serialized.
    #
    # GUARDED, because `make_json_response` does not always return a Response:
    # the saturation tests stub it with one that hands back a plain dict, and a
    # dict has no attributes to set. An audit detail may never be the reason a
    # refusal fails to reach the client.
    try:
        response._etp_code = code
    except Exception:  # noqa: BLE001 - observability is never load-bearing
        pass
    return response


def paged(rows, total, limit, offset):
    return ok(rows, meta={
        "total": total,
        "limit": limit,
        "offset": offset,
        "has_more": (offset + len(rows)) < total,
    })


# Decorators

def api_endpoint(func):
    """Turn any leaked exception into the standard failure envelope.

    Without this an ORM ValidationError reaches the client as a serialized
    Odoo exception with a traceback, which leaks internals and gives the app
    no stable ``code`` to branch on.

    NOT RELATED TO api_auth_gateway's ``api.endpoint`` MODEL, despite the
    name. Worth stating because the resemblance reads as a security hole that
    is not there: the gateway authorizes by matching the request path against
    ``api.role.endpoint`` rows, and none of this addon's routes are registered
    as such rows - which looks like 78 unauthorized endpoints.

    They are not, because nothing here goes through the gateway's decorator.
    It reads an ``access_token`` HEADER; these routes are ``auth="user"`` and
    adopt an ``Authorization: Bearer`` token in ir_http, then gate on
    ``require_manager`` / ``require_staff`` and, where a specific record is
    involved, ``record_read_guard``. That is Odoo's own ACL and record rules -
    strictly stronger than a URL-pattern allow-list, and it is per record
    rather than per path. Registering the routes with the gateway would add a
    second, weaker authorization layer with its own drift to keep in sync.
    """
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        t0 = audit.start()
        try:
            result = func(*args, **kwargs)
        except (AccessDenied, AccessError) as exc:
            audit.emit("api.error", outcome="forbidden", t0=t0, error=exc,
                       route=func.__qualname__, status=403)
            return fail("forbidden", str(exc) or "Access denied", status=403)
        except (UserError, ValidationError) as exc:
            # A UserError is a deliberate, user-facing refusal from the domain
            # layer (e.g. "Only draft assessments can be started"), so its text
            # is safe and useful to forward verbatim.
            #
            # ROLL BACK FIRST, exactly as the generic branch below does. This
            # is a RETURN, not a re-raise: the request then finishes normally
            # and Odoo COMMITS whatever the route wrote before the refusal. A
            # route that mutates and only then hits a guard therefore used to
            # persist half its work while telling the client it did nothing -
            # that is how a generator delete destroyed a bank of questions and
            # reported "Cannot delete - used by assessment". A refusal must
            # leave the database as it found it.
            try:
                request.env.cr.rollback()
            except Exception:  # noqa: BLE001 - already failing; never mask it
                pass
            # A refusal that names its own code (RescoreRefused, e.g. 409
            # `stopping`) keeps it on every route.
            code = getattr(exc, "code", None)
            status = getattr(exc, "http_status", 409) if code else 422
            audit.emit("api.error", outcome="rejected", t0=t0, error=exc,
                       route=func.__qualname__, status=status)
            return fail(code or "rejected", str(exc), status=status)
        except Exception as exc:  # noqa: BLE001 - the API must never 500 raw
            # A serialization failure is RETRYABLE and must propagate.
            #
            # Postgres aborts the whole transaction on one - no savepoint can
            # rescue it - and Odoo's `service.model.retrying` replays the whole
            # request when it reaches the top. Converting it to an envelope
            # here defeats that retry AND leaves the cursor dead, so every
            # later query (including the serializer building this very
            # response) fails with InFailedSqlTransaction. That is what turned
            # a transient blip into a permanent 500 on extract_tags.
            if isinstance(exc, (SerializationFailure, TransactionRollbackError)):
                raise
            # SATURATION IS NOT A BUG, AND MUST NOT LOOK LIKE ONE.
            #
            # When every connection is checked out, Odoo raises
            # `psycopg2.pool.PoolError("The Connection Pool Is Full")`. Folded
            # into the generic branch below it became a flat 500 - so the client
            # could not tell "come back in a moment" from "this endpoint is
            # broken", and its retry ladder (`_retryDelay` in `api_client.dart`,
            # which honours `Retry-After`) had nothing correct to honour. On
            # 2026-09-03 that produced 35,362 pool-full events reported as
            # 30.68% server errors.
            #
            # 503 + Retry-After is the honest answer: the request was refused
            # for lack of capacity, it is safe to repeat, and here is when.
            #
            # LOGGED AT WARNING, NOT AS AN EXCEPTION. A traceback per refused
            # request is what turns saturation into a log flood that hides the
            # cause - and there is nothing in the traceback to act on. The
            # message names the condition instead.
            if isinstance(exc, PoolError):
                try:
                    request.env.cr.rollback()
                except Exception:  # noqa: BLE001 - already failing
                    pass
                _logger.warning(
                    "API shed load in %s evaluator_id=%s: the database "
                    "connection pool is full. Raise db_maxconn, or lower the "
                    "per-worker handler bound (ODOO_MAX_HTTP_THREADS) so fewer "
                    "requests compete for it.",
                    func.__qualname__, request_evaluator_id())
                audit.emit("api.error", outcome="busy", t0=t0, error=exc,
                           route=func.__qualname__, status=503)
                return fail(
                    "busy",
                    "The server is at capacity. This request was not "
                    "processed - try again in a moment.",
                    status=503,
                    retry_after=RETRY_AFTER_SECONDS,
                    headers=[("Retry-After", str(RETRY_AFTER_SECONDS))])
            _logger.exception("API failure in %s evaluator_id=%s",
                              func.__qualname__, request_evaluator_id())
            # Discard the broken transaction BEFORE building the envelope, so
            # the `fail(...)` below and Odoo's end-of-request flush both run on
            # a usable cursor.
            try:
                request.env.cr.rollback()
            except Exception:  # noqa: BLE001 - already failing; never mask it
                pass
            audit.emit("api.error", outcome="server_error", t0=t0, error=exc,
                       route=func.__qualname__, status=500)
            return fail("server_error", "Unexpected server error", status=500)
        # A REFUSAL IS A RETURN, NOT A RAISE - so it lands here, not above.
        #
        # `require_candidate`, `_write_guard` and every `fail(...)` in the API
        # hand back a built Response with a 4xx status; the branches above only
        # ever see an exception. Reading the status back off the result is
        # therefore the ONLY place that sees the refusals which actually matter
        # during a sitting - the 403 wave on `/me/assessments`, the 409
        # `attempt_locked`, the 422 `incomplete_answer`.
        #
        # On the success path this is one getattr against a plain dict, which
        # `ok()` returns and which has no `status_code`.
        status = getattr(result, "status_code", 200)
        if status >= 400:
            audit.emit("api.error", outcome=getattr(result, "_etp_code", ""),
                       t0=t0, route=func.__qualname__, status=status)
        return result
    return wrapper


def require_manager(func):
    """Gate a route on ADMIN - full power. The default for every admin route.

    THE NAME IS HISTORICAL AND THE GROUP IS "Admin". `GROUP_MANAGER` points at
    `group_assessment_manager`, which has always been the full-power group and
    is now labelled Admin; the read-only role added beside it is
    `group_assessment_manager_restricted`, gated by `require_operator` below.
    The xmlid and the constant keep their names so the ~40 sites referencing
    them did not all have to change meaning at once - see the note in
    `security/etp_assessment_security.xml`.

    FAIL CLOSED IS THE WHOLE DESIGN. Every route keeps this gate unless it is
    explicitly opted down to `require_operator`, so a route nobody thought about
    stays Admin-only. A read-only Manager then sees a visible 403 on a feature,
    which is a bug report; the inverse - repointing this gate down and raising
    the sensitive routes one by one - makes every overlooked route a privilege
    leak instead.
    """
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        if not request.env.user.has_group(GROUP_MANAGER):
            return fail("forbidden",
                        "Assessment Admin access required", status=403)
        return func(*args, **kwargs)
    return wrapper


#: Today's `require_staff` sites. Kept as an alias rather than rewritten,
#: because the name still records WHICH routes were once meant to be readable
#: by a non-manager - and that record is exactly what the read-only Manager
#: role was built from. It checks Admin, like `require_manager`; a route that
#: should be readable by a Manager carries `require_operator` instead.
require_staff = require_manager


def require_operator(func):
    """Gate a READ-ONLY route on Manager, which an Admin also satisfies.

    `has_group` resolves through `implied_ids` and Admin implies Manager, so
    testing the lower group admits both and no guard has to enumerate roles.

    WHAT A MANAGER IS. A read-only operator: they watch assessments run and
    read the results, and they author nothing. Dashboard, Assessments,
    Question Bank, Tags, LLM Budget and Form Studio are readable; Generators,
    Review Queue and Settings are not, and nothing they can reach writes.

    SO THIS DECORATOR BELONGS ONLY ON ROUTES THAT MUTATE NOTHING. It is not a
    "Manager may do this" marker, it is a "this is a read" marker. A route that
    creates, updates, deletes, launches, releases, re-scores or spends keeps
    `require_manager` even where the screen it serves is one a Manager can see -
    which is why Assessments and Form Studio are visible-but-read-only rather
    than half-writable.
    """
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        if not is_operator(request.env.user):
            return fail("forbidden",
                        "Assessment Manager access required", status=403)
        return func(*args, **kwargs)
    return wrapper


def is_operator(user):
    """The test `require_operator` applies, for a payload that shows more to
    an operator than to other callers (run cost on `/generators/<id>/progress`)
    rather than refusing them outright."""
    return user.has_group(GROUP_MANAGER_RESTRICTED)


def require_candidate(func):
    """Gate a candidate route on the Candidate group.

    WHY THIS HAD TO BE ADDED RATHER THAN RE-POINTED. Nothing on the candidate
    path checked a group at all: `auth="user"` only requires "not the public
    user", and authorisation was the exam token plus an integer identity match.
    Candidate ability therefore rode on `base.group_user`, which every employee
    in the instance holds - so "Assessment v2 Access = No" still let a person
    sit an exam, which is the defect this closes.

    Admin and Manager both imply Candidate, so an operator previewing an
    attempt still passes. The token and identity checks are unchanged and still
    decide WHOSE attempt may be touched; this only decides who may reach the
    surface at all.
    """
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        if not request.env.user.has_group(GROUP_CANDIDATE):
            return fail("forbidden",
                        "Assessment access is not enabled for this account",
                        status=403)
        return func(*args, **kwargs)
    return wrapper


def record_read_guard(record):
    """Enforce the caller's OWN ACL and record rules on ``record``.

    Returns None when the read is allowed, and a ready-to-return 403 envelope
    when it is not.

    WHY THIS IS NOT ALREADY COVERED by browsing the record: ``browse(id)``
    builds a recordset without touching the database and ``.exists()`` issues a
    bare ``SELECT id``, which passes through no ir.model.access and no ir.rule.
    A route that then reads the record's related rows under ``sudo()`` never
    reads one field as the caller, so nothing anywhere in it consults a record
    rule - an Evaluator could walk ids and read the audit trail (and the mail
    history) of assessments, generators and attempts that their record rule
    hides from them entirely.

    The ORM's own AccessError text names the model, the record ids and the
    groups that would grant access, so it is swallowed for a flat sentence:
    a caller who may not read a record must not learn its shape from the
    refusal either.
    """
    try:
        record.check_access("read")
    except AccessError:
        return fail("forbidden", "You may not read this record", status=403)
    return None


# Request parameters

def body(source=None):
    """The parsed JSON body merged with path params (json2 puts both here).

    ``source`` reads a dict from inside the body instead (one item of
    `/exam/<token>/answers/batch`), so an item is parsed exactly as `/answer`
    parses the whole body.
    """
    return (request.params or {}) if source is None else source


def arg(name, default=None, source=None):
    return body(source).get(name, default)


def int_arg(name, default=0, source=None):
    try:
        return int(body(source).get(name, default) or default)
    except (TypeError, ValueError, OverflowError):
        return default


def bool_arg(name, default=False, source=None):
    raw = body(source).get(name, default)
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, str):
        return raw.strip().lower() in ("1", "true", "yes", "on")
    return bool(raw)


def str_arg(name, default="", max_len=None, source=None):
    raw = body(source).get(name, default)
    if raw is None:
        raw = default
    text = str(raw).strip()
    return text[:max_len] if max_len else text


def id_list_arg(name, source=None):
    """A list of record ids, tolerating a single int or a comma string."""
    raw = body(source).get(name)
    if raw is None:
        return []
    if isinstance(raw, int):
        return [raw]
    if isinstance(raw, str):
        raw = raw.split(",")
    out = []
    for item in raw if isinstance(raw, (list, tuple)) else []:
        try:
            out.append(int(item))
        except (TypeError, ValueError, OverflowError):
            continue
    return out


#: `id_list_arg_strict` returns this when the body carries no such key at all.
_ABSENT = object()


def id_list_arg_strict(name, noun="question ids", empty_ok=False,
                       null_ok=True):
    """Ids, telling "key absent" from "key present but unreadable".

    `id_list_arg` answers `[]` to an absent key, to `[]` and to garbage like
    `'abc'` or `[{...}]` alike, and a route that reads `[]` as "no ids given"
    does the WIDEST thing it has: re-score every unresolved answer, release
    the whole cohort. Only an ABSENT key may mean that.

    Returns None when the key is missing (or null), a non-empty list of ints
    when every item reads as one, and raises ValueError otherwise - with the
    reason, because "invalid" alone does not tell a client which shape it
    sent. A single int and a comma string are accepted.

    ``noun`` names the ids in those messages. ``empty_ok`` reads an empty
    list as absent, for routes whose shipped clients always send the key.
    ``null_ok=False`` refuses a null, where absent means the widest action.
    """
    raw = body().get(name, _ABSENT)
    if raw is _ABSENT or (raw is None and null_ok):
        return None
    if isinstance(raw, bool):
        raise ValueError("`%s` must be a list of %s, not a boolean."
                         % (name, noun))
    if isinstance(raw, int):
        return [raw]
    if isinstance(raw, str):
        raw = [part for part in raw.split(",") if part.strip()]
    if empty_ok and isinstance(raw, (list, tuple)) and not raw:
        return None
    if not isinstance(raw, (list, tuple)) or not raw:
        raise ValueError(
            "`%s` was sent but holds no usable ids. Send a non-empty list of "
            "%s." % (name, noun))
    out = []
    for item in raw:
        if isinstance(item, bool):
            item = None
        try:
            out.append(int(item))
        except (TypeError, ValueError, OverflowError):
            raise ValueError(
                "`%s` must hold %s; %r is not one." % (name, noun, item)
            ) from None
    return out


def paging():
    """(limit, offset) clamped so no caller can request an unbounded scan."""
    limit = int_arg("limit", DEFAULT_LIMIT) or DEFAULT_LIMIT
    offset = max(0, int_arg("offset", 0))
    return max(1, min(limit, MAX_LIMIT)), offset


# Identity resolution

def resolve_applicant(user=None):
    """The hr.applicant for a logged-in user, or an empty recordset.

    Delegates to `hr.applicant._be_applicant_for_user`, which is the exact
    mirror of the applicant -> user walk the exam gate uses. This function used
    to carry its own copy of the three steps, and the docstring said so
    ("copied verbatim from candidate_portal._resolve_applicant") - three copies
    in all, which drifted apart until the list and the gate disagreed about who
    a candidate was. Keep it a delegation.
    """
    return request.env["hr.applicant"]._be_applicant_for_user(
        user or request.env.user)


def evaluator_from_token(token):
    """Resolve an exam access token to its attempt, or an empty recordset.

    A DRAFT PAPER'S TOKEN RESOLVES TO NOTHING. The roster row, and with it the
    token, exists from assignment, before launch; answering it `closed` told
    whoever held the link that a paper exists and what it is called. Until
    launch it is an unknown link, for every route and every caller (a draft
    has no drawn paper, so there is no preview to keep).
    """
    if not token:
        return request.env["assessments.be.evaluator"].sudo().browse()
    evaluator = request.env["assessments.be.evaluator"].sudo().search(
        [("access_token", "=", token),
         ("assessment_id.state", "!=", "draft")], limit=1)
    # Every exam route resolves its attempt here, so this is where the id is
    # kept for `api_endpoint`'s failure log: the token is a credential and is
    # never logged, and without the id the candidates hit by a 500 could not
    # be listed after the incident.
    request._etp_evaluator_id = evaluator.id
    return evaluator


def request_evaluator_id():
    """The attempt id `evaluator_from_token` resolved in this request, or
    None. For log lines only, so it never raises (an unbound `request`
    outside an HTTP request raises RuntimeError, not AttributeError)."""
    try:
        return getattr(request, "_etp_evaluator_id", None)
    except Exception:  # noqa: BLE001 - a log detail is never load-bearing
        return None


def is_assigned_candidate(evaluator):
    """True only when the CURRENT user is the candidate this token belongs to.

    Mirrors portal._is_real_candidate. Anything that mutates an attempt
    (begin/answer/submit/violation) must gate on this and not merely on the
    token, because a manager previewing an exam holds the token too and must
    never write into a real candidate's attempt.
    """
    if not evaluator:
        return False
    candidate_user = evaluator._candidate_user()
    return bool(candidate_user) and request.env.user.id == candidate_user.id


def may_view_attempt(evaluator):
    """True when the current user may READ this attempt through its token.

    The bound candidate always may; when the attempt has no resolvable candidate
    user, STAFF may - that is the preview path. Everyone else is a
    wrong-candidate.

    ASKS FOR STAFF, NOT SPECIFICALLY FOR ADMIN. This tested
    `has_group(GROUP_MANAGER)`, i.e. Admin only, which predates the read-only
    Manager rung. Previewing an attempt is a pure read and Assessments is a
    surface a Manager is meant to have, so the narrower test was excluding the
    exact role it was written for. `_be_assessment_role` answers it once for
    every gate; see `models/res_users.py`.
    """
    if not evaluator:
        return False
    candidate_user = evaluator._candidate_user()
    if candidate_user:
        return request.env.user.id == candidate_user.id
    return request.env.user._be_is_staff()
