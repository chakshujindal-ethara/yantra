"""The smoke scenario against a scripted rig: every step's assertion is exercised, including the ones that
must fail (a second claim, a manifest before acceptance, one approver twice)."""

import json
import uuid
from datetime import UTC, datetime
from typing import Any

import httpx
import pytest

from yantra_cli.__main__ import main
from yantra_cli.client import Gateway
from yantra_cli.smoke import IST, Smoke, SmokeFailed, saturday_after

from .conftest import OPS, WORKER, fake_jwt


def test_saturday_after_is_a_saturday_at_least_eight_days_ahead():
    now = datetime(2026, 11, 3, 6, 0, tzinfo=UTC)  # a Tuesday
    sat = saturday_after(now)
    local = sat.astimezone(UTC)
    assert (sat - now).days >= 8 and (local + (sat - local)).weekday() in (4, 5)  # Saturday IST is Friday night UTC
    assert saturday_after(now, 15) > sat


class Rig:
    """Enough of the platform to walk the smoke through; state machines are tiny and in-memory."""

    def __init__(self, sampled: bool = False, needs_edits_last: bool = True) -> None:
        self.sampled = sampled
        self.units: list[dict[str, Any]] = []
        self.claims: dict[str, dict[str, Any]] = {}
        self.tasks: list[dict[str, Any]] = []
        self.verdicts: dict[str, str] = {}
        self.earnings: dict[str, list[dict[str, Any]]] = {}
        self.inbox: dict[str, list[dict[str, Any]]] = {}
        self.windows: dict[str, dict[str, Any]] = {}
        self.approvals: dict[str, set[str]] = {}
        self.closed_periods: set[str] = set()
        self.requests: list[httpx.Request] = []
        self.subs = {"ops1": OPS, "ops2": "00000000-0000-4000-8000-00000000a002", "worker1": WORKER}
        self.subs["worker2"] = "00000000-0000-4000-8000-000000000002"
        self.subs["worker3"] = "00000000-0000-4000-8000-000000000003"
        self.batch_id = str(uuid.uuid4())
        self.account_status = "verified"
        self.stale: dict[str, str] = {}  # reviewer sub -> a task an earlier, interrupted run left them holding
        self.released: list[str] = []
        self.email: str | None = None  # worker1's verified address
        self.pending: str | None = None
        self.code = "482913"
        self.mail_body = "Your code is 482913. Type it in the app within 15 minutes."
        self.mail_created = "2999-01-01T00:00:00Z"  # newer than any `asked` the smoke records
        self.mailpit_search_status = 200

    # -- identity
    def who(self, r: httpx.Request) -> str:
        token = r.headers["Authorization"].split(" ")[1]
        return str(json.loads(_b64(token.split(".")[1]))["sub"])

    def mailpit(self, r: httpx.Request) -> httpx.Response:
        if r.url.path == "/api/v1/search":
            if self.mailpit_search_status != 200 or self.pending is None:
                return httpx.Response(self.mailpit_search_status, json={"messages": []})
            return httpx.Response(200, json={"messages": [{"ID": "m1", "Created": self.mail_created}]})
        return httpx.Response(200, json={"Text": self.mail_body})

    def handle(self, r: httpx.Request) -> httpx.Response:
        self.requests.append(r)
        path, m = r.url.path, r.method
        if r.url.port == 8026:
            return self.mailpit(r)
        if path.endswith("/openid-connect/token"):
            form = dict(x.split("=", 1) for x in r.content.decode().split("&"))
            # A slow run may refresh mid-smoke: the refresh token carries the username so either grant resolves it.
            name = form["username"] if "username" in form else form["refresh_token"].removeprefix("refresh-")
            sub = self.subs[name]
            roles = ["ops"] if name.startswith("ops") else ["worker"]
            return httpx.Response(
                200, json={"access_token": fake_jwt(sub, roles), "refresh_token": f"refresh-{name}", "expires_in": 300}
            )
        body = json.loads(r.content) if r.content else {}
        me = self.who(r)
        if path == "/v1/workers/me":
            return httpx.Response(200, json={"id": me, "status": "eligible"})
        if path == "/v1/workers/me/availability":
            return httpx.Response(200, json={"worker_id": me, **body})
        if m == "PUT" and path.startswith("/v1/workers/"):
            return httpx.Response(200, json={"id": path.split("/")[-1]})
        if path == "/v1/projects":
            return httpx.Response(201, json={"id": str(uuid.uuid4())})
        if path.endswith("/batches") and m == "POST":
            return httpx.Response(201, json={"id": self.batch_id})
        if path.endswith("/units/import"):
            if r.url.params["dry_run"] == "false":
                self.units = [{"id": str(uuid.uuid4()), "status": "available", **line} for line in body["lines"]]
            return httpx.Response(
                200, json={"total": 3, "accepted": 3, "errors": [], "dry_run": r.url.params["dry_run"] == "true"}
            )
        if path.endswith("/publish"):
            return httpx.Response(200, json={"status": "published"})
        if path == "/v1/notify/channel" and m == "GET":
            if self.email is None and self.pending is None:  # the real service: 404 until a channel is set
                return httpx.Response(404, json={"code": "not_found", "message": "no channel set", "request_id": "r"})
            return httpx.Response(200, json={"email": self.email})
        if path == "/v1/notify/channel":
            self.pending = body["email"]
            return httpx.Response(200, json={"email": self.email, "pending_email": self.pending})
        if path == "/v1/notify/channel/verify":
            if body["code"] != self.code:
                return httpx.Response(422, json={"code": "wrong_code", "message": "no", "request_id": "r"})
            self.email, self.pending = self.pending, None
            return httpx.Response(200, json={"email": self.email})
        if path == "/v1/batches":
            mine = [u for u in self.units if u["status"] == "available" and u.get("assigned") in (None, me)]
            return httpx.Response(200, json=[{"id": self.batch_id, "available_units": len(mine)}] if mine else [])
        if path.endswith("/claims") and m == "POST":
            key = r.headers["Idempotency-Key"]
            for c in self.claims.values():
                if c["key"] == key:
                    return httpx.Response(201, json=c)
            if any(c["worker"] == me and c["status"] == "active" for c in self.claims.values()):
                return httpx.Response(409, json={"code": "one_live_claim", "message": "x", "request_id": "r"})
            unit = next((u for u in self.units if u["status"] == "available" and u.get("assigned") in (None, me)), None)
            if unit is None:
                return httpx.Response(404, json={"code": "not_found", "message": "no unit", "request_id": "r"})
            unit["status"] = "claimed"
            claim = {"id": str(uuid.uuid4()), "unit_id": unit["id"], "worker": me, "key": key, "status": "active"}
            self.claims[claim["id"]] = claim
            return httpx.Response(201, json=claim)
        if path.startswith("/v1/units/"):
            unit = next(u for u in self.units if u["id"] == path.split("/")[-1])
            return httpx.Response(200, json={"unit_pay": "28", "payload": unit["payload"]})
        if path.endswith("/submission"):
            claim = self.claims[path.split("/")[3]]
            claim["status"] = "submitted"
            self.tasks.append(
                {
                    "id": str(uuid.uuid4()),
                    "unit_id": claim["unit_id"],
                    "author": claim["worker"],
                    "status": "pending",
                    "payload": {"language": "hi"},
                    "answer": body["answer"],
                }
            )
            return httpx.Response(201, json={"id": str(uuid.uuid4())})
        if path == "/v1/quality/reviews/active":
            stale_task = self.stale.get(me)
            if stale_task is None:
                return httpx.Response(404, json={"code": "not_found", "message": "none", "request_id": "r"})
            return httpx.Response(200, json={"id": stale_task})
        if path.startswith("/v1/quality/reviews/") and path.endswith("/release"):
            self.released.append(path.split("/")[4])
            self.stale = {k: v for k, v in self.stale.items() if v != path.split("/")[4]}
            return httpx.Response(200, json={"id": path.split("/")[4], "status": "pending"})
        if path == "/v1/quality/reviews/claim":
            assert r.url.params.get("batch_id") == self.batch_id, "smoke claims only its own batch's reviews"
            kind = r.url.params.get("kind", "review")
            want = "pending" if kind == "review" else "audit_pending"
            task = next((t for t in self.tasks if t["status"] == want and t["author"] != me), None)
            if task is None:
                return httpx.Response(404, json={"code": "not_found", "message": "no task", "request_id": "r"})
            task["status"] = "claimed" if kind == "review" else "audit_claimed"
            return httpx.Response(201, json=task)
        if path.startswith("/v1/quality/tasks/") and m == "GET":
            return httpx.Response(200, json=next(t for t in self.tasks if t["id"] == path.split("/")[-1]))
        if path.endswith("/review"):
            task = next(t for t in self.tasks if t["id"] == path.split("/")[4])
            if body["verdict"] == "accept" and task["status"] == "claimed" and self.sampled:
                task["status"], task["reviewer"] = "audit_pending", me
                return httpx.Response(200, json={**task, "canonical_verdict": None})
            task["status"] = "done"
            task["canonical_verdict"] = body["verdict"]
            unit = next(u for u in self.units if u["id"] == task["unit_id"])
            if body["verdict"] == "accept":
                unit["status"] = "accepted"
            else:
                unit["status"], unit["assigned"] = "available", task["author"]
            self._settle(task, body["verdict"], me)
            return httpx.Response(200, json=task)
        if path.endswith("/manifest"):
            open_units = [u for u in self.units if u["status"] != "accepted"]
            if open_units:
                held = {"available": len(open_units)}
                return httpx.Response(
                    409, json={"code": "batch_held", "message": "held", "request_id": "r", "held": held}
                )
            units = [
                {"unit_id": t["unit_id"], "answer": t["answer"]}
                for t in self.tasks
                if t.get("canonical_verdict") == "accept"
            ]
            return httpx.Response(200, json={"accepted_units": 3, "total_price": "180.000000", "units": units})
        if path == "/v1/quality/my-work":
            mine = [
                {
                    "unit_id": t["unit_id"],
                    "stage": "decided" if t["status"] == "done" else "in_review",
                    "canonical_verdict": t.get("canonical_verdict"),
                }
                for t in self.tasks
                if t["author"] == me
            ]
            return httpx.Response(200, json=mine)
        if path == "/v1/payout/statement":
            rows = self.earnings.get(me, [])
            totals: dict[str, Any] = {}
            for e in rows:
                totals[e["status"]] = str(sum(float(x["amount"]) for x in rows if x["status"] == e["status"]))
            pending = {"currency": "INR", "amount": "0.00", "count": 0}
            statement = {"totals": totals, "earnings": rows, "windows": [], "weeks": [], "pending_next": pending}
            return httpx.Response(200, json=statement)
        if path == "/v1/notify/inbox":
            return httpx.Response(200, json=self.inbox.get(me, []))
        if path == "/v1/payout/windows/close":
            if body["as_of"] in self.closed_periods:
                return httpx.Response(409, json={"code": "conflict", "message": "closed", "request_id": "r"})
            self.closed_periods.add(body["as_of"])
            w = {"id": str(uuid.uuid4()), "status": "closed"}
            self.windows[w["id"]] = w
            return httpx.Response(201, json=w)
        if path.endswith("/approve"):
            w = self.windows[path.split("/")[4]]
            people = self.approvals.setdefault(w["id"], set())
            if me in people:
                return httpx.Response(409, json={"code": "already_approved", "message": "x", "request_id": "r"})
            people.add(me)
            if len(people) >= 2:
                w["status"] = "approved"
            return httpx.Response(200, json=w)
        if path == "/v1/payout/accounts/me":
            return httpx.Response(200, json={"status": self.account_status, "account_last4": "0005"})
        if path.endswith("/lines"):
            w = self.windows[path.split("/")[4]]
            status = "paid" if w["status"] == "paid" else "payable"
            lines = [
                {"worker_id": sub, "gross": f"{self._total(sub):.2f}", "status": status, "utr": "UTR1"}
                for sub in (WORKER, self.subs["worker2"])
            ]
            return httpx.Response(200, json=lines)
        if path.endswith("/pay"):
            w = self.windows[path.split("/")[4]]
            w.update(status="paying", rail_reference=f"razorpayx:{w['id'][:8]}")
            return httpx.Response(200, json=w)
        if m == "GET" and path.startswith("/v1/payout/windows/") and path.count("/") == 4:
            w = self.windows[path.split("/")[4]]
            if w["status"] == "paying":  # the rail settled every line since the last look
                w["status"] = "paid"
                for sub, rows in self.earnings.items():
                    for e in rows:
                        e["status"] = "paid"
                    self.inbox.setdefault(sub, []).append({"kind": "payout_paid", "emailed_at": "t"})
            return httpx.Response(200, json=w)
        if path.endswith("/reconcile"):
            total = self._total(WORKER) + self._total(self.subs["worker2"])
            return httpx.Response(
                200, json={"balanced": True, "paid_total": f"{total:.2f}", "reconciled_at": "2026-11-07T00:00:00Z"}
            )
        if "/statements/" in path:
            csv_rows = [f"s,e,paid,UTR1,unit,u,{e['amount']},INR,t" for e in self.earnings.get(me, [])]
            text = "header\n" + "\n".join(csv_rows) + "\n"
            return httpx.Response(200, text=text, headers={"content-type": "text/csv"})
        if path == "/v1/payout/margin":
            return httpx.Response(200, json=[{"batch_id": self.batch_id, "margin": "46.00"}])
        raise AssertionError(f"unrouted {m} {path}")

    def _settle(self, task: dict[str, Any], verdict: str, reviewer: str) -> None:
        if verdict == "accept":
            self.earnings.setdefault(task["author"], []).append({"kind": "unit", "amount": "28", "status": "payable"})
            self.inbox.setdefault(task["author"], []).append({"kind": "verdict_accepted", "emailed_at": "t"})
        else:
            self.inbox.setdefault(task["author"], []).append({"kind": "verdict_needs_edits", "emailed_at": "t"})
        for who in {task.get("reviewer", reviewer), reviewer}:  # the canonical verdict pays reviewer and auditor
            self.earnings.setdefault(who, []).append({"kind": "review", "amount": "6", "status": "payable"})

    def _total(self, sub: str) -> float:  # noqa: D401
        return sum(float(e["amount"]) for e in self.earnings.get(sub, []))


