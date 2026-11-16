"""A scripted gateway and Keycloak behind httpx.MockTransport: no network, every branch of the client reachable."""

import base64
import json
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

import httpx
import pytest

from yantra_cli.config import Config

WORKER = "00000000-0000-4000-8000-000000000001"
OPS = "00000000-0000-4000-8000-00000000a001"


def fake_jwt(sub: str, roles: list[str]) -> str:
    def part(doc: dict[str, Any]) -> str:
        return base64.urlsafe_b64encode(json.dumps(doc).encode()).decode().rstrip("=")

    return part({"alg": "none"}) + "." + part({"sub": sub, "realm_access": {"roles": roles}}) + ".sig"


class Backend:
    """Routes `METHOD path` to a handler; records every request. Keycloak lives at /realms/..."""

    def __init__(self) -> None:
        self.routes: dict[str, Callable[[httpx.Request], httpx.Response]] = {}
        self.requests: list[httpx.Request] = []
        self.tokens_issued = 0
        self.on("POST /realms/yantra/protocol/openid-connect/token", self.token)

    def on(
        self, key: str, handler: Callable[[httpx.Request], httpx.Response] | httpx.Response | dict[str, Any]
    ) -> None:
        if isinstance(handler, httpx.Response):
            self.routes[key] = lambda r, resp=handler: resp  # type: ignore[misc]
        elif isinstance(handler, dict):
            self.routes[key] = lambda r, doc=handler: httpx.Response(200, json=doc)  # type: ignore[misc]
        else:
            self.routes[key] = handler

    def token(self, request: httpx.Request) -> httpx.Response:
        form = dict(x.split("=", 1) for x in request.content.decode().split("&"))
        self.tokens_issued += 1
        if form.get("grant_type") == "password" and form.get("password") != "yantra":
            return httpx.Response(401, json={"error": "invalid_grant", "error_description": "Invalid user credentials"})
        sub, roles = (OPS, ["ops"]) if form.get("username", "").startswith("ops") else (WORKER, ["worker"])
        if form.get("grant_type") == "refresh_token":
            sub = WORKER
            roles = ["worker"]
        return httpx.Response(
            200,
            json={"access_token": fake_jwt(sub, roles), "refresh_token": "r" * 20, "expires_in": 300},
        )

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        key = f"{request.method} {request.url.path}"
        if key not in self.routes:
            return httpx.Response(404, json={"detail": "Not Found"})
        return self.routes[key](request)

    @property
    def client(self) -> httpx.Client:
        return httpx.Client(transport=httpx.MockTransport(self.handle))


@pytest.fixture
def backend() -> Backend:
    return Backend()


@pytest.fixture
def env(tmp_path: Path) -> dict[str, str]:
    return {
        "YANTRA_GATEWAY_URL": "http://gw",
        "YANTRA_KEYCLOAK_URL": "http://kc",
        "YANTRA_SESSION_FILE": str(tmp_path / "session.json"),
        "HOME": str(tmp_path),
    }


@pytest.fixture
def cfg(env: dict[str, str]) -> Config:
    return Config.from_env(env)


def expired_session(path: Path, sub: str = WORKER) -> None:
    doc = {
        "username": "worker1",
        "access_token": fake_jwt(sub, ["worker"]),
        "refresh_token": "r" * 20,
        "expires_at": time.time() - 1,
    }
    path.write_text(json.dumps(doc))


def fresh_session(path: Path, sub: str = WORKER, roles: list[str] | None = None) -> None:
    doc = {
        "username": "worker1",
        "access_token": fake_jwt(sub, roles or ["worker"]),
        "refresh_token": "r" * 20,
        "expires_at": time.time() + 300,
    }
    path.write_text(json.dumps(doc))


def new_id() -> str:
    return str(uuid.uuid4())
