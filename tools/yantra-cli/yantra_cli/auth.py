"""Keycloak grants the CLI uses: password (the local rig, and the staging smoke client), the device flow (RFC
8628: anywhere the password grant is off; the person approves in a browser, TOTP included) and refresh. The session
is a small JSON file with the tokens; the access token's claims are read without verification only to show who is
logged in."""

import base64
import hashlib
import json
import os
import secrets
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import httpx

from yantra_cli.config import Config


class AuthError(Exception):
    pass


@dataclass
class Session:
    username: str
    access_token: str
    refresh_token: str
    expires_at: float

    @property
    def claims(self) -> dict[str, Any]:
        payload = self.access_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return dict(json.loads(base64.urlsafe_b64decode(payload)))

    @property
    def worker_id(self) -> str:
        return str(self.claims.get("sub", ""))

    @property
    def roles(self) -> list[str]:
        return [str(r) for r in (self.claims.get("realm_access") or {}).get("roles", [])]

    def expiring(self, now: float | None = None) -> bool:
        return (now or time.time()) > self.expires_at - 30

    def save(self, path: Path) -> None:
        """Owner-only from the first byte: the refresh token is never readable by anyone else, even briefly."""
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(asdict(self)))

    @classmethod
    def load(cls, path: Path) -> "Session | None":
        """A missing or unreadable file means "not logged in"; it is never a crash."""
        if not path.exists():
            return None
        try:
            doc = json.loads(path.read_text())
            return cls(
                username=str(doc["username"]),
                access_token=str(doc["access_token"]),
                refresh_token=str(doc["refresh_token"]),
                expires_at=float(doc["expires_at"]),
            )
        except (ValueError, KeyError, TypeError, OSError):
            return None


DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"


def _client(cfg: Config) -> dict[str, str]:
    return {"client_id": cfg.client_id, **({"client_secret": cfg.client_secret} if cfg.client_secret else {})}


def _grant(http: httpx.Client, cfg: Config, data: dict[str, str], username: str) -> Session:
    try:
        r = http.post(cfg.token_url, data={**_client(cfg), **data}, timeout=10)
    except httpx.HTTPError as e:
        raise AuthError(f"keycloak unreachable at {cfg.keycloak_url}: {type(e).__name__}") from e
    if r.status_code != 200:
        detail = r.text[:200]
        if r.headers.get("content-type", "").startswith("application/json"):
            doc = r.json()
            detail = str(doc.get("error_description", doc.get("error", detail))) if isinstance(doc, dict) else detail
        raise AuthError(f"login refused ({r.status_code}): {detail}")
    doc = r.json()
    return Session(
        username=username,
        access_token=str(doc["access_token"]),
        refresh_token=str(doc.get("refresh_token", "")),
        expires_at=time.time() + float(doc.get("expires_in", 300)),
    )


def login(http: httpx.Client, cfg: Config, username: str, password: str) -> Session:
    return _grant(http, cfg, {"grant_type": "password", "username": username, "password": password}, username)


def refresh(http: httpx.Client, cfg: Config, session: Session) -> Session:
    data = {"grant_type": "refresh_token", "refresh_token": session.refresh_token}
    return _grant(http, cfg, data, session.username)


def device_login(
    http: httpx.Client,
    cfg: Config,
    say: Callable[[str], None],
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> Session:
    """RFC 8628: ask for a code, show where to approve it, poll until the person has, honouring `slow_down`. The
    app client requires PKCE on every flow, so the device request carries a challenge and the poll its verifier."""
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    pkce = {"code_challenge": challenge, "code_challenge_method": "S256"}
    try:
        r = http.post(cfg.device_url, data={**_client(cfg), **pkce}, timeout=10)
    except httpx.HTTPError as e:
        raise AuthError(f"keycloak unreachable at {cfg.keycloak_url}: {type(e).__name__}") from e
    if r.status_code != 200:
        raise AuthError(f"device login refused ({r.status_code}): {r.text[:200]}")
    start = r.json()
    where = start.get("verification_uri_complete") or start["verification_uri"]
    say(f"open {where} and confirm code {start['user_code']}")
    interval, deadline = float(start.get("interval", 5)), clock() + float(start.get("expires_in", 600))
    while clock() < deadline:
        sleep(interval)
        try:
            t = http.post(
                cfg.token_url,
                data={
                    **_client(cfg),
                    "grant_type": DEVICE_GRANT,
                    "device_code": start["device_code"],
                    "code_verifier": verifier,
                },
                timeout=10,
            )
        except httpx.HTTPError as e:
            raise AuthError(f"keycloak unreachable at {cfg.keycloak_url}: {type(e).__name__}") from e
        if t.status_code == 200:
            doc = t.json()
            session = Session("", str(doc["access_token"]), str(doc.get("refresh_token", "")), 0.0)
            session.username = str(session.claims.get("preferred_username", ""))
            session.expires_at = time.time() + float(doc.get("expires_in", 300))
            return session
        error = t.json().get("error", "") if t.headers.get("content-type", "").startswith("application/json") else ""
        if error == "slow_down":
            interval += 5
        elif error != "authorization_pending":
            raise AuthError(f"device login refused: {error or t.status_code}")
    raise AuthError("device login timed out: the code was not approved in time")
