"""The launch gates against scripted services: a work and money stand-in for the load gates (claims, reviews,
the pay window, the deliverable) and a gateway with Keycloak for the security gate. No network."""

import hashlib
import json
import subprocess
import threading
import uuid
from argparse import Namespace
from collections.abc import Sequence
from typing import Any

import httpx
import pytest

from yantra_cli.__main__ import main
from yantra_cli.gates import GateAborted, GateResult, table
from yantra_cli.gates import runner as gates
from yantra_cli.gates.delivery import DeliveryGate
from yantra_cli.gates.direct import Actor, Direct, DirectError
from yantra_cli.gates.money import MoneyParity
from yantra_cli.gates.restore import RestoreDrill
from yantra_cli.gates.security import SecurityGate, forge, tamper
from yantra_cli.gates.storm import ClaimStorm, percentile
from yantra_cli.gates.ui import UiGate

from .conftest import fake_jwt

WORK, MONEY, STORE = "http://work.test", "http://money.test", "http://store.test"


def err(status: int, code: str, **extra: Any) -> httpx.Response:
    return httpx.Response(status, json={"code": code, "message": code, "request_id": "r", **extra})


class Services:
    """Market, quality and payout, just deep enough for the gates: units move available, claimed, submitted, then
    accepted or back to their author; every fifth accept is sampled for audit; payout books every canonical verdict."""

    def __init__(self, sample_every: int = 5) -> None:
        self.lock = threading.Lock()
        self.sample_every = sample_every
        self.units: dict[str, dict[str, Any]] = {}
        self.claims: dict[str, str] = {}
        self.tasks: dict[str, dict[str, Any]] = {}
        self.accepts = 0
        self.earnings: dict[str, float] = {}
        self.costs = {"pay": 0.0, "review": 0.0, "audit": 0.0, "accepted": 0, "judged": 0}
        self.batch_id = ""
        self.close_conflicts = 1
        self.fail: dict[str, httpx.Response] = {}  # "METHOD path-suffix" -> a scripted answer, used once
        self.line_status = "paid"
        self.balanced = True
        self.margin_skew = 0.0
        self.accounts = "verified"

    def handle(self, r: httpx.Request) -> httpx.Response:
        with self.lock:
            for key, resp in list(self.fail.items()):
                method, suffix = key.split(" ", 1)
                if r.method == method and r.url.path.endswith(suffix):
                    del self.fail[key]
                    return resp
            return self._route(r)

    def _route(self, r: httpx.Request) -> httpx.Response:
        path, m = r.url.path, r.method
        who = r.headers.get("X-Worker-Id", "")
        body = json.loads(r.content) if r.content else {}
        if r.url.host == "store.test":
            return httpx.Response(200, content=self._deliverable(path))
        if path == "/v1/projects":
            return httpx.Response(201, json={"id": str(uuid.uuid4())})
        if path.endswith("/batches") and m == "POST":
            self.batch_id = str(uuid.uuid4())
            return httpx.Response(201, json={"id": self.batch_id})
        if path.endswith("/units/import"):
            for line in body["lines"]:
                self.units[str(uuid.uuid4())] = {"status": "available", "author": None, "ref": line["external_ref"]}
            return httpx.Response(200, json={})
        if path.endswith("/publish") or path.startswith("/v1/workers/"):
            return httpx.Response(200, json={})
        if path.endswith("/claims") and m == "POST":
            return self._claim(who)
        if path.endswith("/submission"):
            unit = self.claims[path.split("/")[3]]
            self.units[unit]["status"] = "submitted"
            self.tasks[str(uuid.uuid4())] = {"unit_id": unit, "status": "pending", "author": who, "reviewer": None}
            return httpx.Response(201, json={})
        if path == f"/v1/batches/{self.batch_id}" and m == "GET":
            counts = {"submitted": sum(1 for u in self.units.values() if u["status"] == "submitted")}
            return httpx.Response(200, json={"units": counts, "live_claims": 0})
        if path == "/v1/quality/reviews/claim":
            return self._take(who, r.url.params.get("kind", "review"))
        if path.endswith("/review"):
            return self._record(path.split("/")[4], who, body)
        if path.endswith("/manifest"):
            open_units = sum(1 for u in self.units.values() if u["status"] != "accepted")
            if open_units:
                return err(409, "batch_held", held={"available": open_units})
            return httpx.Response(200, json={"accepted_units": len(self.units), "digest": "d1"})
        if path.endswith("/deliverable"):
            sha = hashlib.sha256(self._deliverable("/units.jsonl")).hexdigest()
            jsonl = {"url": f"{STORE}/units.jsonl", "sha256": sha}
            return httpx.Response(200, json={"digest": "d1", "jsonl": jsonl, "manifest": {"url": f"{STORE}/m.json"}})
        return self._money(path, m, who)

    def _money(self, path: str, m: str, who: str) -> httpx.Response:
        if path == "/v1/payout/accounts/me":
            return httpx.Response(200, json={"status": self.accounts if m == "GET" else "verifying"})
        if path == "/v1/payout/margin":
            c = self.costs
            invoice = 25 * c["accepted"]
            row = {
                "batch_id": self.batch_id,
                "units_accepted": c["accepted"],
                "invoice": f"{invoice:.2f}",
                "cost_pay": f"{c['pay']:.2f}",
                "cost_review": f"{c['review']:.2f}",
                "cost_audit": f"{c['audit']:.2f}",
                "margin": f"{invoice - c['pay'] - c['review'] - c['audit'] + self.margin_skew:.2f}",
            }
            return httpx.Response(200, json=[{"batch_id": "other", "units_accepted": 0}, row])
        if path == "/v1/payout/windows/close":
            if self.close_conflicts:
                self.close_conflicts -= 1
                return err(409, "window_closed")
            return httpx.Response(201, json={"id": "w1"})
        if path.endswith("/lines"):
            lines = [
                {"worker_id": w, "gross": f"{v:.2f}", "status": self.line_status} for w, v in self.earnings.items()
            ]
            return httpx.Response(200, json=[*lines, {"worker_id": "someone-else", "gross": "5.00", "status": "paid"}])
        if path.endswith("/reconcile"):
            delta = "0.00" if self.balanced else "1.00"
            return httpx.Response(200, json={"balanced": self.balanced, "delta": delta, "delta_rail": "0.00"})
        if path.endswith("/approve") or path.endswith("/pay"):
            return httpx.Response(200, json={})
        return err(404, "not_found")

    def _claim(self, who: str) -> httpx.Response:
        for uid, u in self.units.items():
            back_to_me = u["status"] == "needs_edits" and u["author"] == who
            if u["status"] == "available" or back_to_me:
                u["status"], u["author"] = "claimed", who
                cid = str(uuid.uuid4())
                self.claims[cid] = uid
                return httpx.Response(201, json={"id": cid, "unit_id": uid})
        return err(404, "not_found")

    def _take(self, who: str, kind: str) -> httpx.Response:
        want = "pending" if kind == "review" else "audit_pending"
        for tid, t in self.tasks.items():
            if t["status"] == want and t["author"] != who and t["reviewer"] != who:
                t["status"] = "claimed" if kind == "review" else "audit_claimed"
                if kind == "review":
                    t["reviewer"] = who
                else:
                    t["auditor"] = who
                return httpx.Response(201, json={"id": tid, "unit_id": t["unit_id"]})
        return err(404, "not_found")

    def _record(self, tid: str, who: str, body: dict[str, Any]) -> httpx.Response:
        t = self.tasks[tid]
        unit = self.units[t["unit_id"]]
        if body["verdict"] == "needs_edits":
            t["status"], unit["status"] = "done", "needs_edits"
            self._book(t, accepted=False)
            return httpx.Response(200, json={"unit_id": t["unit_id"], "status": "done", "canonical_verdict": None})
        if t["status"] == "claimed":
            self.accepts += 1
            if self.accepts % self.sample_every == 0:
                t["status"] = "audit_pending"
                return httpx.Response(200, json={"unit_id": t["unit_id"], "status": "audit_pending"})
        t["status"], unit["status"] = "done", "accepted"
        self._book(t, accepted=True)
        return httpx.Response(200, json={"unit_id": t["unit_id"], "status": "done", "canonical_verdict": "accept"})

    def _book(self, t: dict[str, Any], accepted: bool) -> None:
        c = self.costs
        c["judged"] += 1
        c["review"] += 2
        self.earnings[t["reviewer"]] = self.earnings.get(t["reviewer"], 0) + 2
        if t.get("auditor"):
            c["audit"] += 2
            self.earnings[t["auditor"]] = self.earnings.get(t["auditor"], 0) + 2
        if accepted:
            c["accepted"] += 1
            c["pay"] += 10
            self.earnings[t["author"]] = self.earnings.get(t["author"], 0) + 10

    def _deliverable(self, path: str) -> bytes:
        if path.endswith(".json"):
            return json.dumps({"digest": "d1"}).encode()
        return "".join(json.dumps({"unit": u}) + "\n" for u in self.units).encode()

    def direct(self) -> Direct:
        return Direct(httpx.Client(transport=httpx.MockTransport(self.handle)), WORK, MONEY)


