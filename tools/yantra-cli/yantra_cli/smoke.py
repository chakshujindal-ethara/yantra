"""The end-to-end smoke test against a running rig: project to paid, through the gateway with real tokens.
Every step asserts what the plan promises (one claim per unit, pay only on the canonical accept, the gate
holds a batch on one bad unit, approvals are two finance people, the rail pays every line, the paid lines are the
ledger to the paisa, the statement is released after reconciliation)."""

import re
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Any

import httpx

from yantra_cli.auth import login
from yantra_cli.client import Gateway, GatewayError
from yantra_cli.config import Config

IST = timedelta(hours=5, minutes=30)
CODE_SUBJECT = "Your Yantra email code"
WORKER1_EMAIL = "worker1@yantra.local"
SCHEMA = {
    "type": "object",
    "required": ["text", "language"],
    "properties": {"text": {"type": "string", "minLength": 1}, "language": {"type": "string", "enum": ["hi", "ta"]}},
}


class SmokeFailed(Exception):
    pass


def check(cond: bool, what: str) -> None:
    if not cond:
        raise SmokeFailed(what)


def bank_account_for(worker_id: str) -> dict[str, str]:
    """A bank account of the worker's own, the same on every run (so a second run is a no-op), never ending in the
    emulator's failure digits (0000, 1111)."""
    digits = str(uuid.UUID(worker_id).int)
    number = "7" + digits[-10:] + "5"
    return {"account_name": "Smoke Worker", "account_number": number, "ifsc": "HDFC0001234"}


def saturday_after(now: datetime, min_days_ahead: int = 8) -> datetime:
    """A Saturday 10:00 IST at least `min_days_ahead` days ahead: past the first-payout hold, so money moves."""
    local = (now + timedelta(days=min_days_ahead)).astimezone(UTC) + IST
    days = (5 - local.weekday()) % 7
    sat = (local + timedelta(days=days)).replace(hour=10, minute=0, second=0, microsecond=0)
    return sat - IST