def _b64(s: str) -> str:
    import base64

    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)).decode()


def test_the_smoke_gives_back_a_review_an_interrupted_run_left_held(cfg):
    rig = Rig()
    rig.stale = {rig.subs["worker2"]: "stale-task"}
    smoke = Smoke(cfg, "yantra", httpx.Client(transport=httpx.MockTransport(rig.handle)), sleep=lambda s: None)
    assert smoke.run()["result"] == "PASS"
    assert rig.released == ["stale-task"]


@pytest.mark.parametrize("sampled", [False, True])
def test_the_smoke_walks_the_whole_loop(cfg, sampled):
    rig = Rig(sampled=sampled)
    said: list[str] = []
    smoke = Smoke(
        cfg, "yantra", httpx.Client(transport=httpx.MockTransport(rig.handle)), sleep=lambda s: None, say=said.append
    )
    report = smoke.run()
    # sampled: worker1 audits the redo (+6 on the bank file); worker3's two audits are not on the file's rows
    assert report["result"] == "PASS" and report["paid_total"] == ("86.00" if sampled else "80.00")
    assert len(said) == 7 + 2 * int(sampled)
    assert all(
        r.headers.get("Idempotency-Key")
        for r in rig.requests
        if r.method in ("POST", "PUT") and "/token" not in r.url.path
    )


