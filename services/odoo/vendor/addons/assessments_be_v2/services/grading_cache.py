# -*- coding: utf-8 -*-
"""Question-group context caches on Vertex for bulk grading (W13).

`scoring._cache_spec` decides WHAT a group cache holds - the instructions and
the group's question material, never an answer, pick, name or answer id - and
its key. This module finds or creates the Vertex cache for that key, keeps it
alive, and books what it costs (`docs/ETP_PLANS_AND_STRATEGY.md` §3.10).

A CACHE PROBLEM NEVER BLOCKS GRADING. `resolve` returns None instead of
raising - the call then goes inline, uncached, with no attempt spent. Only the
spend caps and Kill Scoring propagate, as they would refuse the call anyway.

THE BOOKKEEPING IS ON A SHORT CURSOR OF ITS OWN, like
`vertex._vertex_bearer_until`, never inside a candidate's marks transaction.
That cursor runs at READ COMMITTED, so a lane that wins a key's lock sees a
cache another lane committed a moment before. Only the lock holder creates or
extends: a lane that loses the race grades that call inline.
"""
import logging
from contextlib import contextmanager
from datetime import timedelta
from types import SimpleNamespace

from odoo import SUPERUSER_ID, api, fields

from ..constants import ADVISORY_LOCK_SCORING_CACHE
from . import model_catalog
from . import vertex as vertex_svc

_logger = logging.getLogger(__name__)

TTL_SECONDS = 900
#: A cache with less than this left is extended when used.
EXTEND_BELOW = timedelta(minutes=5)
#: A cache this close to expiry is treated as gone.
LIVE_MARGIN = timedelta(seconds=60)
#: A failed create is not retried for its key before this has passed.
RETRY_CREATE_AFTER = timedelta(minutes=10)


