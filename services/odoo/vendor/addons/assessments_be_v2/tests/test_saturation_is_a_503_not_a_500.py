"""Saturation answers 503 + Retry-After, and the probes answer without the DB.

TWO GAPS, one theme: under load the platform could not tell a client - or an
orchestrator - the difference between "busy" and "broken".

G7. Every unexpected exception became `fail("server_error", ..., status=500)`
(`api/common.py`). A full connection pool raises
`psycopg2.pool.PoolError("The Connection Pool Is Full")`, so saturation was
reported as a server error: on 2026-09-03 that was 35,362 pool-full events read
as 30.68% 500s. A 500 is not retryable, so the client's own retry ladder
(`api_client.dart:424-442`, which already honours `Retry-After`) had nothing
correct to honour and gave up on requests that would have succeeded moments
later.

G8. There was NO health route in the addon - 132 route declarations, none
matching health/ready/live/ping. So a probe has to hit a real endpoint, and every
real endpoint borrows a connection. That probe therefore fails exactly when the
pool is full, the orchestrator reads saturation as death, restarts the pod, and
its traffic lands on pods that are already saturated. Overload becomes a restart
loop.

WHAT IS ASSERTED, and what is deliberately not: these tests pin the CONTRACT -
which status, which code, which header, and that liveness touches no database.
They do not simulate a real 1,200-candidate load; that is the load harness
(SNo 151-153) and it is a separate piece of work.
"""
import json
from unittest.mock import patch

from psycopg2.pool import PoolError

from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger

from ..controllers.api.common import RETRY_AFTER_SECONDS