def test_the_smoke_fails_loudly_when_the_platform_misbehaves(cfg, monkeypatch):
    rig = Rig()
    original = rig.handle

    def no_second_claim_guard(r: httpx.Request) -> httpx.Response:
        if r.url.path.endswith("/claims") and r.method == "POST":
            unit = next(u for u in rig.units if u["status"] == "available")
            unit["status"] = "claimed"
            return httpx.Response(201, json={"id": str(uuid.uuid4()), "unit_id": unit["id"]})
        return original(r)

    smoke = Smoke(
        cfg,
        "yantra",
        httpx.Client(transport=httpx.MockTransport(no_second_claim_guard)),
        sleep=lambda s: None,
        say=lambda s: None,
    )
    with pytest.raises(SmokeFailed, match="same claim"):
        smoke.run()


def test_waiting_times_out_with_a_named_step(cfg, monkeypatch):
    clock = {"t": 0.0}
    monkeypatch.setattr("yantra_cli.smoke.time.monotonic", lambda: clock["t"])

    def tick(s: float) -> None:
        clock["t"] += s

    smoke = Smoke(cfg, "yantra", httpx.Client(), sleep=tick, say=lambda s: None, wait_seconds=3)
    with pytest.raises(SmokeFailed, match="timed out waiting for never"):
        smoke.until("never", lambda: False)


