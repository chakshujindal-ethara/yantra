"""Gate `security`: the edge refuses what it must, through the gateway with real Keycloak tokens. Cross-worker
reads, a client token on worker routes and on another organisation's project, missing and forged tokens, a reused
idempotency key with a different body, an admin approving money, a client claiming a review, an unsigned
webhook, a tampered storage link, a released claim's link, and the rate limit."""

import uuid
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any

import httpx

from yantra_cli.auth import login
from yantra_cli.client import Gateway, GatewayError
from yantra_cli.config import Config
from yantra_cli.gates import GateResult

SCHEMA = {"type": "object", "required": ["audio"], "properties": {"audio": {"type": "string"}}}
CLIP = b"RIFF security gate clip"


def tamper(url: str) -> str:
    """Flip the last character of the signature in a presigned link."""
    last = url[-1]
    return url[:-1] + ("0" if last != "0" else "1")


def forge(token: str) -> str:
    """The same token with its payload changed by one character: the signature no longer matches."""
    head, payload, sig = token.split(".")
    flipped = payload[:-1] + ("A" if payload[-1] != "A" else "B")
    return f"{head}.{flipped}.{sig}"


@dataclass
class SecurityGate:
    cfg: Config
    password: str
    http: httpx.Client
    rate_limit_per_minute: int = 600
    users: dict[str, Gateway] = field(default_factory=dict)
    checks: dict[str, str] = field(default_factory=dict)
    failed: list[str] = field(default_factory=list)

    def as_user(self, name: str) -> Gateway:
        if name not in self.users:
            self.users[name] = Gateway(self.cfg, login(self.http, self.cfg, name, self.password), self.http)
        return self.users[name]

    def expect(self, name: str, allowed: tuple[int, ...], act: Callable[[], Any]) -> None:
        """Run `act`; the check passes when it ends in one of the `allowed` statuses (2xx when it returns)."""
        try:
            got = act()
            status = got if isinstance(got, int) else 200
        except GatewayError as e:
            status = e.status
        self.checks[name] = f"{status} (want {'/'.join(map(str, allowed))})"
        if status not in allowed:
            self.failed.append(name)

    def verdict(self, name: str, ok: bool, observed: str) -> None:
        """A check that is not one status code: what was seen, and whether it is what the edge must do."""
        self.checks[name] = observed
        if not ok:
            self.failed.append(name)

    def raw(self, method: str, path: str, token: str | None, **kw: Any) -> httpx.Response:
        headers = dict(kw.pop("headers", {}))
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        return self.http.request(method, self.cfg.gateway_url + path, headers=headers, **kw)

    def run(self) -> GateResult:
        ops, w1, w2 = self.as_user("ops1"), self.as_user("worker1"), self.as_user("worker2")
        client, admin = self.as_user("client1"), self.as_user("admin1")
        project, batch, claim = self._media_claim(ops, w1)
        unit = claim["unit_id"]
        self.expect("cross_worker_unit", (404,), lambda: w2.get(f"/v1/units/{unit}"))
        self.expect("cross_worker_media_link", (404,), lambda: w2.get(f"/v1/units/{unit}/payload-url"))
        link = w1.get(f"/v1/units/{unit}/payload-url")["url"]
        self.expect("media_link_works", (200,), lambda: self.http.get(link).status_code)
        self.expect("tampered_media_link", (403,), lambda: self.http.get(tamper(link)).status_code)
        w1.post(f"/v1/claims/{claim['id']}/release")
        self.expect("released_claim_media_link", (404,), lambda: w1.get(f"/v1/units/{unit}/payload-url"))
        self.expect("client_on_worker_route", (403,), lambda: client.get("/v1/batches"))
        self.expect("client_other_org_project", (403, 404), lambda: client.get(f"/v1/client/projects/{project}"))
        self.expect("client_claims_review", (403,), lambda: client.post("/v1/quality/reviews/claim"))
        self.expect("admin_approves_window", (403,), lambda: admin.post(f"/v1/payout/windows/{uuid.uuid4()}/approve"))
        self.expect("no_token", (401,), lambda: self.raw("GET", "/v1/batches", None).status_code)
        self.expect("garbage_token", (401,), lambda: self.raw("GET", "/v1/batches", "not-a-jwt").status_code)
        forged = forge(w1.session.access_token)
        self.expect("forged_token", (401,), lambda: self.raw("GET", "/v1/batches", forged).status_code)
        self._idempotency(w1)
        webhook = self.raw(
            "POST",
            "/v1/payout/webhooks/razorpayx",
            None,
            json={"event": "payout.processed", "payload": {}},
            headers={"X-Razorpay-Signature": "0" * 64, "X-Razorpay-Event-Id": f"evt_gate_{uuid.uuid4().hex[:8]}"},
        )
        # 401: the signature is checked; 404: this rig has no webhook secret, so the path does not exist at all
        self.expect("unsigned_webhook", (401, 404), lambda: webhook.status_code)
        self._rate_limit()
        figures: dict[str, Any] = {"checks": len(self.checks), "failed": len(self.failed), **self.checks}
        notes = [f"{n}: {self.checks[n]}" for n in self.failed]
        return GateResult("security", not self.failed, figures, notes)

    def _media_claim(self, ops: Gateway, worker: Gateway) -> tuple[str, str, Any]:
        """A project of its own (no client organisation) with one stored clip, and worker1 holding its unit."""
        tag = uuid.uuid4().hex[:6]
        project = ops.post(
            "/v1/projects", {"name": f"System check · security {tag}", "currency": "INR", "payload_schema": SCHEMA}
        )
        batch = ops.post(
            f"/v1/projects/{project['id']}/batches", {"title": "System check", "unit_pay": "1", "unit_price": "2"}
        )
        ups = ops.post(
            f"/v1/batches/{batch['id']}/payload-uploads",
            {"files": [{"name": f"gate-{tag}.wav", "content_type": "audio/wav", "size_bytes": len(CLIP)}]},
        )
        up = ups["uploads"][0]
        self.http.put(up["url"], content=CLIP, headers=up["headers"]).raise_for_status()
        lines = [{"external_ref": f"sec-{tag}", "payload": {"audio": up["ref"]}}]
        ops.post(f"/v1/batches/{batch['id']}/units/import", {"lines": lines}, dry_run="false")
        ops.post(f"/v1/batches/{batch['id']}/publish", {})
        claim = worker.post(f"/v1/batches/{batch['id']}/claims")
        return str(project["id"]), str(batch["id"]), claim

    def _idempotency(self, worker: Gateway) -> None:
        key = f"gate-{uuid.uuid4()}"
        body = {"category": "other", "title": "Launch gate check", "body": "Idempotency replay check.", "screen": "-"}
        token = worker.session.access_token
        first = self.raw("POST", "/v1/notify/tickets", token, json=body, headers={"Idempotency-Key": key})
        again = self.raw("POST", "/v1/notify/tickets", token, json=body, headers={"Idempotency-Key": key})
        other = self.raw(
            "POST", "/v1/notify/tickets", token, json={**body, "title": "Changed"}, headers={"Idempotency-Key": key}
        )
        same = first.status_code == again.status_code == 201 and first.json().get("id") == again.json().get("id")
        self.verdict("idempotent_replay", same, f"{again.status_code}, same ticket: {same}")
        mismatch = other.status_code == 422 and other.json().get("code") == "idempotency_mismatch"
        self.verdict(
            "idempotency_key_reused_with_other_body", mismatch, f"{other.status_code} {other.json().get('code')}"
        )

    def _rate_limit(self) -> None:
        """worker5 sends one minute's allowance and a little more; the edge answers 429 with Retry-After."""
        token = self.as_user("worker5").session.access_token
        burst = self.rate_limit_per_minute + 30

        def hit(_: int) -> httpx.Response:
            return self.raw("GET", "/v1/notify/inbox/unread-count", token)

        with ThreadPoolExecutor(max_workers=32) as pool:
            answers = list(pool.map(hit, range(burst)))
        limited = [r for r in answers if r.status_code == 429]
        with_retry = bool(limited) and all(r.headers.get("Retry-After") for r in limited)
        self.verdict("rate_limit_429_with_retry_after", with_retry, f"{len(limited)} of {burst} answered 429")