@tagged("-at_install", "post_install")
class TestSaturationIsA503NotA500(TransactionCase):

    # ── G7: the shed ──────────────────────────────────────────────────

    def _run_guarded(self, raising):
        """Run `raising` through the real `api_endpoint` decorator.

        Exercising the decorator itself rather than a route, because the branch
        under test is in the decorator and every route inherits it - so this
        covers all 132 rather than one.
        """
        from ..controllers.api import common as api_common

        captured = {}

        class _Req:
            def __init__(self, env):
                self.env = env
                self.params = {}

            def make_json_response(self, payload, headers=None, status=200):
                captured["headers"] = headers
                captured["status"] = status
                return {"__status": status, "__headers": headers, **payload}

        fake = _Req(self.env)
        with patch.object(api_common, "request", fake):
            guarded = api_common.api_endpoint(raising)
            response = guarded()
        return response, captured

    @staticmethod
    def _code(response):
        error = (response or {}).get("error")
        return error.get("code") if isinstance(error, dict) else None

    def test_a_full_pool_answers_503_and_not_500(self):
        """THE HEADLINE. Saturation is a refusal, not a fault."""
        def pool_is_full():
            raise PoolError("The Connection Pool Is Full")

        response, _ = self._run_guarded(pool_is_full)

        self.assertEqual(
            response.get("__status"), 503,
            "a full connection pool still answers 500, so a client cannot tell "
            "'retry shortly' from 'this endpoint is broken'")
        self.assertEqual(self._code(response), "busy")

    def test_the_503_carries_a_retry_after_header(self):
        """The header is the part a client acts on.

        `api_client.dart` reads `Retry-After` off the response; a hint in the
        JSON body would have to be parsed by code that does not look there. So
        it must be a real header, not only a payload field.
        """
        def pool_is_full():
            raise PoolError("The Connection Pool Is Full")

        response, captured = self._run_guarded(pool_is_full)

        headers = dict(captured.get("headers") or [])
        self.assertIn(
            "Retry-After", headers,
            "the 503 sets no Retry-After header, so the client's retry ladder "
            "has nothing to honour and falls back to its own guess")
        self.assertEqual(headers["Retry-After"], str(RETRY_AFTER_SECONDS))
        # And in the body too, for a caller that would rather read JSON.
        self.assertEqual(response.get("retry_after"), RETRY_AFTER_SECONDS)

    def test_the_message_says_the_request_was_not_processed(self):
        """A retryable refusal has to promise idempotence, or a client dare not
        repeat a write."""
        def pool_is_full():
            raise PoolError("The Connection Pool Is Full")

        response, _ = self._run_guarded(pool_is_full)
        message = ((response.get("error") or {}).get("message") or "").lower()
        self.assertIn("not", message)
        self.assertIn("capacity", message)

    @mute_logger("odoo.addons.assessments_be_v2.controllers.api.common")
    def test_an_ordinary_bug_is_still_a_500(self):
        """THE OTHER HALF, and the one that keeps this honest: a real fault must
        not be relabelled as busy. A blanket 503 would 'pass' the tests above
        while hiding every genuine error behind a retry.
        """
        def a_real_bug():
            raise ValueError("something is actually wrong")

        response, _ = self._run_guarded(a_real_bug)

        self.assertEqual(response.get("__status"), 500)
        self.assertEqual(self._code(response), "server_error")

    def test_a_serialization_failure_still_propagates(self):
        """Unchanged behaviour, re-pinned because this branch sits right beside
        the new one.

        A serialization failure must REACH Odoo's `service.model.retrying`,
        which replays the whole request. Converting it to an envelope defeats
        that retry and leaves the cursor dead - the note in `api_endpoint` says
        so, and adding a branch above it is exactly how that would regress.
        """
        from psycopg2.errors import SerializationFailure

        def serialization_failure():
            raise SerializationFailure("could not serialize access")

        with self.assertRaises(SerializationFailure):
            self._run_guarded(serialization_failure)

    # ── G8: the probes ────────────────────────────────────────────────

    def test_liveness_never_touches_the_database(self):
        """THE POINT OF THE HEALTH ROUTE.

        A probe that borrows a connection fails when the pool is full, which is
        when the pod is busiest and least deserving of a restart. This asserts
        the property directly: with `request` set to an object that has no `env`
        at all, the handler must still answer 200. Any DB access would raise
        AttributeError instead.
        """
        from ..controllers import health as health_mod

        class _NoEnvRequest:
            """Deliberately has no `env`. Reaching for one is the failure."""

            params = {}

            def __getattr__(self, name):
                raise AssertionError(
                    "the liveness probe touched request.%s - it must answer "
                    "without the database, or it will fail exactly when the "
                    "pool is full" % name)

        controller = health_mod.AssessmentsBeHealth()
        with patch.object(health_mod, "request", _NoEnvRequest()):
            response = controller.health()

        self.assertEqual(response.status_code, 200)
        self.assertIn(b"ok", response.data)

    def test_liveness_is_not_cacheable(self):
        """A cached health answer is worse than none - it reports the state of
        whichever pod answered first, for as long as the cache lives."""
        from ..controllers import health as health_mod

        controller = health_mod.AssessmentsBeHealth()
        with patch.object(health_mod, "request", object()):
            response = controller.health()

        self.assertIn("no-store",
                      response.headers.get("Cache-Control", ""))

    def test_readiness_reports_a_reachable_database(self):
        from ..controllers import health as health_mod

        controller = health_mod.AssessmentsBeHealth()

        class _Req:
            def __init__(self, env):
                self.env = env

        with patch.object(health_mod, "request", _Req(self.env)):
            response = controller.ready()

        self.assertEqual(response.status_code, 200)
        self.assertIn(b"ready", response.data)

    def test_readiness_answers_503_when_the_database_is_unreachable(self):
        """And it must not raise. A probe that 500s with a traceback tells the
        orchestrator nothing it can act on, and floods the log."""
        from ..controllers import health as health_mod

        controller = health_mod.AssessmentsBeHealth()

        class _DeadCursor:
            def execute(self, *a, **k):
                raise PoolError("The Connection Pool Is Full")

        class _Env:
            cr = _DeadCursor()

        class _Req:
            env = _Env()

        with patch.object(health_mod, "request", _Req()):
            response = controller.ready()

        self.assertEqual(
            response.status_code, 503,
            "readiness must report unavailable rather than raising")
        self.assertIn(b"unavailable", response.data)

    def test_neither_probe_leaks_anything(self):
        """Both are `auth="none"`, so anyone on the network can read them. They
        must not name the database, the version, or any count."""
        from ..controllers import health as health_mod

        controller = health_mod.AssessmentsBeHealth()

        class _Req:
            def __init__(self, env):
                self.env = env

        with patch.object(health_mod, "request", object()):
            live = controller.health().data.decode()
        with patch.object(health_mod, "request", _Req(self.env)):
            ready = controller.ready().data.decode()

        for body in (live, ready):
            self.assertNotIn(self.env.cr.dbname, body)
            self.assertNotIn("19.0", body, "no version in a public probe")
            # Small by construction: a status word and nothing else.
            self.assertLess(len(body), 64)