def test_smoke_from_the_command_line(cfg, env, capsys):
    rig = Rig()
    code = main(["smoke"], http=httpx.Client(transport=httpx.MockTransport(rig.handle)), env=env)
    out, _ = capsys.readouterr()
    assert code == 0 and "result          PASS" in out
    broken = Rig()
    broken.units = []
    code = main(
        ["smoke", "--wait", "0"],
        http=httpx.Client(
            transport=httpx.MockTransport(
                lambda r: httpx.Response(500, json={"code": "internal_error", "message": "x", "request_id": "r"})
                if "/token" not in r.url.path
                else broken.handle(r)
            )
        ),
        env=env,
    )
    _, err = capsys.readouterr()
    assert code == 1 and "error: 500 internal_error" in err


class SlowRig(Rig):
    """The submitted event takes a round to reach quality, and one pay window is already closed."""

    def __init__(self) -> None:
        super().__init__()
        self.claim_calls = 0
        self.closes = 0

    def handle(self, r: httpx.Request) -> httpx.Response:
        if r.url.path == "/v1/quality/reviews/claim":
            self.claim_calls += 1
            if self.claim_calls == 1:
                return httpx.Response(404, json={"code": "not_found", "message": "no task", "request_id": "r"})
        if r.url.path == "/v1/payout/windows/close":
            self.closes += 1
            if self.closes == 1:
                return httpx.Response(409, json={"code": "conflict", "message": "closed", "request_id": "r"})
        return super().handle(r)


