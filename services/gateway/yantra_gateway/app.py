"""The gateway process. Every request: body cap, a per-address limit before any work, the bearer token
(verified off the event loop), the per-caller limit, idempotency on mutations (bound to the body), then one upstream
call with the caller's identity in the headers the services trust (`X-Worker-Id`, `X-Role`, `X-Name`). A service
never sees a token.

The per-address limit keys on `request.client.host`, never on a header the client sends: behind a load balancer,
uvicorn's `FORWARDED_ALLOW_IPS` (the proxies' addresses) is what makes that the real client address."""

import asyncio
import hashlib
import logging
import random
import re
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from urllib.parse import quote

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from redis.exceptions import RedisError

from yantra_common.boot import boot
from yantra_common.deps import role_header
from yantra_common.errors import Invalid
from yantra_common.http import install_boundary, install_security_headers
from yantra_common.metrics import install_metrics, mark_upstream
from yantra_common.people import clean_name
from yantra_common.tracing import install_tracing
from yantra_gateway.auth import Caller, Verifier, bearer_token
from yantra_gateway.config import GatewaySettings, gateway_settings
from yantra_gateway.store import MISMATCH, Store, Stored

log = logging.getLogger("yantra.gateway")
MUTATIONS = frozenset({"POST", "PUT", "PATCH", "DELETE"})
IDEMPOTENCY_KEY = re.compile(r"^[A-Za-z0-9._:-]{8,200}$")
# only these client headers reach a service; identity and request id are set here, never passed through
FORWARDED_HEADERS = frozenset({"content-type", "accept", "accept-language", "user-agent"})
NOT_STORED = frozenset({408, 429})
# The only routes a caller without a token may reach: a payout rail's webhook. POST only, no identity, no
# idempotency key (money dedupes on the rail's event id), a small body, and only the rail's own headers forwarded.
# The HMAC signature is checked by money, which holds the secret; the gateway stays secret-free.
WEBHOOKS = frozenset({"/v1/payout/webhooks/razorpayx"})
WEBHOOK_MAX_BYTES = 64 * 1024
WEBHOOK_HEADERS = ("x-razorpay-signature", "x-razorpay-event-id")

Upstreams = dict[str, httpx.AsyncClient]


def route(path: str) -> str:
    return "money" if path.startswith("/v1/payout/") else "work"


def clean_path(path: str) -> str:
    """The path as the service will see it: no empty or dot segments, so `/v1/../ready` cannot reach a service."""
    if any(s in ("", ".", "..") for s in path.split("/")[1:]):
        raise Invalid("path must not contain empty or dot segments")
    return path


def identity_headers(caller: Caller, request_id: str) -> dict[str, str]:
    """Always carries `X-Role`, an empty string when the caller holds no known role: a service never has to wonder
    whether a missing header meant "no role" or "not via the gateway". `X-Name` is the token's display name,
    cleaned, capped and percent-encoded (a header is ASCII; a name may be Devanagari); absent when there is none.
    `X-Email` (percent-encoded) and `X-Email-Verified` (`true` or `false`) carry the token's email for the assess
    module, which provisions the worker in the Assessment engine; both absent when the token has none. A client can
    never set any of these: only `FORWARDED_HEADERS` pass through from the caller."""
    headers = {"X-Worker-Id": str(caller.worker_id), "X-Role": role_header(caller.roles), "X-Request-Id": request_id}
    name = clean_name(caller.name)
    if name is not None:
        headers["X-Name"] = quote(name, safe="")
    if caller.email:
        headers["X-Email"] = quote(caller.email.strip()[:254], safe="@")
        headers["X-Email-Verified"] = "true" if caller.email_verified else "false"
    return headers


