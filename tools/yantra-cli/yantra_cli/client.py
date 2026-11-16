"""One call to the gateway: bearer token, an idempotency key on every mutation, a refresh on 401, a bounded
wait on 429 and 503 (Retry-After is honoured), and the error envelope turned into one exception."""

import logging
import time
import uuid
from collections.abc import Callable
from typing import Any

import httpx

from yantra_cli.auth import Session, refresh
from yantra_cli.config import Config

log = logging.getLogger("yantra.cli")
MAX_RETRY_WAIT = 30.0
MAX_ATTEMPTS = 4


class GatewayError(Exception):
    def __init__(self, status: int, code: str, message: str, request_id: str, body: Any = None) -> None:
        super().__init__(f"{status} {code}: {message} (request {request_id})")
        self.status, self.code, self.message, self.request_id, self.body = status, code, message, request_id, body


class Gateway:
    def __init__(
        self,
        cfg: Config,
        session: Session,
        http: httpx.Client | None = None,
        sleep: Callable[[float], None] = time.sleep,
        on_session: Callable[[Session], None] | None = None,
    ) -> None:
        self.cfg = cfg
        self.session = session
        self.http = http or httpx.Client(timeout=httpx.Timeout(20.0, connect=5.0))
        self.sleep = sleep
        self.on_session = on_session or (lambda s: None)

    def _refresh(self) -> None:
        self.session = refresh(self.http, self.cfg, self.session)
        self.on_session(self.session)

    def call(
        self,
        method: str,
        path: str,
        json: Any = None,
        params: dict[str, Any] | None = None,
        key: str | None = None,
        content: bytes | None = None,
        content_type: str = "text/csv",
    ) -> Any:
        if self.session.expiring():
            self._refresh()
        key = key or (str(uuid.uuid4()) if method in ("POST", "PUT", "PATCH", "DELETE") else None)
        refreshed = False
        for attempt in range(1, MAX_ATTEMPTS + 1):
            headers = {"Authorization": f"Bearer {self.session.access_token}"}
            if content is not None:
                headers["Content-Type"] = content_type
            if key:
                headers["Idempotency-Key"] = key
            try:
                r = self.http.request(
                    method, self.cfg.gateway_url + path, json=json, params=params, headers=headers, content=content
                )
            except httpx.HTTPError as e:
                raise GatewayError(0, "unreachable", f"gateway unreachable: {type(e).__name__}", "-") from e
            if r.status_code == 401 and not refreshed:
                refreshed = True
                self._refresh()
                continue
            # 429 and an in-flight twin are safe to repeat with the same key. A 503 is repeated only for a read: the
            # gateway frees the key on an upstream failure, and a create that did commit would run twice.
            repeatable = r.status_code == 429 or (r.status_code == 409 and _code(r) == "request_in_flight")
            if repeatable or (r.status_code == 503 and key is None):
                if attempt == MAX_ATTEMPTS:
                    raise _error(r)
                wait = min(MAX_RETRY_WAIT, _retry_after(r))
                log.warning("gateway asked to wait status=%s seconds=%s attempt=%d", r.status_code, wait, attempt)
                self.sleep(wait)
                continue
            if r.status_code >= 400:
                raise _error(r)
            if r.headers.get("content-type", "").startswith("application/json"):
                return r.json()
            return r.text
        raise AssertionError("unreachable")  # pragma: no cover

    def get(self, path: str, **params: Any) -> Any:
        return self.call("GET", path, params={k: v for k, v in params.items() if v is not None} or None)

    def post(self, path: str, json: Any = None, **params: Any) -> Any:
        return self.call("POST", path, json=json, params=params or None)

    def put(self, path: str, json: Any = None) -> Any:
        return self.call("PUT", path, json=json)


def _code(r: httpx.Response) -> str:
    try:
        doc = r.json()
    except ValueError:
        return ""
    return str(doc.get("code", "")) if isinstance(doc, dict) else ""


def _retry_after(r: httpx.Response) -> float:
    """Seconds to wait; a date-shaped or missing header means one second."""
    try:
        return max(0.0, float(r.headers.get("Retry-After", "1")))
    except ValueError:
        return 1.0


def _error(r: httpx.Response) -> GatewayError:
    try:
        doc = r.json()
    except ValueError:
        return GatewayError(r.status_code, "http_error", r.text[:200], "-")
    if not isinstance(doc, dict):
        return GatewayError(r.status_code, "http_error", str(doc)[:200], "-")
    return GatewayError(
        r.status_code, str(doc.get("code", "error")), str(doc.get("message", "")), str(doc.get("request_id", "-")), doc
    )
