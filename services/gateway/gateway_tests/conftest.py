"""Gateway tests: a locally generated RSA key stands in for Keycloak; Redis is the local one; the upstreams are
small FastAPI apps that echo what the gateway sent them. One TestClient context per test keeps one event loop,
which the async Redis pool and the ASGI upstream clients are bound to."""

import os
import time
import uuid
from collections.abc import Iterator
from typing import Any

import httpx
import jwt
import pytest
import redis as redis_sync
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient
from redis.asyncio import Redis

from yantra_gateway.app import create_app
from yantra_gateway.auth import Verifier
from yantra_gateway.store import Store

ISSUER = "https://keycloak.test/realms/yantra"
AUDIENCE = "yantra"
# parallel runs (several agents, CI shards) take their own Redis database with YANTRA_TEST_REDIS_DB
REDIS_URL = f"redis://localhost:6390/{os.environ.get('YANTRA_TEST_REDIS_DB', '9')}"

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
PUBLIC = KEY.public_key()
PRIVATE_PEM = KEY.private_bytes(
    serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
)


class TestVerifier(Verifier):
    """The same verification, with the signing key from the test pair instead of a JWKS fetch."""

    __test__ = False

    def __init__(self) -> None:
        super().__init__(ISSUER, AUDIENCE, "https://keycloak.test/certs")

    def signing_key(self, token: str) -> Any:
        return PUBLIC

    def warm(self) -> bool:  # no JWKS endpoint in tests: the key is in hand
        self.loaded = True
        return True


def token(worker: uuid.UUID, roles: tuple[str, ...] = (), **overrides: Any) -> str:
    now = int(time.time())
    claims = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": str(worker),
        "iat": now,
        "exp": now + 300,
        "jti": str(uuid.uuid4()),
        "typ": "Bearer",  # Keycloak sets it on every access token; the gateway refuses a token without it
        "realm_access": {"roles": list(roles)},
        **overrides,
    }
    return jwt.encode(claims, PRIVATE_PEM, algorithm="RS256")


def auth(worker: uuid.UUID, roles: tuple[str, ...] = ()) -> dict[str, str]:
    return {"Authorization": f"Bearer {token(worker, roles)}"}


def echo_app(name: str) -> FastAPI:
    app = FastAPI()
    calls: list[dict[str, Any]] = []
    app.state.calls = calls

    @app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT"])
    async def echo(request: Request, path: str) -> Any:
        body = await request.body()
        calls.append({"path": path, "headers": dict(request.headers), "body": body.decode()})
        if path == "big":
            return JSONResponse(content={"blob": "x" * 70_000})
        if path == "conflict":
            return JSONResponse(
                status_code=409, content={"code": "x", "n": len(calls)}, media_type="application/problem+json"
            )
        if path == "fail":
            return JSONResponse(status_code=500, content={"code": "internal_error"})
        if path == "limited":
            return JSONResponse(status_code=429, content={"code": "rate_limited"}, headers={"Retry-After": "7"})
        return {
            "upstream": name,
            "path": path,
            "worker": request.headers.get("x-worker-id"),
            "role": request.headers.get("x-role"),
            "n": len(calls),
        }

    return app


@pytest.fixture
def kv() -> Iterator[redis_sync.Redis]:
    """A synchronous client for flushing and asserting; the app gets its own async client."""
    r = redis_sync.Redis.from_url(REDIS_URL)
    r.flushdb()
    yield r
    r.close()


def build_gateway(upstreams: dict[str, httpx.AsyncClient], limit: int = 5, address_multiplier: int = 20) -> FastAPI:
    store = Store(
        Redis.from_url(REDIS_URL), limit_per_minute=limit, idempotency_ttl=60, address_multiplier=address_multiplier
    )
    return create_app(TestVerifier(), store, upstreams, max_body_bytes=1000)


@pytest.fixture
def gateway(kv) -> Iterator[TestClient]:
    work, money = echo_app("work"), echo_app("money")
    upstreams = {
        "work": httpx.AsyncClient(transport=httpx.ASGITransport(app=work), base_url="http://work"),
        "money": httpx.AsyncClient(transport=httpx.ASGITransport(app=money), base_url="http://money"),
    }
    app = build_gateway(upstreams)
    app.state.work, app.state.money = work, money
    with TestClient(app, raise_server_exceptions=False) as client:
        yield client