@tagged("-at_install", "post_install")
class TestSaturationBeforeDispatchIsAlsoA503(TransactionCase):
    """The shed that covers the case the endpoint decorator cannot reach.

    MEASURED, NOT ASSUMED. A write ladder on 2026-09-09 saturated the pool and
    every failure came back HTTP 500 with this traceback:

        odoo/http.py:2810  in __call__   response = request._serve_db()
        odoo/http.py:2230  in _serve_db  cr = registry.cursor(readonly=True)
        psycopg2.pool.PoolError: The Connection Pool Is Full

    The cursor is taken to MATCH the route, so there is no controller yet and
    nothing for `api_endpoint`'s handler to wrap. The tests above pin the
    in-endpoint shed; these pin the one before dispatch.
    """

    def test_a_full_pool_becomes_a_503_with_retry_after(self):
        from odoo.http import Request

        from ..controllers import load_shed

        def _raises(_self):
            raise PoolError("The Connection Pool Is Full")

        # A stand-in with the attribute the log line reads. The shed also
        # survives one without it - see the test below - but the ordinary path
        # is a real request, so that is what this asserts against.
        class _Req:
            httprequest = type("H", (), {"path": "/api/v1/exam/x/answer"})()

        with patch.object(Request, "_serve_db", _raises):
            # Re-wrap the raising stand-in, which is what the real install
            # does to the real method.
            wrapped = Request._serve_db
            try:
                load_shed._install()
                response = Request._serve_db(_Req())
            finally:
                Request._serve_db = wrapped

        self.assertEqual(
            response.status_code, 503,
            "pool exhaustion before dispatch still answers 500, which tells a "
            "client the request was wrong and invites a retry that lengthens "
            "the queue")
        self.assertEqual(response.headers.get("Retry-After"),
                         str(load_shed.RETRY_AFTER_SECONDS))
        self.assertEqual(response.headers.get("Cache-Control"), "no-store")
        body = json.loads(response.get_data(as_text=True))
        self.assertEqual((body.get("error") or {}).get("code"), "busy")

    def test_the_shed_survives_a_request_it_cannot_describe(self):
        """The 503 must not depend on the log line succeeding.

        Saturation happens while the request is still being built, so the
        object the shed is handed is not guaranteed to answer for itself. An
        exception raised while composing the warning would surface as the 500
        this whole file exists to prevent - and it would do so only under load,
        which is the worst time to find out.
        """
        from odoo.http import Request

        from ..controllers import load_shed

        def _raises(_self):
            raise PoolError("The Connection Pool Is Full")

        with patch.object(Request, "_serve_db", _raises):
            wrapped = Request._serve_db
            try:
                load_shed._install()
                response = Request._serve_db(object())
            finally:
                Request._serve_db = wrapped

        self.assertEqual(response.status_code, 503)

    def test_a_healthy_request_passes_through_untouched(self):
        """The wrapper must be invisible when the pool is fine."""
        from odoo.http import Request

        from ..controllers import load_shed

        sentinel = object()

        def _fine(_self):
            return sentinel

        with patch.object(Request, "_serve_db", _fine):
            wrapped = Request._serve_db
            try:
                load_shed._install()
                self.assertIs(Request._serve_db(object()), sentinel)
            finally:
                Request._serve_db = wrapped

    def test_any_other_failure_still_propagates(self):
        """THE GUARD ON THE GUARD.

        A shed that swallowed every exception would turn real bugs into a
        soothing 503 and hide them from the log for as long as the deployment
        ran. Only `PoolError` is capacity; everything else is a defect and must
        reach Odoo's own handler.
        """
        from odoo.http import Request

        from ..controllers import load_shed

        def _explodes(_self):
            raise ValueError("a real bug, not capacity")

        with patch.object(Request, "_serve_db", _explodes):
            wrapped = Request._serve_db
            try:
                load_shed._install()
                with self.assertRaises(ValueError):
                    Request._serve_db(object())
            finally:
                Request._serve_db = wrapped

    def test_installing_twice_does_not_stack_wrappers(self):
        """A registry reload re-imports the package; wrappers must not nest."""
        from odoo.http import Request

        from ..controllers import load_shed

        before = Request._serve_db
        load_shed._install()
        self.assertIs(
            Request._serve_db, before,
            "a second install wrapped the wrapper, so every request would "
            "carry one more frame per reload")
