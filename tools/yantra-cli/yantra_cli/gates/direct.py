"""Calls to the work and money services past the gateway, carrying the identity headers the gateway would set.
The gates need hundreds of workers that have no Keycloak account, so they speak to the services directly. The
rig publishes those ports only with the development overlay:

  docker compose -f deployment/local/compose.yaml -f deployment/local/compose.dev.yaml up -d work money
"""

import uuid
from dataclasses import dataclass
from typing import Any

import httpx

from yantra_cli.gates import GateAborted


class DirectError(Exception):
    def __init__(self, status: int, body: Any) -> None:
        super().__init__(f"{status} {body}")
        self.status = status
        self.body = body if isinstance(body, dict) else {}
        self.code = str(self.body.get("code", ""))


@dataclass(frozen=True)
class Actor:
    """Someone the services trust by header: a subject id and the realm roles the gateway would forward."""

    id: str
    roles: str

    @classmethod
    def new(cls, roles: str) -> "Actor":
        return cls(str(uuid.uuid4()), roles)

    def headers(self) -> dict[str, str]:
        return {"X-Worker-Id": self.id, "X-Role": self.roles, "Idempotency-Key": str(uuid.uuid4())}


@dataclass
class Direct:
    http: httpx.Client
    work_url: str = "http://localhost:8081"
    money_url: str = "http://localhost:8082"

    def call(self, actor: Actor, method: str, path: str, json: Any = None, **params: Any) -> Any:
        base = self.money_url if path.startswith("/v1/payout/") else self.work_url
        query = {k: v for k, v in params.items() if v is not None} or None
        try:
            r = self.http.request(method, base + path, json=json, params=query, headers=actor.headers())
        except httpx.ConnectError as e:
            raise GateAborted(
                f"{base} is not reachable: start the rig with deployment/local/compose.dev.yaml ({e})"
            ) from e
        if r.status_code >= 400:
            try:
                body = r.json()
            except ValueError:
                body = r.text
            raise DirectError(r.status_code, body)
        return r.json() if r.content else None

    def get(self, actor: Actor, path: str, **params: Any) -> Any:
        return self.call(actor, "GET", path, **params)

    def post(self, actor: Actor, path: str, json: Any = None, **params: Any) -> Any:
        return self.call(actor, "POST", path, json if json is not None else {}, **params)

    def put(self, actor: Actor, path: str, json: Any = None) -> Any:
        return self.call(actor, "PUT", path, json if json is not None else {})