# ---------- the shared pieces


def test_percentile_is_nearest_rank_and_zero_when_empty():
    assert percentile([], 99) == 0.0
    assert percentile([5.0, 1.0, 3.0], 50) == 3.0
    assert percentile([float(i) for i in range(1, 101)], 99) == 99.0


def test_the_table_prints_one_row_per_gate_with_its_notes():
    out = table([GateResult("ui", True, {"a": 1}), GateResult("security", False, {}, ["x failed"])])
    assert out.splitlines() == ["PASS  ui             a=1", "FAIL  security       ", "      - x failed"]
    assert GateResult("ui", False).as_dict() == {"gate": "ui", "result": "FAIL", "notes": []}


def test_the_direct_client_sends_identity_routes_payout_to_money_and_reads_errors():
    seen: list[httpx.Request] = []

    def handle(r: httpx.Request) -> httpx.Response:
        seen.append(r)
        if r.url.path == "/v1/plain":
            return httpx.Response(500, text="boom")
        if r.url.path == "/v1/empty":
            return httpx.Response(204)
        return httpx.Response(200, json={"ok": True})

    api = Direct(httpx.Client(transport=httpx.MockTransport(handle)), WORK, MONEY)
    ops = Actor.new("ops")
    assert api.get(ops, "/v1/payout/windows", status=None) == {"ok": True}
    assert api.put(ops, "/v1/workers/x") == {"ok": True}
    assert api.post(ops, "/v1/empty") is None
    with pytest.raises(DirectError) as e:
        api.get(ops, "/v1/plain")
    assert e.value.status == 500 and e.value.code == "" and e.value.body == {}
    assert seen[0].url.host == "money.test" and seen[1].url.host == "work.test"
    assert seen[0].headers["X-Role"] == "ops" and seen[0].headers["X-Worker-Id"] == ops.id


