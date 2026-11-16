"""Liveness and readiness, answered without touching the database.

WHY THIS EXISTS. There was no health route anywhere in the addon - 132
`@http.route` declarations and not one matching health/ready/live/ping. So an
orchestrator has nothing to probe except a real endpoint, and every real endpoint
takes a database connection.

WHY THAT IS THE WRONG THING TO PROBE, and it is the whole point of this file. A
probe that needs a connection FAILS EXACTLY WHEN THE POOL IS FULL - i.e. under
the load the platform is meant to survive. The orchestrator then reads
saturation as "this pod is dead", kills it, and moves its share of the traffic
onto the pods that are already saturated. That converts a slow minute into a
restart loop, and it is the documented failure mode behind the 2026-09-03
outage.

SO THERE ARE TWO ROUTES, AND THE DIFFERENCE MATTERS:

  /assessments_be/health   LIVENESS. Is this process running Python and able to
                           answer HTTP? No database, no ORM, no config read.
                           This is what a liveness probe must use: the only
                           correct reason to restart a pod is that the process
                           itself is wedged.

  /assessments_be/ready    READINESS. Can this pod usefully serve? Takes a
                           connection and runs `SELECT 1`. A readiness failure
                           takes the pod out of the load balancer WITHOUT
                           killing it, which is the right response to "the
                           database is unreachable" - the pod recovers on its
                           own when the database does.

`auth="none"` on both: a probe has no session and must not need one. `type="http"`
rather than the API's `json2`, because an orchestrator's probe is a plain GET and
`json2` only reads a JSON body. Neither route reveals anything - no version, no
database name, no counts - because both are reachable unauthenticated.
"""
import json
import logging

from odoo import http
from odoo.http import request

_logger = logging.getLogger(__name__)


class AssessmentsBeHealth(http.Controller):

    @staticmethod
    def _plain(payload, status=200):
        """A JSON body with no ORM involvement.

        `request.make_json_response` is avoided deliberately: it is a method on
        the request object, which exists here, but keeping this to
        `http.Response` makes it obvious that nothing on the path can touch the
        registry. `Cache-Control: no-store` because a cached health answer is
        worse than none.
        """
        return http.Response(
            json.dumps(payload),
            status=status,
            headers=[("Content-Type", "application/json"),
                     ("Cache-Control", "no-store")],
        )

    @http.route("/assessments_be/health", type="http", auth="none",
                methods=["GET"], csrf=False, save_session=False)
    def health(self, **kw):
        """LIVENESS. Answers 200 if this process can serve a request at all.

        THE HANDLER TOUCHES NO `request.env`, AND THAT IS NOT ENOUGH. An earlier
        version of this docstring claimed the route "cannot fail because the
        pool is full". That was measured and it is FALSE: Odoo takes the cursor
        in `_serve_db` (`http.py:2230`, `cr = registry.cursor(readonly=True)`)
        BEFORE any route is dispatched, so every request against a database
        borrows a connection whether or not its handler wants one. Under a load
        run that exhausted the pool at ~60 concurrent sittings, this route
        returned HTTP 500 - `psycopg2.pool.PoolError: The Connection Pool Is
        Full` - alongside the exam routes.

        WHY THAT MATTERS MORE THAN IT LOOKS. A liveness probe that fails under
        load is worse than no liveness probe: the orchestrator restarts healthy
        processes at exactly the moment they are busiest, and a capacity problem
        becomes an outage. So:

          * DO NOT wire container liveness to this route. Use a TCP check on the
            port, or terminate liveness at the reverse proxy, which is the only
            layer that can answer without Odoo taking a cursor.
          * DO use it for "is this build up and routing", which is what it is
            genuinely good for, and for readiness alongside `/ready` below.

        The right fix for the underlying condition is capacity, not a cleverer
        probe: size `db_maxconn` to the worker count and keep Postgres
        `max_connections` above workers x db_maxconn. See
        `docs/ETP_PLANS_AND_STRATEGY.md` §3.4.

        `save_session=False` so a probe every few seconds does not write a
        session file per call.
        """
        return self._plain({"status": "ok"})

    @http.route("/assessments_be/ready", type="http", auth="none",
                methods=["GET"], csrf=False, save_session=False)
    def ready(self, **kw):
        """READINESS. 200 when the database is reachable, 503 when it is not.

        Takes a connection ON PURPOSE - that is what is being tested - and
        `SELECT 1` is chosen because it touches no table, so it cannot be
        affected by a lock, a missing column or a mid-upgrade schema.

        A 503 here must NOT restart the pod. The distinction is the contract:
        liveness kills, readiness only removes from the load balancer, and a
        database that is briefly unreachable is not a reason to kill a healthy
        process. That is why the two routes are separate and why this one is not
        the liveness probe.
        """
        try:
            request.env.cr.execute("SELECT 1")
            request.env.cr.fetchone()
        except Exception as exc:  # noqa: BLE001 - a probe reports, never raises
            # WARNING, not exception(): under saturation this fires on every
            # probe, and a traceback per probe is a log flood that buries the
            # cause. The class name is the actionable part.
            _logger.warning("readiness probe failed: %s: %s",
                            type(exc).__name__, exc)
            return self._plain({"status": "unavailable"}, status=503)
        return self._plain({"status": "ready"})