async def forward(
    client: httpx.AsyncClient, request: Request, path: str, headers: dict[str, str], body: bytes
) -> httpx.Response:
    """One upstream call, with one retry only when the request never reached the service (a connect failure).
    A timeout after sending is not retried: the service may have committed, and not every mutation dedupes on
    its key. Backoff with full jitter so retries never line up."""
    passthrough = {k: v for k, v in request.headers.items() if k.lower() in FORWARDED_HEADERS}
    for attempt in (1, 2):
        try:
            return await client.request(
                request.method, path, params=request.url.query, content=body, headers={**passthrough, **headers}
            )
        except (httpx.ConnectError, httpx.ConnectTimeout) as e:
            if attempt == 2:
                raise
            log.warning("upstream connect failed, retrying path=%s error=%s", path, type(e).__name__)
            await asyncio.sleep(random.uniform(0, 0.25))  # noqa: S311
    raise AssertionError("unreachable")  # pragma: no cover


def too_many(request_id: str, retry_after: int) -> JSONResponse:
    return JSONResponse(
        status_code=429,
        content={"code": "rate_limited", "message": "too many requests", "request_id": request_id},
        headers={"Retry-After": str(retry_after)},
    )


def unavailable(code: str, request_id: str) -> JSONResponse:
    return JSONResponse(
        status_code=503,
        content={"code": code, "message": "try again shortly", "request_id": request_id},
        headers={"Retry-After": "2"},
    )