def test_an_unreachable_service_aborts_with_the_overlay_to_start():
    def refuse(r: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused", request=r)

    api = Direct(httpx.Client(transport=httpx.MockTransport(refuse)), WORK, MONEY)
    with pytest.raises(GateAborted, match="compose.dev.yaml"):
        api.get(Actor.new("ops"), "/v1/projects")


# ---------- claim-storm


def test_the_storm_passes_when_every_unit_is_claimed_once_and_fast():
    rig = Services()
    result = ClaimStorm(rig.direct(), workers=4, units=9, concurrency=4).run()
    assert result.passed, result
    assert result.figures["claimed_once"] == 9 and result.figures["double_claims"] == 0
    assert result.figures["units_submitted"] == 9 and result.figures["errors"] == {}


def test_the_storm_fails_on_a_slow_p99_and_counts_claim_and_submit_errors():
    rig = Services()
    rig.fail["POST /claims"] = err(500, "boom")
    rig.fail["POST /submission"] = err(409, "claim_expired")
    result = ClaimStorm(rig.direct(), workers=3, units=5, concurrency=3, p99_ms=0.0).run()
    assert not result.passed
    assert result.figures["errors"] == {"claim 500 boom": 1, "submit 409 claim_expired": 1}
    assert "over the 0 ms target" in result.notes[0]


# ---------- money-parity


def parity(rig: Services, **kw: Any) -> MoneyParity:
    kw.setdefault("sleep", lambda s: None)
    return MoneyParity(rig.direct(), workers=4, units=10, concurrency=4, **kw)


def test_money_parity_passes_when_earnings_lines_payouts_and_margin_agree():
    rig = Services()
    result = parity(rig).run()
    assert result.passed, result
    f = result.figures
    assert f["earnings"] == f["window_lines"] == f["paid_by_rail"]
    assert f["units_accepted"] == 10 and f["audits"] == 2 and f["margin_matches"] is True


def test_money_parity_fails_on_an_unpaid_line_an_unbalanced_run_or_a_margin_off_by_a_rupee():
    rig = Services()
    rig.line_status, rig.balanced, rig.margin_skew = "held", False, 1.0
    rig.fail["POST /claims"] = err(500, "boom")
    rig.fail["POST /v1/quality/reviews/claim"] = err(503, "busy")
    result = parity(rig).run()
    assert not result.passed
    assert set(result.figures["lines_not_paid"]) == {"held"}  # how many depends on who drew work first
    assert result.figures["reconciliation_balanced"] is False and result.figures["margin_matches"] is False
    assert result.figures["errors"] == {"claim 500": 1, "audit claim 503 busy": 1}
    assert "did not settle" in result.notes[0]


def test_money_parity_aborts_when_reviews_stall_or_no_window_is_free():
    rig = Services()
    stalled = parity(rig, wait_seconds=0.0)
    with pytest.raises(GateAborted, match="canonical accept"):
        stalled.run()
    rig = Services()
    rig.close_conflicts = 10_000
    with pytest.raises(GateAborted, match="no free pay window"):
        parity(rig).run()
    rig = Services()
    rig.fail["POST /windows/close"] = err(500, "boom")
    with pytest.raises(DirectError):
        parity(rig).run()


def test_money_parity_waits_for_accounts_and_gives_up_after_its_deadline():
    rig = Services()
    rig.accounts = "verifying"
    gate = parity(rig, wait_seconds=0.0)
    gate._review = lambda *a: None
    with pytest.raises(GateAborted, match="bank accounts verified"):
        gate.run()
    naps: list[float] = []
    patient = parity(rig, sleep=naps.append)
    answers = iter([False, True])
    patient.until("x", lambda: next(answers))
    assert naps == [2.0]


# ---------- delivery-gate


def test_the_delivery_gate_holds_then_delivers_a_matching_deliverable():
    rig = Services(sample_every=2)
    api = rig.direct()
    result = DeliveryGate(api, api.http, sleep=lambda s: None).run()
    assert result.passed, result
    assert result.figures["held_status"] == 409 and result.figures["held_counts"] == {"available": 1}
    assert result.figures["deliverable_lines"] == 3 and result.figures["sha256_matches"] is True


def test_the_delivery_gate_fails_when_the_manifest_is_not_held_and_aborts_when_work_never_comes():
    rig = Services()
    rig.fail["GET /manifest"] = httpx.Response(200, json={"accepted_units": 3, "digest": "d1"})
    api = rig.direct()
    assert DeliveryGate(api, api.http, sleep=lambda s: None).run().figures["held_status"] == 200
    gate = DeliveryGate(Services().direct(), api.http, wait_seconds=0.0, sleep=lambda s: None)
    with pytest.raises(GateAborted, match="a review task"):
        gate._next(Actor.new("reviewer"), "b", "review")
    with pytest.raises(GateAborted, match="sent back"):
        gate._until_claimable(Actor.new("worker"), "b")


def test_the_delivery_gate_lets_unexpected_answers_through():
    rig = Services()
    gate = DeliveryGate(rig.direct(), rig.direct().http, sleep=lambda s: None)
    for key, call in (
        ("POST /v1/quality/reviews/claim", lambda: gate._next(Actor.new("r"), "b", "review")),
        ("POST /claims", lambda: gate._until_claimable(Actor.new("w"), "b")),
        ("GET /manifest", lambda: gate._held(Actor.new("o"), "b")),
    ):
        rig.fail[key] = err(500, "boom")
        with pytest.raises(DirectError):
            call()
    rig.fail["GET /manifest"] = err(500, "boom")
    with pytest.raises(DirectError):
        gate._manifest(Actor.new("o"), "b")


# ---------- security


class Edge:
    """A gateway and Keycloak that answer the security gate's probes the way the rig does."""

    def __init__(self, broken: set[str] | None = None) -> None:
        self.broken = broken or set()
        self.tickets: dict[str, str] = {}
        self.calls = 0

    def handle(self, r: httpx.Request) -> httpx.Response:
        path = r.url.path
        if path.endswith("/openid-connect/token"):
            form = dict(x.split("=", 1) for x in r.content.decode().split("&"))
            return httpx.Response(200, json={"access_token": fake_jwt(form["username"], []), "expires_in": 300})
        if r.url.host == "store.test":
            return httpx.Response(200 if str(r.url).endswith("good") else 403)
        auth = r.headers.get("Authorization", "")
        if not auth.startswith("Bearer ey"):
            return err(401, "unauthorized")
        try:
            who = json.loads(_b64(auth.split(".")[1]))["sub"]
        except ValueError:
            return err(401, "unauthorized")  # a payload changed after signing no longer decodes
        return self._as(who, r)

    def _as(self, who: str, r: httpx.Request) -> httpx.Response:
        path, m = r.url.path, r.method
        if path == "/v1/notify/inbox/unread-count":
            self.calls += 1
            if self.calls > 600 and "ratelimit" not in self.broken:
                return httpx.Response(429, headers={"Retry-After": "30"}, json={"code": "rate_limited"})
            return httpx.Response(200, json={"unread": 0})
        if path == "/v1/notify/tickets":
            return self._ticket(r)
        if who == "worker2" and path.startswith("/v1/units/"):
            return httpx.Response(200, json={}) if "cross" in self.broken else err(404, "not_found")
        if path.endswith("/payload-url"):
            if r.url.params.get("released") or getattr(self, "released", False):
                return err(404, "not_found")
            return httpx.Response(200, json={"url": f"{STORE}/clip?sig=good"})
        if path.endswith("/release"):
            self.released = True
            return httpx.Response(200, json={"status": "released"})
        if who == "client1" or (who == "admin1" and path.endswith("/approve")):
            return err(403, "forbidden")
        if path.endswith("/payload-uploads"):
            up = {"url": f"{STORE}/put-good", "headers": {}, "ref": "s3://yantra/k"}
            return httpx.Response(200, json={"uploads": [up]})
        if path.endswith("/claims"):
            return httpx.Response(201, json={"id": "c1", "unit_id": "u1"})
        return httpx.Response(201 if m == "POST" else 200, json={"id": str(uuid.uuid4())})

    def _ticket(self, r: httpx.Request) -> httpx.Response:
        key = r.headers["Idempotency-Key"]
        if key in self.tickets and self.tickets[key] != r.content.decode():
            return err(422, "idempotency_mismatch")
        self.tickets[key] = r.content.decode()
        return httpx.Response(201, json={"id": key})


def _b64(s: str) -> bytes:
    import base64

    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def security(edge: Edge, cfg: Any) -> SecurityGate:
    return SecurityGate(cfg, "yantra", httpx.Client(transport=httpx.MockTransport(edge.handle)), 600)


def test_the_security_gate_passes_when_the_edge_refuses_everything_it_must(cfg):
    result = security(Edge(), cfg).run()
    assert result.passed, result.notes
    assert result.figures["failed"] == 0
    assert result.figures["rate_limit_429_with_retry_after"] == "30 of 630 answered 429"


def test_the_security_gate_names_every_check_that_let_something_through(cfg):
    result = security(Edge(broken={"cross", "ratelimit"}), cfg).run()
    assert not result.passed
    failed = {n.split(":")[0] for n in result.notes}
    assert failed == {"cross_worker_unit", "cross_worker_media_link", "rate_limit_429_with_retry_after"}


def test_tamper_and_forge_change_exactly_one_character():
    assert tamper("http://x?sig=abc1") == "http://x?sig=abc0"
    assert tamper("http://x?sig=abc0") == "http://x?sig=abc1"
    assert forge("h.payloadZ.s") == "h.payloadA.s"
    assert forge("h.payloadA.s") == "h.payloadB.s"


def test_a_replayed_key_that_returns_a_new_ticket_fails_the_idempotency_check(cfg):
    edge = Edge()
    gate = security(edge, cfg)
    edge.tickets = {}
    original = edge._ticket

    def fresh_each_time(r: httpx.Request) -> httpx.Response:
        resp = original(r)
        return httpx.Response(201, json={"id": str(uuid.uuid4())}) if resp.status_code == 201 else resp

    edge._ticket = fresh_each_time
    gate._idempotency(gate.as_user("worker1"))
    assert gate.failed == ["idempotent_replay"]


def test_a_mismatch_answered_with_success_fails_the_reuse_check(cfg):
    edge = Edge()
    edge._ticket = lambda r: httpx.Response(201, json={"id": "same"})
    gate = security(edge, cfg)
    gate._idempotency(gate.as_user("worker1"))
    assert gate.failed == ["idempotency_key_reused_with_other_body"]


# ---------- restore-drill


class Scripts:
    def __init__(self, backup_rc: int = 0, restore_rc: int = 0, smoke: str = "result PASS") -> None:
        self.backup_rc, self.restore_rc, self.smoke = backup_rc, restore_rc, smoke
        self.calls: list[list[str]] = []

    def __call__(self, argv: Sequence[str]) -> subprocess.CompletedProcess[str]:
        self.calls.append(list(argv))
        if argv[0].endswith("backup.sh"):
            return subprocess.CompletedProcess(argv, self.backup_rc, "== nats\nbackups/T1\n", "disk full\n")
        return subprocess.CompletedProcess(argv, self.restore_rc, f"restored in 9s\n{self.smoke}\n", "")


def clock(*ticks: float) -> Any:
    it = iter(ticks)
    return lambda: next(it)


def test_the_restore_drill_times_backup_and_restore_against_the_targets(tmp_path):
    scripts = Scripts()
    result = RestoreDrill(tmp_path, scripts, clock(0.0, 3.0, 3.0, 60.0)).run()
    assert result.passed
    assert result.figures["backup_s"] == 3.0 and result.figures["restore_and_smoke_s"] == 57.0
    assert scripts.calls[1] == [str(tmp_path / "deployment/scripts/restore.sh"), "backups/T1"]


def test_the_restore_drill_fails_on_a_failed_backup_restore_or_smoke(tmp_path):
    failed = RestoreDrill(tmp_path, Scripts(backup_rc=1), clock(0.0, 1.0)).run()
    assert not failed.passed and failed.notes == ["disk full"]
    broken = RestoreDrill(tmp_path, Scripts(restore_rc=2, smoke=""), clock(0.0, 1.0, 1.0, 2.0)).run()
    assert not broken.passed and broken.notes == ["restored in 9s"]
    assert broken.figures["smoke_after_restore"] == "FAIL"
    slow = RestoreDrill(tmp_path, Scripts(), clock(0.0, 1.0, 1.0, 5 * 3600.0)).run()
    assert not slow.passed


def test_an_empty_script_output_still_reads():
    from yantra_cli.gates.restore import _tail

    assert _tail("   \n") == "no output"


# ---------- ui


def ui_client(headers: dict[str, str], config: int = 200) -> httpx.Client:
    def handle(r: httpx.Request) -> httpx.Response:
        if r.url.path == "/config.json":
            return httpx.Response(config, json={"gateway_url": "http://gw"})
        return httpx.Response(200, headers=headers, text="<html>")

    return httpx.Client(transport=httpx.MockTransport(handle))


GOOD_HEADERS = {
    "x-content-type-options": "nosniff",
    "x-frame-options": "DENY",
    "referrer-policy": "no-referrer",
    "content-security-policy": "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; frame-ancestors 'none'",
}


def test_the_ui_gate_checks_headers_csp_config_and_counts_the_evidence(tmp_path):
    (tmp_path / "m3-home.png").write_bytes(b"x")
    (tmp_path / "m4-csp.png").write_bytes(b"x")
    result = UiGate(ui_client(GOOD_HEADERS), "http://app", tmp_path).run()
    assert result.passed and result.figures["screenshots"] == {"m1": 0, "m2": 0, "m3": 1, "m4": 1}


def test_the_ui_gate_fails_without_headers_or_config_and_says_when_evidence_is_missing(tmp_path):
    weak = {**GOOD_HEADERS, "content-security-policy": "default-src 'self'; script-src 'unsafe-eval'"}
    result = UiGate(ui_client(weak, config=404), "http://app", tmp_path / "none").run()
    assert not result.passed and result.figures["csp_scripts_self_only"] is False
    assert result.figures["config_gateway"] is None and "no screenshots" in result.notes[0]


# ---------- the runner and the command


def args(name: str, **kw: Any) -> Namespace:
    base = {
        "name": name,
        "workers": None,
        "units": None,
        "concurrency": None,
        "quick": False,
        "yes": False,
        "with_restore": False,
        "work_url": WORK,
        "money_url": MONEY,
        "app_url": "http://app",
        "password": "yantra",
    }
    return Namespace(**{**base, **kw})


def test_the_runner_refuses_the_restore_drill_without_yes_and_turns_aborts_into_fail_rows(cfg):
    refused = gates.run(args("restore-drill"), cfg, httpx.Client())
    assert refused[0].notes == ["restore-drill replaces the rig's data with a fresh backup of itself: add --yes"]
    assert gates.selected(args("all", with_restore=True)) == (
        "--with-restore replaces the rig's data with a fresh backup of itself: add --yes"
    )
    assert gates.selected(args("all", with_restore=True, yes=True))[-1] == "restore-drill"
    assert "restore-drill" not in gates.selected(args("all"))

    def refuse(r: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused", request=r)

    rows = gates.run(args("claim-storm"), cfg, httpx.Client(transport=httpx.MockTransport(refuse)))
    assert not rows[0].passed and "aborted" in rows[0].notes[0]


def test_the_runner_builds_every_gate_with_its_sizes(cfg, monkeypatch):
    http = httpx.Client()
    storm = gates.build("claim-storm", args("claim-storm", workers=7, units=9, concurrency=3), cfg, http)
    assert (storm.__self__.workers, storm.__self__.units, storm.__self__.concurrency) == (7, 9, 3)
    quick = gates.build("money-parity", args("money-parity", quick=True), cfg, http)
    assert (quick.__self__.workers, quick.__self__.units) == (10, 100)
    full = gates.build("money-parity", args("money-parity"), cfg, http)
    assert (full.__self__.workers, full.__self__.units) == (50, 1000)
    for name, kind in (
        ("delivery-gate", DeliveryGate),
        ("security", SecurityGate),
        ("ui", UiGate),
        ("restore-drill", RestoreDrill),
    ):
        assert isinstance(gates.build(name, args(name), cfg, http).__self__, kind)


def test_the_rate_limit_is_read_from_the_compose_file(tmp_path):
    compose = tmp_path / "compose.yaml"
    compose.write_text('      YANTRA_GATEWAY_RATE_LIMIT_PER_MINUTE: "250"\n')
    assert gates.rate_limit_from_compose(compose) == 250
    compose.write_text("nothing here\n")
    assert gates.rate_limit_from_compose(compose) == 600
    assert gates.rate_limit_from_compose(tmp_path / "missing.yaml", 42) == 42


def test_yantra_gate_prints_the_table_or_json_and_exits_by_the_result(env, capsys, monkeypatch, tmp_path):
    shots = tmp_path / "shots"
    shots.mkdir()
    (shots / "m4-x.png").write_bytes(b"x")
    monkeypatch.setattr(UiGate, "evidence_dir", shots)
    http = ui_client(GOOD_HEADERS)
    assert main(["gate", "ui", "--app-url", "http://app"], http=http, env=env) == 0
    assert capsys.readouterr().out.startswith("PASS  ui")
    assert main(["--json", "gate", "ui", "--app-url", "http://app"], http=ui_client({}), env=env) == 1
    doc = json.loads(capsys.readouterr().out)
    assert doc[0]["gate"] == "ui" and doc[0]["result"] == "FAIL"


def test_yantra_gate_builds_its_own_patient_client_when_none_is_given(env, monkeypatch):
    made: list[httpx.Client] = []
    real = httpx.Client

    def spy(*a: Any, **kw: Any) -> httpx.Client:
        client = real(*a, **kw)
        made.append(client)
        return client

    monkeypatch.setattr(httpx, "Client", spy)
    monkeypatch.setattr(gates, "run", lambda a, cfg, http: [GateResult("ui", True)])
    assert main(["gate", "ui"], env=env) == 0
    assert made[0].timeout.read == 120.0


def test_the_repo_root_is_where_the_compose_file_lives():
    assert (gates.REPO / "deployment/local/compose.yaml").exists()


def test_every_gate_name_is_offered_by_the_command():
    assert set(gates.NAMES) == {"claim-storm", "money-parity", "delivery-gate", "security", "ui", "restore-drill"}


def test_the_delivery_gate_waits_while_the_manifest_is_still_held():
    rig = Services()
    rig.fail["GET /manifest"] = err(409, "batch_held", held={"available": 1})
    naps: list[float] = []
    gate = DeliveryGate(rig.direct(), rig.direct().http, sleep=naps.append)
    assert gate._manifest(Actor.new("ops"), "b") == {"accepted_units": 0, "digest": "d1"}
    assert naps == [1.0]


def test_money_parity_has_no_margin_row_until_payout_booked_every_unit():
    assert parity(Services())._margin(Actor.new("finance"), "b") is None
