"""Answer a saturated connection pool with 503, not 500 - before dispatch.

WHY THIS EXISTS SEPARATELY FROM THE SHED IN `api/common.py`. That one wraps the
API endpoints and catches `PoolError` raised INSIDE a handler. Measured under a
real write ladder on 2026-09-09, that is not where saturation actually lands:

    File "odoo/http.py", line 2810, in __call__
      response = request._serve_db()
    File "odoo/http.py", line 2230, in _serve_db
      cr = registry.cursor(readonly=True)
    psycopg2.pool.PoolError: The Connection Pool Is Full

The cursor is taken to MATCH the route, so the pool is exhausted before any
controller exists to have been wrapped. Every one of those requests came back
HTTP 500. The endpoint decorator was doing its job and never ran.

WHY `_serve_db` AND NOT `Application.__call__`. `__call__` already has a generic
`except Exception` that logs and returns a 500, so a wrapper around it never
sees the exception - only the 500 it has already become. `_serve_db` is the
frame that raises, and `PoolError` is deliberately absent from the
`(AttributeError, OperationalError, ProgrammingError)` tuple it does catch, so
it propagates cleanly and can be intercepted here without touching Odoo's own
error handling for anything else.

WHY 503 AND NOT 500. They are different instructions. A 500 tells a client the
request was wrong and invites a retry that makes the queue longer; a 503 with
`Retry-After` tells it the server is briefly full, which every load balancer,
proxy and sensible client already knows how to handle - and it keeps the
deployment out of a crash-loop when liveness probes are watching. The condition
is capacity, and capacity is temporary by definition.

THE BLAST RADIUS, stated plainly. This patches a method on Odoo's own
`Request`, so it applies to every request in every installed module, not just
this addon's. That is inherent: the pool is process-wide and the exhaustion
happens before anything knows which module the request was for. It is kept as
narrow as a global patch can be - one exception type, one status code,
everything else delegated untouched and re-raised - and it is idempotent, so a
registry reload cannot stack wrappers.

WHAT THIS DOES NOT FIX. Sizing. A pool that fills under normal load is a
configuration problem: `db_maxconn` must cover the workers, and Postgres
`max_connections` must cover `workers x db_maxconn`. This turns the symptom
into the right signal; it does not create capacity.
"""
import json
import logging

import werkzeug.wrappers
from psycopg2.pool import PoolError

from odoo.http import Request

from ..models.ir_http import _RedactExamTokens

_logger = logging.getLogger(__name__)
# The shed's warning names the request path, and an exam path carries the
# token - a credential. The access log's filter only covers `werkzeug`.
_logger.addFilter(_RedactExamTokens())

# Seconds. Matches RETRY_AFTER_SECONDS in api/common.py so the two sheds tell a
# client the same thing.
RETRY_AFTER_SECONDS = 2

_PATCH_FLAG = "_assessments_be_v2_load_shed"


def _shed_response():
    """The 503 a saturated server answers with."""
    body = json.dumps({
        "ok": False,
        "error": {
            "code": "busy",
            "message": "The server is at capacity. Try again in a moment.",
        },
        "retry_after": RETRY_AFTER_SECONDS,
    })
    return werkzeug.wrappers.Response(
        body,
        status=503,
        headers=[
            ("Content-Type", "application/json"),
            ("Retry-After", str(RETRY_AFTER_SECONDS)),
            # Never let a proxy or browser keep this. It describes one moment.
            ("Cache-Control", "no-store"),
        ],
    )


def _install():
    """Wrap `Request._serve_db` once."""
    if getattr(Request._serve_db, _PATCH_FLAG, False):
        return

    original = Request._serve_db

    def _serve_db(self):
        try:
            return original(self)
        except PoolError:
            # WARNING, not exception: the traceback is always the same three
            # frames and says nothing a reader needs, while the RATE of this
            # line is the whole signal. Logged per request on purpose - a
            # sampled count would hide a short, total saturation, which is
            # exactly the shape of the 2026-09-03 outage.
            # THE LOG LINE MUST NEVER COST THE SHED. Reading the path is a
            # convenience; if anything about the half-built request refuses to
            # answer, the 503 still goes out. A shed that raised while
            # explaining itself would hand back the 500 it exists to prevent.
            try:
                path = getattr(getattr(self, "httprequest", None), "path", "?")
            except Exception:  # noqa: BLE001
                path = "?"
            _logger.warning(
                "Shedding load: the database connection pool is full, "
                "answering 503 for %s. Raise db_maxconn to cover the worker "
                "count, and Postgres max_connections above workers x "
                "db_maxconn.",
                path,
            )
            return _shed_response()

    setattr(_serve_db, _PATCH_FLAG, True)
    Request._serve_db = _serve_db
    _logger.info("load shed installed: pool exhaustion answers 503, not 500")


_install()