def create_app(
    verifier: Verifier,
    store: Store,
    upstreams: Upstreams,
    max_body_bytes: int = 8 << 20,
    allowed_origins: list[str] | None = None,
    hsts: bool = False,
) -> FastAPI:
    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        await asyncio.to_thread(verifier.warm)  # a failure is logged; /ready says so until keys arrive
        yield
        await store.close()
        for client in upstreams.values():
            await client.aclose()

    app = FastAPI(title="Yantra gateway", version="0.1.0", lifespan=lifespan)
    install_boundary(app, max_body_bytes)
    install_security_headers(app, hsts)
    install_metrics(app, "gateway", normalize=True)  # inside CORS, outside the boundary: it sees the final status
    if allowed_origins:  # the browser app; an exact list, never "*", so a token is only ever sent from our origin.
        # Added last, so it is outermost: even a 413 or a 500 from the boundary carries the CORS headers.
        app.add_middleware(
            CORSMiddleware,
            allow_origins=allowed_origins,
            allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
            allow_headers=["Authorization", "Content-Type", "Idempotency-Key", "X-Request-Id"],
            # Date is not CORS-safelisted: the app reads it for its server-clock offset (timed sittings, claims).
            # uvicorn stamps it on every response at the server layer, proxied ones included.
            expose_headers=["Retry-After", "X-Request-Id", "Date"],
            max_age=600,
        )

    @app.get("/health", include_in_schema=False)
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/ready", include_in_schema=False)
    async def ready() -> JSONResponse:
        """Ready when Redis answers and the identity provider's keys have been fetched at least once. Keys that
        were not there at start (the identity provider came up later) are fetched again here, so readiness
        recovers on its own instead of waiting for a first caller."""
        try:
            await store.redis.ping()
        except RedisError as e:
            log.error("ready: redis unavailable error=%s", type(e).__name__)
            return JSONResponse(status_code=503, content={"status": "redis_unavailable"})
        if not verifier.loaded and not await asyncio.to_thread(verifier.warm):
            return JSONResponse(status_code=503, content={"status": "jwks_not_loaded"})
        return JSONResponse(content={"status": "ok"})

    @app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"], include_in_schema=False)
    async def proxy(request: Request, path: str) -> Response:
        request_id = request.state.request_id
        target = clean_path(request.url.path)
        try:
            return await _proxy(request, target, request_id)
        except RedisError as e:
            log.error("redis unavailable request_id=%s error=%s", request_id, type(e).__name__)
            return unavailable("gateway_unavailable", request_id)

    async def _proxy(request: Request, target: str, request_id: str) -> Response:
        address = request.client.host if request.client else "unknown"
        if await store.allow(f"ip:{address}", store.address_limit):
            return too_many(request_id, 60)
        if request.method == "POST" and target in WEBHOOKS:
            return await _webhook(request, target, request_id)
        caller = await asyncio.to_thread(verifier.verify, bearer_token(request.headers.get("Authorization")))
        wait = await store.allow(f"w:{caller.worker_id}")
        if wait:
            log.warning("rate limited worker_id=%s path=%s request_id=%s", caller.worker_id, target, request_id)
            return too_many(request_id, wait)
        headers = identity_headers(caller, request_id)
        body = await request.body()
        name, body_hash = None, ""
        if request.method in MUTATIONS:
            key = request.headers.get("Idempotency-Key", "")
            if not IDEMPOTENCY_KEY.match(key):
                raise Invalid("Idempotency-Key header required on every mutation (8 to 200 characters)")
            headers["Idempotency-Key"] = key
            scope = f"{target}?{request.url.query}" if request.url.query else target
            name = Store.name(str(caller.worker_id), request.method, scope, key)
            body_hash = hashlib.sha256(body).hexdigest()
            claimed = await store.begin(name, body_hash)
            if claimed is MISMATCH:
                return JSONResponse(
                    status_code=422,
                    content={
                        "code": "idempotency_mismatch",
                        "message": "this Idempotency-Key was already used with a different body",
                        "request_id": request_id,
                    },
                )
            if isinstance(claimed, Stored):
                return Response(content=claimed.body, status_code=claimed.status, media_type=claimed.content_type)
            if claimed is False:
                return JSONResponse(
                    status_code=409,
                    content={
                        "code": "request_in_flight",
                        "message": "the same request is still running",
                        "request_id": request_id,
                    },
                )
        stored = False
        try:
            upstream = await forward(upstreams[route(target)], request, target, headers, body)
            mark_upstream(request)
            content_type = upstream.headers.get("content-type", "application/octet-stream")
            if name is not None and upstream.status_code < 500 and upstream.status_code not in NOT_STORED:
                stored = await store.finish(
                    name, Stored(upstream.status_code, upstream.content, content_type), body_hash
                )
        except httpx.HTTPError as e:
            log.error("upstream failed route=%s request_id=%s error=%s", route(target), request_id, type(e).__name__)
            return unavailable("upstream_unavailable", request_id)
        finally:
            if name is not None and not stored:
                await store.release(name)
        passthrough = {"Retry-After": upstream.headers["Retry-After"]} if "Retry-After" in upstream.headers else {}
        return Response(
            content=upstream.content, status_code=upstream.status_code, media_type=content_type, headers=passthrough
        )

    async def _webhook(request: Request, target: str, request_id: str) -> Response:
        body = await request.body()
        if len(body) > WEBHOOK_MAX_BYTES:
            return JSONResponse(
                status_code=413,
                content={"code": "payload_too_large", "message": "webhook body too large", "request_id": request_id},
            )
        headers = {"X-Role": "", "X-Request-Id": request_id}
        headers |= {name: request.headers[name] for name in WEBHOOK_HEADERS if name in request.headers}
        try:
            upstream = await forward(upstreams[route(target)], request, target, headers, body)
            mark_upstream(request)
        except httpx.HTTPError as e:
            log.error("webhook upstream failed request_id=%s error=%s", request_id, type(e).__name__)
            return unavailable("upstream_unavailable", request_id)
        return Response(
            content=upstream.content,
            status_code=upstream.status_code,
            media_type=upstream.headers.get("content-type", "application/json"),
        )

    return app


def default_app(s: GatewaySettings | None = None) -> FastAPI:
    """Production wiring: Keycloak JWKS, Redis with short timeouts, one HTTP client per upstream."""
    from redis.asyncio import Redis

    boot("gateway")
    s = s or gateway_settings()
    verifier = Verifier(str(s.keycloak_issuer), s.audience, s.jwks_url)
    redis = Redis.from_url(s.redis_url, socket_connect_timeout=1, socket_timeout=1)
    store = Store(redis, s.rate_limit_per_minute, s.idempotency_ttl_seconds)
    timeout = httpx.Timeout(s.upstream_timeout_seconds, connect=3.0)
    upstreams: Upstreams = {
        "work": httpx.AsyncClient(base_url=str(s.work_url), timeout=timeout),
        "money": httpx.AsyncClient(base_url=str(s.money_url), timeout=timeout),
    }
    app = create_app(verifier, store, upstreams, s.max_body_bytes, s.allowed_origins, hsts=s.env != "local")
    install_tracing(app, "gateway", clients=list(upstreams.values()))
    return app