@dataclass
class Smoke:
    cfg: Config
    password: str
    http: httpx.Client
    sleep: Callable[[float], None] = time.sleep
    say: Callable[[str], None] = print
    wait_seconds: float = 90.0
    pay_wait_seconds: float = 180.0  # the rail's dispatch (15 s) and poll (60 s) jobs settle the lines
    users: dict[str, Gateway] = field(default_factory=dict)
    mailpit_url: str = "http://localhost:8026"  # the rig's mail catcher, where the email code lands

    def as_user(self, name: str) -> Gateway:
        if name not in self.users:
            self.users[name] = Gateway(self.cfg, login(self.http, self.cfg, name, self.password), self.http, self.sleep)
        return self.users[name]

    def _verify_email(self, worker: Gateway, address: str) -> None:
        """Mail goes only to a verified address: set it, read the code from the rig's mail catcher, confirm it.
        A rerun finds it verified already and moves on."""
        try:
            current = worker.get("/v1/notify/channel").get("email")
        except GatewayError as e:
            if e.status != 404:  # 404: no channel yet, the first run on a fresh rig
                raise
            current = None
        if current == address:
            return
        asked = datetime.now(UTC) - timedelta(seconds=5)
        worker.put("/v1/notify/channel", {"email": address})
        found: dict[str, str] = {}

        def code_arrived() -> bool:
            code = self._mailed_code(address, asked)
            if code:
                found["code"] = code
            return bool(code)

        self.until(f"the email code for {address}", code_arrived)
        verified = worker.post("/v1/notify/channel/verify", {"code": found["code"]})
        check(verified.get("email") == address, "the email address is verified")

    def _mailed_code(self, address: str, since: datetime) -> str | None:
        """The newest code mailed to `address` after `since`, from Mailpit's API; None until it arrives."""
        query = f'to:"{address}" subject:"{CODE_SUBJECT}"'
        found = self.http.get(f"{self.mailpit_url}/api/v1/search", params={"query": query})
        if found.status_code != 200:
            return None
        for msg in found.json().get("messages", []):  # newest first
            if datetime.fromisoformat(msg["Created"].replace("Z", "+00:00")) < since:
                return None
            body = self.http.get(f"{self.mailpit_url}/api/v1/message/{msg['ID']}").json().get("Text", "")
            match = re.search(r"\b(\d{6})\b", body)
            if match:
                return match.group(1)
        return None

    def until(self, what: str, probe: Callable[[], bool], seconds: float | None = None) -> None:
        deadline = time.monotonic() + (self.wait_seconds if seconds is None else seconds)
        while True:
            if probe():
                return
            if time.monotonic() > deadline:
                raise SmokeFailed(f"timed out waiting for {what}")
            self.sleep(1.0)

    def run(self) -> dict[str, Any]:
        ops1, ops2 = self.as_user("ops1"), self.as_user("ops2")
        w1, w2, w3 = self.as_user("worker1"), self.as_user("worker2"), self.as_user("worker3")
        gate = f"smoke-{uuid.uuid4().hex[:6]}"
        before = {name: self._totals(w) for name, w in (("w1", w1), ("w2", w2), ("w3", w3))}
        # the inbox accumulates across runs (the worker ids are fixed): count what this run adds
        inbox_before = {
            "w1": self._inbox_kinds(w1).count("verdict_accepted"),
            "w3": self._inbox_kinds(w3).count("verdict_needs_edits"),
        }
        self.say("1. three workers register bank accounts; ops seed them eligible, a project, a batch; publish")
        for w in (w1, w2, w3):
            account = w.put("/v1/payout/accounts/me", bank_account_for(w.session.worker_id))
            check(account["status"] in ("verifying", "verified"), "the bank account is accepted for the penny drop")
            check("account_number" not in account, "the account number never comes back")
            ops1.put(f"/v1/workers/{w.session.worker_id}", {"status": "eligible", "cert_gates": [gate]})
        project = ops1.post(
            "/v1/projects",
            {
                "name": f"Smoke {gate}",
                "currency": "INR",
                "payload_schema": SCHEMA,
                "cert_gate": gate,
                "margin_floor": "0.3",
            },
        )
        batch = ops1.post(
            f"/v1/projects/{project['id']}/batches",
            {"title": "smoke batch", "unit_pay": "28", "unit_price": "60", "review_pay": "6", "claim_ttl_minutes": 60},
        )
        lines = [{"external_ref": f"s{i}", "payload": {"text": f"line {i}", "language": "hi"}} for i in range(3)]
        dry = ops1.post(f"/v1/batches/{batch['id']}/units/import", {"lines": lines}, dry_run="true")
        check(dry["accepted"] == 3 and dry["dry_run"], "dry run accepts 3 lines")
        ops1.post(f"/v1/batches/{batch['id']}/units/import", {"lines": lines}, dry_run="false")
        published = ops1.post(f"/v1/batches/{batch['id']}/publish", {})
        check(published["status"] == "published", "batch published")
        self._verify_email(w1, WORKER1_EMAIL)

        self.say("2. workers browse, claim and submit (one live claim each; a key retried returns the same claim)")
        open_batches = w1.get("/v1/batches")
        check(
            any(b["id"] == batch["id"] and b["available_units"] == 3 for b in open_batches),
            "batch is open with 3 units",
        )
        key = f"smoke-{uuid.uuid4()}"
        c1 = w1.call("POST", f"/v1/batches/{batch['id']}/claims", key=key)
        check(
            w1.call("POST", f"/v1/batches/{batch['id']}/claims", key=key)["id"] == c1["id"], "retried key, same claim"
        )
        try:
            w1.post(f"/v1/batches/{batch['id']}/claims")
            raise SmokeFailed("a second live claim was allowed")
        except GatewayError as e:
            check(e.code == "one_live_claim", "one live claim per worker")
        unit1 = w1.get(f"/v1/units/{c1['unit_id']}")
        check("unit_price" not in unit1 and Decimal(unit1["unit_pay"]) == 28, "worker sees pay, never price")
        w1.post(f"/v1/claims/{c1['id']}/submission", {"answer": {"transcript": unit1["payload"]["text"]}})
        c2 = w1.post(f"/v1/batches/{batch['id']}/claims")
        w1.post(f"/v1/claims/{c2['id']}/submission", {"answer": {"transcript": "second"}})
        c3 = w3.post(f"/v1/batches/{batch['id']}/claims")
        w3.post(f"/v1/claims/{c3['id']}/submission", {"answer": {"transcript": "third"}})
        check(
            w1.get("/v1/batches") == [] or all(b["id"] != batch["id"] for b in w1.get("/v1/batches")), "no units left"
        )

        self.say("3. review: two accepts (audited when sampled), one reject that the client caused")
        self._drop_stale_holds(w1, w2, w3)
        verdicts: dict[str, str] = {}
        audits_by_w3 = 0  # an audit pays review_pay, so worker3's statement moves before their unit is accepted
        for _ in range(3):
            task = self._next_task(w2, batch["id"])
            detail = w2.get(f"/v1/quality/tasks/{task['id']}")
            check("answer" in detail and detail["payload"]["language"] == "hi", "reviewer reads the submission copy")
            if task["unit_id"] == c3["unit_id"]:
                verdict = {"verdict": "needs_edits", "reason_code": "client_glossary_change"}
                done = w2.post(f"/v1/quality/tasks/{task['id']}/review", verdict)
                verdicts[task["unit_id"]] = "needs_edits"
            else:
                done = w2.post(f"/v1/quality/tasks/{task['id']}/review", {"verdict": "accept"})
                if done["status"] == "audit_pending":
                    self.say("   unit in the 10% audit sample: the auditor's verdict wins")
                    audit = w3.post("/v1/quality/reviews/claim", kind="audit", batch_id=batch["id"])
                    done = w3.post(f"/v1/quality/tasks/{audit['id']}/review", {"verdict": "accept"})
                    audits_by_w3 += 1
                verdicts[task["unit_id"]] = "accept"
            check(done["canonical_verdict"] in ("accept", "needs_edits"), "verdict is canonical")
        check(list(verdicts.values()).count("accept") == 2, "two accepts, one needs_edits")

        self.say("4. the worker's own screens: profile, the weekly check-in, my work, the statement's keys")
        check(w1.get("/v1/workers/me")["status"] == "eligible", "worker1 is eligible")
        check(w1.put("/v1/workers/me/availability", {"weekly_hours": 20})["weekly_hours"] == 20, "availability echoed")
        for worker, units in ((w1, {c1["unit_id"], c2["unit_id"]}), (w3, {c3["unit_id"]})):
            decided = {row["unit_id"] for row in worker.get("/v1/quality/my-work") if row["stage"] == "decided"}
            check(units <= decided, "the three units are decided in my work")
        statement = w1.get("/v1/payout/statement")
        check(all(k in statement for k in ("windows", "weeks", "pending_next")), "statement carries the app's keys")

        self.say("5. money moves only on the canonical accept; the inbox and the email follow")
        self.until("worker1 earnings", lambda: self._earned(w1, before["w1"]) == Decimal("56"))
        self.until("reviewer earnings", lambda: self._earned(w2, before["w2"]) == Decimal("18"))
        audit_pay = Decimal("6") * audits_by_w3
        check(self._earned(w3, before["w3"]) == audit_pay, "the author of the sent-back unit earns only audit pay yet")
        self.until("worker1 inbox", lambda: self._inbox_kinds(w1).count("verdict_accepted") - inbox_before["w1"] == 2)
        self.until(
            "worker3 inbox", lambda: self._inbox_kinds(w3).count("verdict_needs_edits") - inbox_before["w3"] == 1
        )
        self.until("worker1 email", lambda: all(n["emailed_at"] for n in w1.get("/v1/notify/inbox")))

        self.say("6. the delivery gate holds the batch on the unit sent back; its author redoes it; the gate passes")
        try:
            ops1.get(f"/v1/batches/{batch['id']}/manifest")
            raise SmokeFailed("manifest built with a unit still open")
        except GatewayError as e:
            check(e.code == "batch_held" and e.body["held"] == {"available": 1}, "gate reports the unit sent back")
        self.until("the unit back with its author", lambda: any(b["id"] == batch["id"] for b in w3.get("/v1/batches")))
        check(all(b["id"] != batch["id"] for b in w1.get("/v1/batches")), "a sent-back unit is its author's alone")
        redo = w3.post(f"/v1/batches/{batch['id']}/claims")
        check(redo["unit_id"] == c3["unit_id"], "the author gets the same unit back")
        w3.post(f"/v1/claims/{redo['id']}/submission", {"answer": {"transcript": "third, fixed"}})
        task = self._next_task(w2, batch["id"])
        done = w2.post(f"/v1/quality/tasks/{task['id']}/review", {"verdict": "accept"})
        if done["status"] == "audit_pending":
            audit = w1.post("/v1/quality/reviews/claim", kind="audit", batch_id=batch["id"])
            done = w1.post(f"/v1/quality/tasks/{audit['id']}/review", {"verdict": "accept"})
        check(done["canonical_verdict"] == "accept", "the redo is accepted")
        self.until("worker3 earnings", lambda: self._earned(w3, before["w3"]) == Decimal("28") + audit_pay)
        self.until("the manifest", lambda: self._manifest(ops1, batch["id"]) is not None)
        manifest = self._manifest(ops1, batch["id"])
        check(
            manifest["accepted_units"] == 3 and Decimal(manifest["total_price"]) == Decimal("180"), "manifest = 3 x 60"
        )
        redone: dict[str, Any] = next((u for u in manifest["units"] if u["unit_id"] == c3["unit_id"]), {})
        check(redone.get("answer") == {"transcript": "third, fixed"}, "the manifest carries the final answer")

        self.say("7. pay window: close, two finance approvals, the rail pays each line, reconciled, statement out")
        self.until(
            "the penny drops",
            lambda: all(w.get("/v1/payout/accounts/me")["status"] == "verified" for w in (w1, w2, w3)),
            self.pay_wait_seconds,
        )
        window = self._close_a_fresh_window(ops1)
        try:
            ops1.post(f"/v1/payout/windows/{window['id']}/approve")
            ops1.post(f"/v1/payout/windows/{window['id']}/approve")
            raise SmokeFailed("one person approved twice")
        except GatewayError as e:
            check(e.status == 409, "a second approval must be another person")
        approved = ops2.post(f"/v1/payout/windows/{window['id']}/approve")
        check(approved["status"] == "approved", "two approvals release the window")
        window_lines: list[dict[str, Any]] = ops1.get(f"/v1/payout/windows/{window['id']}/lines")
        w1_lines = [line for line in window_lines if line["worker_id"] == w1.session.worker_id]
        check(
            len(w1_lines) == 1 and w1_lines[0]["status"] == "payable" and Decimal(w1_lines[0]["gross"]) >= 56,
            "the window pays worker1 at least 56.00",
        )
        paying = ops1.post(f"/v1/payout/windows/{window['id']}/pay")
        check(paying["status"] in ("paying", "paid"), "the window is on the rail")
        self.until(
            "the rail pays every line",
            lambda: ops1.get(f"/v1/payout/windows/{window['id']}")["status"] == "paid",
            self.pay_wait_seconds,
        )
        window_lines = ops1.get(f"/v1/payout/windows/{window['id']}/lines")
        paid_lines = [line for line in window_lines if line["status"] == "paid"]
        check(all(line["utr"] for line in paid_lines), "every paid line carries the bank's reference")
        paid_total = sum((Decimal(line["gross"]) for line in paid_lines), Decimal("0"))
        report = ops1.post(f"/v1/payout/windows/{window['id']}/reconcile")
        check(
            report["balanced"] and Decimal(report["paid_total"]) == paid_total and report["reconciled_at"],
            "reconciled to the paisa",
        )
        export = w1.get(f"/v1/payout/statements/{window['id']}/export", format="csv")
        check(export.count(",paid,") >= 2, "worker1's statement export lists this run's paid earnings")
        ref = str(paying["rail_reference"])
        self.until("payout notice", lambda: "payout_paid" in self._inbox_kinds(w1))
        paid_now = self._totals(w1).get("paid", Decimal("0")) - before["w1"].get("paid", Decimal("0"))
        check(paid_now >= Decimal("56"), "statement shows this run's 56 paid")
        margin = [m for m in ops1.get("/v1/payout/margin") if m.get("batch_id") == batch["id"]]
        check(len(margin) == 1, "margin report carries the batch")
        return {
            "project_id": project["id"],
            "batch_id": batch["id"],
            "window_id": window["id"],
            "paid_total": str(paid_total),
            "rail_reference": ref,
            "margin": margin[0],
            "result": "PASS",
        }

    @staticmethod
    def _drop_stale_holds(*reviewers: Gateway) -> None:
        """A run cut short can leave a reviewer holding a task; each holds one at a time, so give it back first."""
        for reviewer in reviewers:
            try:
                held = reviewer.get("/v1/quality/reviews/active")
            except GatewayError as e:
                if e.status != 404:
                    raise
                continue
            reviewer.post(f"/v1/quality/reviews/{held['id']}/release")

    def _next_task(self, reviewer: Gateway, batch_id: str) -> Any:
        """Claims the next review task of this run's batch (other runs' leftovers are not ours to judge), waiting for
        the submitted event to reach quality."""
        deadline = time.monotonic() + self.wait_seconds
        while True:
            try:
                return reviewer.post("/v1/quality/reviews/claim", batch_id=batch_id)
            except GatewayError as e:
                if e.status != 404 or time.monotonic() > deadline:
                    raise
                self.sleep(1.0)

    @staticmethod
    def _inbox_kinds(worker: Gateway) -> list[str]:
        return [str(n["kind"]) for n in worker.get("/v1/notify/inbox")]

    def _close_a_fresh_window(self, ops: Gateway) -> Any:
        """A window at least a week ahead (past the first-payout hold); the next one when a run already closed it."""
        for weeks in range(52):
            as_of = saturday_after(datetime.now(UTC), 8 + 7 * weeks).isoformat()
            try:
                return ops.post("/v1/payout/windows/close", {"currency": "INR", "as_of": as_of})
            except GatewayError as e:
                if e.status != 409:
                    raise
        raise SmokeFailed("no free pay window in the next year")

    @staticmethod
    def _totals(worker: Gateway) -> dict[str, Decimal]:
        return {k: Decimal(v) for k, v in worker.get("/v1/payout/statement")["totals"].items()}

    def _earned(self, worker: Gateway, before: dict[str, Decimal]) -> Decimal:
        """What this run added to the worker's statement, whatever its status."""
        now = self._totals(worker)
        return sum(now.values(), Decimal("0")) - sum(before.values(), Decimal("0"))

    @staticmethod
    def _manifest(ops: Gateway, batch_id: str) -> Any:
        try:
            return ops.get(f"/v1/batches/{batch_id}/manifest")
        except GatewayError as e:
            if e.code == "batch_held":
                return None
            raise