def test_the_smoke_waits_for_the_event_and_skips_a_closed_window(cfg):
    rig = SlowRig()
    waits: list[float] = []
    smoke = Smoke(
        cfg, "yantra", httpx.Client(transport=httpx.MockTransport(rig.handle)), sleep=waits.append, say=lambda s: None
    )
    assert smoke.run()["result"] == "PASS" and rig.closes == 2 and 1.0 in waits


def _mutated(cfg, mutate):
    rig = Rig()
    original = rig.handle

    def handle(r: httpx.Request) -> httpx.Response:
        return mutate(r) or original(r)

    return Smoke(
        cfg, "yantra", httpx.Client(transport=httpx.MockTransport(handle)), sleep=lambda s: None, say=lambda s: None
    )


@pytest.mark.parametrize(
    "path_end,method,response,message",
    [
        ("/manifest", "GET", httpx.Response(200, json={"accepted_units": 3}), "manifest built"),
        (
            "/manifest",
            "GET",
            httpx.Response(500, json={"code": "internal_error", "message": "x", "request_id": "r"}),
            "gate reports",
        ),
        ("/approve", "POST", httpx.Response(200, json={"status": "approved"}), "approved twice"),
        (
            "/windows/close",
            "POST",
            httpx.Response(409, json={"code": "conflict", "message": "x", "request_id": "r"}),
            "no free pay window",
        ),
        (
            "/windows/close",
            "POST",
            httpx.Response(500, json={"code": "internal_error", "message": "x", "request_id": "r"}),
            "500 internal_error",
        ),
        (
            "/reviews/claim",
            "POST",
            httpx.Response(403, json={"code": "forbidden", "message": "x", "request_id": "r"}),
            "403 forbidden",
        ),
        (
            "/v1/notify/channel",
            "GET",
            httpx.Response(500, json={"code": "internal_error", "message": "x", "request_id": "r"}),
            "500 internal_error",
        ),
        (
            "/reviews/active",
            "GET",
            httpx.Response(500, json={"code": "internal_error", "message": "x", "request_id": "r"}),
            "500 internal_error",
        ),
        ("/v1/workers/me", "GET", httpx.Response(200, json={"status": "unknown"}), "worker1 is eligible"),
        ("/me/availability", "PUT", httpx.Response(200, json={"weekly_hours": 0}), "availability echoed"),
        ("/quality/my-work", "GET", httpx.Response(200, json=[]), "decided in my work"),
        ("/payout/statement", "GET", httpx.Response(200, json={"totals": {}}), "statement carries"),
        ("/payout/accounts/me", "PUT", httpx.Response(200, json={"status": "failed"}), "accepted for the penny drop"),
        (
            "/payout/accounts/me",
            "PUT",
            httpx.Response(200, json={"status": "verified", "account_number": "1"}),
            "never",
        ),
        ("/pay", "POST", httpx.Response(200, json={"status": "closed"}), "on the rail"),
        ("/reconcile", "POST", httpx.Response(200, json={"balanced": False}), "reconciled to the paisa"),
        ("/export", "GET", httpx.Response(200, text="h\n", headers={"content-type": "text/csv"}), "statement export"),
    ],
)
def test_each_promise_the_smoke_checks_can_fail(cfg, path_end, method, response, message):
    def mutate(r: httpx.Request) -> httpx.Response | None:
        return response if r.url.path.endswith(path_end) and r.method == method else None

    with pytest.raises((SmokeFailed, Exception), match=message):
        _mutated(cfg, mutate).run()