@contextmanager
def _own_env(env):
    if not vertex_svc._side_cursor_is_safe(env):
        yield env
        return
    with env.registry.cursor() as cr:
        cr.execute("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
        yield api.Environment(cr, SUPERUSER_ID, {})


def _try_lock(env, key):
    env.cr.execute("SELECT pg_try_advisory_xact_lock(%s, %s)",
                   (ADVISORY_LOCK_SCORING_CACHE, int(key[:8], 16) - 2 ** 31))
    return env.cr.fetchone()[0]


def _row(env, key):
    Cache = env["assessments.be.scoring.cache"].sudo()
    Cache.invalidate_model()
    return Cache.search([("key", "=", key)], limit=1)


def _live(row, now):
    return bool(row and row.resource_name and row.expires_at
                and row.expires_at > now + LIVE_MARGIN)


def _failed(row, now):
    return bool(row and row.failed_until and row.failed_until > now)


def _auth(env):
    """Where and how to reach Vertex, or None: caching needs the bearer
    (service-account) path, so an API key grades inline. A bearer with no
    project is not configured (`vertex._bearer_project`)."""
    project, location, _model, _key = vertex_svc._vertex_creds(env)
    bearer = vertex_svc._vertex_bearer(env)
    if not bearer:
        return None
    project = vertex_svc._bearer_project(env, project)
    return SimpleNamespace(
        host=vertex_svc._vertex_host(location), project=project,
        location=location, pinned=bool(env.context.get("etp_vertex_bearer")),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer %s" % bearer})


def _send(env, auth, method, url, body, model, ctx):
    """A 401 on a pinned bearer (it lapsed while the call waited for a
    worker) is booked and sent once more with a fresh one, as `vertex` does."""
    send = getattr(vertex_svc._httpx(), method)
    resp = send(url, json=body, headers=auth.headers)
    if resp.status_code == 401 and auth.pinned:
        auth.pinned = False
        vertex_svc._log_failed_call(env, model, ctx, 401, resp.text)
        fresh = vertex_svc._vertex_bearer(
            env(context=dict(env.context, etp_vertex_bearer=False)))
        auth.headers = dict(auth.headers, Authorization="Bearer %s" % fresh)
        resp = send(url, json=body, headers=auth.headers)
    return resp


def resolve(env, cache, system_prompt, model, usage_ctx):
    """The name of a live Vertex cache for ``cache``, or None: inline."""
    try:
        name, booking = _resolve(env, cache, system_prompt, model, usage_ctx)
    except (vertex_svc.VertexBudgetError, vertex_svc.VertexCancelledError,
            vertex_svc.VertexNotConfiguredError, vertex_svc.VertexQuotaError):
        raise
    except Exception:  # noqa: BLE001 - a cache problem never blocks grading
        _logger.warning("etp_assessment grading cache %s unavailable; this "
                        "call goes inline.", cache.key[:12], exc_info=True)
        return None
    if booking:
        _book(env, model, *booking)
    return name


def _resolve(env, cache, system_prompt, model, usage_ctx):
    auth = _auth(env)
    if auth is None:
        return None, None
    now = fields.Datetime.now()
    with _own_env(env) as own:
        row = _row(own, cache.key)
        if _live(row, now) and row.expires_at - now >= EXTEND_BELOW:
            return row.resource_name, None
        if not _live(row, now) and (not cache.create or _failed(row, now)):
            return None, None
        # An extension or a create is due, and only the key's lock holder
        # makes it. A loser still uses a live cache, else goes inline.
        if not _try_lock(own, cache.key):
            return (row.resource_name if _live(row, now) else None), None
        row = _row(own, cache.key)
        if _live(row, now):
            if row.expires_at - now >= EXTEND_BELOW:
                return row.resource_name, None
            return _extend(own, auth, row, now)
        if _failed(row, now):
            return None, None
        vertex_svc._check_budget(env, usage_ctx)
        vertex_svc._check_scoring_cancelled(env, usage_ctx)
        return _create(own, auth, row, cache, system_prompt, model, now)


def _create(env, auth, row, cache, system_prompt, model, now):
    body = {
        "model": "projects/%s/locations/%s/publishers/google/models/%s"
                 % (auth.project, auth.location, model),
        "systemInstruction": {"parts": [{"text": system_prompt}]},
        "contents": [{"role": "user", "parts": [{"text": cache.block}]}],
        "ttl": "%ds" % TTL_SECONDS,
    }
    url = "%s/v1/projects/%s/locations/%s/cachedContents" % (
        auth.host, auth.project, auth.location)
    name, tokens = None, 0
    try:
        resp = _send(env, auth, "post", url, body, model, {
            "operation": "scoring_cache_create",
            "note": "cache create %s" % cache.key[:12]})
        if resp.status_code == 200:
            data = resp.json()
            name = data.get("name")
            tokens = int((data.get("usageMetadata") or {})
                         .get("totalTokenCount") or 0)
        else:
            _logger.warning("etp_assessment grading cache create refused "
                            "[%s]: %s", resp.status_code, resp.text[:200])
    except Exception:  # noqa: BLE001 - the call goes inline
        _logger.warning("etp_assessment grading cache create failed",
                        exc_info=True)
    vals = {"key": cache.key, "model": model, "location": auth.location}
    if name:
        vals.update(resource_name=name, token_count=tokens, created_at=now,
                    expires_at=now + timedelta(seconds=TTL_SECONDS),
                    failed_until=False)
    else:
        vals["failed_until"] = now + RETRY_CREATE_AFTER
    if row:
        row.write(vals)
    else:
        env["assessments.be.scoring.cache"].sudo().create(vals)
    if not name:
        return None, None
    _logger.info("etp_assessment grading cache created: %s (%d tokens)",
                 name, tokens)
    return name, ({"operation": "scoring_cache_create",
                   "note": "cache create %s" % cache.key[:12]},
                  tokens, tokens, TTL_SECONDS)


def _extend(env, auth, row, now):
    """PATCH the cache's ttl back to the full 15 minutes. A 404 means Vertex
    no longer has it (inline); any other failure keeps using it as it is."""
    name = row.resource_name
    try:
        resp = _send(
            env, auth, "patch", "%s/v1/%s?updateMask=ttl" % (auth.host, name),
            {"ttl": "%ds" % TTL_SECONDS}, row.model,
            {"operation": "scoring_cache_refresh",
             "note": "cache refresh %s" % row.key[:12]})
    except Exception:  # noqa: BLE001 - still live, used as it is
        _logger.warning("etp_assessment grading cache extend failed",
                        exc_info=True)
        return name, None
    if resp.status_code == 404:
        row.write({"expires_at": now})
        return None, None
    if resp.status_code != 200:
        _logger.warning("etp_assessment grading cache extend refused [%s]: %s",
                        resp.status_code, resp.text[:200])
        return name, None
    expires = now + timedelta(seconds=TTL_SECONDS)
    added = (expires - row.expires_at).total_seconds()
    row.write({"expires_at": expires})
    return name, ({"operation": "scoring_cache_refresh",
                   "note": "cache refresh +%ds %s" % (added, row.key[:12])},
                  0, row.token_count, added)


def forget(env, cache, name):
    """Vertex no longer has ``name``: its row stops being live.

    A CACHE REJECTED WHILE WE BELIEVE IT IS LIVE IS A BREAKER, NOT AN EXPIRY:
    a key Vertex refuses on use (IAM, a location mismatch, an API change)
    would otherwise be re-created, and rejected, once per candidate. It gets
    the 10-minute `failed_until` backoff a failed CREATE gets, so the group
    grades inline until it lapses. A row that had genuinely run out of time
    just expires - re-creating that one is correct.
    """
    try:
        now = fields.Datetime.now()
        with _own_env(env) as own:
            rows = own["assessments.be.scoring.cache"].sudo().search([
                ("key", "=", cache.key), ("resource_name", "=", name),
            ])
            for row in rows:
                vals = {"expires_at": now}
                if row.expires_at and row.expires_at > now:
                    vals["failed_until"] = now + RETRY_CREATE_AFTER
                    _logger.warning(
                        "etp_assessment grading cache %s was rejected while "
                        "still live; this group grades inline for %d minute(s)",
                        cache.key[:12], RETRY_CREATE_AFTER.total_seconds() // 60)
                row.write(vals)
    except Exception:  # noqa: BLE001 - the row simply expires on its own
        _logger.warning("etp_assessment could not mark grading cache %s gone",
                        name, exc_info=True)


def _book(env, model, ctx, tokens_in, stored, seconds):
    """A ledger row with no candidate: input tokens at the model's rate (a
    create) plus storage of ``stored`` tokens for ``seconds``."""
    try:
        values = vertex_svc._ledger_values(
            env, model, {"promptTokenCount": tokens_in}, 0, ctx)
        values["cost_usd"] += model_catalog.cache_storage_cost(
            model, stored, seconds)
        vertex_svc._write_ledger_row(env, values)
        # Through the same "LLM usage" line as every other billed call, so
        # spend totalled from the logs includes cache create/refresh.
        vertex_svc.log_usage_line(values, cache=True)
    except Exception as exc:  # noqa: BLE001 - never fail grading on a ledger row
        _logger.error(
            "etp_assessment COST ACCOUNTING FAILED (op=%s model=%s): %s - the "
            "cache was billed but NOT recorded.", ctx.get("operation"), model,
            exc)