def test_a_second_live_claim_that_is_allowed_fails_the_smoke(cfg):
    seen = {"claims": 0}

    def mutate(r: httpx.Request) -> httpx.Response | None:
        if r.url.path.endswith("/claims") and r.method == "POST":
            seen["claims"] += 1
            if seen["claims"] == 3:  # the one that must be refused
                return httpx.Response(201, json={"id": str(uuid.uuid4()), "unit_id": str(uuid.uuid4())})
        return None

    with pytest.raises(SmokeFailed, match="second live claim"):
        _mutated(cfg, mutate).run()


def test_a_reviewer_who_never_gets_a_task_times_out(cfg, monkeypatch):
    clock = {"t": 0.0}
    monkeypatch.setattr("yantra_cli.smoke.time.monotonic", lambda: clock["t"])

    def mutate(r: httpx.Request) -> httpx.Response | None:
        if r.url.path == "/v1/quality/reviews/claim":
            clock["t"] += 100
            return httpx.Response(404, json={"code": "not_found", "message": "no", "request_id": "r"})
        return None

    with pytest.raises(Exception, match="404 not_found"):
        _mutated(cfg, mutate).run()


def test_smoke_failure_from_the_command_line_is_exit_1(cfg, env, capsys):
    rig = Rig()
    original = rig.handle

    def handle(r: httpx.Request) -> httpx.Response:
        if r.url.path.endswith("/manifest"):
            return httpx.Response(200, json={})
        return original(r)

    code = main(["smoke"], http=httpx.Client(transport=httpx.MockTransport(handle)), env=env)
    _, err = capsys.readouterr()
    assert code == 1 and "FAIL: manifest built" in err


def test_a_rig_with_earlier_earnings_still_passes_and_a_leaked_price_fails(cfg):
    rig = Rig()
    rig.earnings[WORKER] = [{"kind": "unit", "amount": "56", "status": "paid"}]  # a previous run's money
    smoke = Smoke(
        cfg, "yantra", httpx.Client(transport=httpx.MockTransport(rig.handle)), sleep=lambda s: None, say=lambda s: None
    )
    assert smoke.run()["result"] == "PASS"

    def leak(r: httpx.Request) -> httpx.Response | None:
        if r.url.path.startswith("/v1/units/"):
            return httpx.Response(200, json={"unit_pay": "28", "unit_price": "60", "payload": {"text": "x"}})
        return None

    with pytest.raises(SmokeFailed, match="never price"):
        _mutated(cfg, leak).run()


def test_saturday_after_lands_on_a_saturday_morning_in_india():
    for day in range(1, 15):
        sat = saturday_after(datetime(2026, 11, day, 6, 0, tzinfo=UTC))
        local = sat.astimezone(UTC) + IST
        assert local.weekday() == 5 and (local.hour, local.minute) == (10, 0)


def test_manifest_probe_distinguishes_held_from_broken(cfg):
    def answer(r: httpx.Request) -> httpx.Response:
        if "held" in r.url.path:
            return httpx.Response(409, json={"code": "batch_held", "message": "x", "request_id": "r", "held": {}})
        return httpx.Response(500, json={"code": "internal_error", "message": "x", "request_id": "r"})

    from yantra_cli.auth import Session

    gw = Gateway(
        cfg,
        Session("ops1", fake_jwt(OPS, ["ops"]), "r" * 20, 9e12),
        httpx.Client(transport=httpx.MockTransport(answer)),
    )
    assert Smoke._manifest(gw, "held") is None
    with pytest.raises(Exception, match="500 internal_error"):
        Smoke._manifest(gw, "broken")


def test_a_penny_drop_that_never_lands_times_out_by_name(cfg, monkeypatch):
    clock = {"t": 0.0}
    monkeypatch.setattr("yantra_cli.smoke.time.monotonic", lambda: clock["t"])

    def mutate(r: httpx.Request) -> httpx.Response | None:
        if r.url.path == "/v1/payout/accounts/me" and r.method == "GET":
            clock["t"] += 100
            return httpx.Response(200, json={"status": "verifying"})
        return None

    with pytest.raises(SmokeFailed, match="the penny drops"):
        _mutated(cfg, mutate).run()


def test_bank_account_for_is_stable_and_avoids_the_emulator_failure_digits():
    from yantra_cli.smoke import bank_account_for

    a = bank_account_for(WORKER)
    assert a == bank_account_for(WORKER) and a["account_number"].endswith("5") and len(a["account_number"]) == 12


def test_the_smoke_skips_the_email_code_when_the_address_is_verified_already(cfg):
    rig = Rig()
    rig.email = "worker1@yantra.local"
    smoke = Smoke(cfg, "yantra", httpx.Client(transport=httpx.MockTransport(rig.handle)), sleep=lambda s: None)
    assert smoke.run()["result"] == "PASS"
    assert not [r for r in rig.requests if r.url.port == 8026]


def test_the_smoke_reads_the_mailed_code_and_verifies_the_address(cfg):
    rig = Rig()
    smoke = Smoke(cfg, "yantra", httpx.Client(transport=httpx.MockTransport(rig.handle)), sleep=lambda s: None)
    assert smoke.run()["result"] == "PASS"
    assert rig.email == "worker1@yantra.local"
    verify = next(r for r in rig.requests if r.url.path == "/v1/notify/channel/verify")
    assert json.loads(verify.content) == {"code": "482913"}


@pytest.mark.parametrize(
    "change",
    [
        {"mailpit_search_status": 503},  # the catcher is down: no code ever
        {"mail_created": "2000-01-01T00:00:00Z"},  # only an older mail: not this request's code
        {"mail_body": "no digits here"},  # a mail without a code
    ],
)
def test_the_smoke_fails_plainly_when_no_code_arrives(cfg, change):
    rig = Rig()
    for k, v in change.items():
        setattr(rig, k, v)
    smoke = Smoke(
        cfg, "yantra", httpx.Client(transport=httpx.MockTransport(rig.handle)), sleep=lambda s: None, wait_seconds=0
    )
    with pytest.raises(SmokeFailed, match="email code"):
        smoke.run()
