"""Gate `money-parity`: W workers and U units through claim, submit, review (and the audit sample), a closed pay
window, two finance approvals and the rail (WireMock as RazorpayX on the rig). The plan's gate: earnings equal
the window lines equal the payouts, to the paisa; the reconciliation is balanced; the margin report equals the
invoice minus every cost line. Pay rates are whole rupees, so no line ends in the emulator's failure paise."""

import threading
import time
from collections import Counter
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any

from yantra_cli.gates import GateAborted, GateResult
from yantra_cli.gates.direct import Actor, Direct, DirectError
from yantra_cli.gates.storm import published_batch
from yantra_cli.smoke import bank_account_for, saturday_after

UNIT_PAY, UNIT_PRICE, REVIEW_PAY = Decimal("10"), Decimal("25"), Decimal("2")


def paisa(value: Any) -> Decimal:
    return Decimal(str(value)).quantize(Decimal("0.01"))


@dataclass
class MoneyParity:
    api: Direct
    workers: int = 50
    units: int = 1000
    concurrency: int = 32
    wait_seconds: float = 900.0
    sleep: Callable[[float], None] = time.sleep
    now: Callable[[], datetime] = lambda: datetime.now(UTC)
    authored: Counter[str] = field(default_factory=Counter)  # accepted units per author
    reviews: Counter[str] = field(default_factory=Counter)
    audits: Counter[str] = field(default_factory=Counter)
    canonical: set[str] = field(default_factory=set)
    errors: Counter[str] = field(default_factory=Counter)

    def until(self, what: str, probe: Callable[[], bool]) -> None:
        deadline = time.monotonic() + self.wait_seconds
        while not probe():
            if time.monotonic() > deadline:
                raise GateAborted(f"timed out waiting for {what}")
            self.sleep(2.0)

    def run(self) -> GateResult:
        ops, fin1, fin2 = Actor.new("ops"), Actor.new("finance"), Actor.new("finance")
        tag = Actor.new("x").id[:6]
        batch_id = published_batch(self.api, ops, f"parity-{tag}", self.units, str(UNIT_PAY), str(UNIT_PRICE))
        crowd = [Actor.new("worker,reviewer") for _ in range(self.workers)]
        for w in crowd:
            self.api.put(ops, f"/v1/workers/{w.id}", {"status": "eligible", "cert_gates": []})
            self.api.put(w, "/v1/payout/accounts/me", {**bank_account_for(w.id), "account_name": "Gate Worker"})
        lock = threading.Lock()
        self._work(batch_id, crowd, lock)
        self._review(batch_id, crowd, lock)
        self.until("bank accounts verified", lambda: all(self._verified(w) for w in crowd))
        self.until("payout to book every verdict", lambda: self._margin(fin1, batch_id) is not None)
        margin = self._margin(fin1, batch_id)
        assert margin is not None  # until() returned
        window = self._close(fin1)
        self.api.post(fin1, f"/v1/payout/windows/{window['id']}/approve")
        self.api.post(fin2, f"/v1/payout/windows/{window['id']}/approve")
        self.api.post(fin1, f"/v1/payout/windows/{window['id']}/pay")
        ids = {w.id for w in crowd}
        self.until("the rail to settle the gate's lines", lambda: self._settled(fin1, window["id"], ids))
        lines = [ln for ln in self.api.get(fin1, f"/v1/payout/windows/{window['id']}/lines") if ln["worker_id"] in ids]
        run = self.api.post(fin1, f"/v1/payout/windows/{window['id']}/reconcile")
        return self._judge(crowd, lines, run, margin, window)

    def _work(self, batch_id: str, crowd: list[Actor], lock: threading.Lock) -> None:
        def one(worker: Actor) -> None:
            while True:
                try:
                    claim = self.api.post(worker, f"/v1/batches/{batch_id}/claims")
                except DirectError as e:
                    if e.status != 404:
                        with lock:
                            self.errors[f"claim {e.status}"] += 1
                    return
                self.api.post(worker, f"/v1/claims/{claim['id']}/submission", {"answer": {"text": "done"}})
                with lock:
                    self.authored[worker.id] += 1

        with ThreadPoolExecutor(max_workers=self.concurrency) as pool:
            list(pool.map(one, crowd))

    def _review(self, batch_id: str, crowd: list[Actor], lock: threading.Lock) -> None:
        deadline = time.monotonic() + self.wait_seconds

        def one(reviewer: Actor) -> None:
            while len(self.canonical) < self.units and time.monotonic() < deadline:
                for kind in ("audit", "review"):
                    try:
                        task = self.api.post(reviewer, "/v1/quality/reviews/claim", kind=kind, batch_id=batch_id)
                    except DirectError as e:
                        if e.status != 404:
                            with lock:
                                self.errors[f"{kind} claim {e.status} {e.code}"] += 1
                        continue
                    done = self.api.post(reviewer, f"/v1/quality/tasks/{task['id']}/review", {"verdict": "accept"})
                    with lock:
                        (self.audits if kind == "audit" else self.reviews)[reviewer.id] += 1
                        if done.get("canonical_verdict") == "accept":
                            self.canonical.add(str(done["unit_id"]))
                    break
                else:
                    self.sleep(0.5)

        with ThreadPoolExecutor(max_workers=min(self.concurrency, len(crowd))) as pool:
            list(pool.map(one, crowd))
        if len(self.canonical) < self.units:
            raise GateAborted(f"only {len(self.canonical)} of {self.units} units reached a canonical accept")

    def _verified(self, worker: Actor) -> bool:
        return bool(self.api.get(worker, "/v1/payout/accounts/me")["status"] == "verified")

    def _margin(self, actor: Actor, batch_id: str) -> dict[str, Any] | None:
        """The batch's margin row once payout has booked every verdict (accepted units and judged units)."""
        for row in self.api.get(actor, "/v1/payout/margin"):
            if row["batch_id"] == batch_id and row["units_accepted"] == self.units:
                return dict(row)
        return None

    def _close(self, fin: Actor) -> Any:
        """A window at least a week ahead (past the first-payout hold); the next one when a run already closed it."""
        for weeks in range(104):
            as_of = saturday_after(self.now(), 8 + 7 * weeks).isoformat()
            try:
                return self.api.post(fin, "/v1/payout/windows/close", {"currency": "INR", "as_of": as_of})
            except DirectError as e:
                if e.status != 409:
                    raise
        raise GateAborted("no free pay window in the next two years")

    def _settled(self, fin: Actor, window_id: str, ids: set[str]) -> bool:
        lines = [ln for ln in self.api.get(fin, f"/v1/payout/windows/{window_id}/lines") if ln["worker_id"] in ids]
        return bool(lines) and all(ln["status"] in ("paid", "failed", "returned", "held") for ln in lines)

    def _judge(self, crowd: list[Actor], lines: list[Any], run: Any, margin: dict[str, Any], window: Any) -> GateResult:
        expected = {
            w.id: UNIT_PAY * self.authored[w.id] + REVIEW_PAY * (self.reviews[w.id] + self.audits[w.id]) for w in crowd
        }
        expected = {k: v for k, v in expected.items() if v}
        by_worker = {ln["worker_id"]: ln for ln in lines}
        earned = sum(expected.values(), Decimal(0))
        lined = sum((paisa(ln["gross"]) for ln in lines), Decimal(0))
        paid = sum((paisa(ln["gross"]) for ln in lines if ln["status"] == "paid"), Decimal(0))
        mismatched = [w for w, v in expected.items() if paisa(by_worker.get(w, {}).get("gross", 0)) != paisa(v)]
        not_paid = Counter(ln["status"] for ln in lines if ln["status"] != "paid")
        audits, judged = sum(self.audits.values()), self.units
        invoice = UNIT_PRICE * self.units
        costs = UNIT_PAY * self.units + REVIEW_PAY * judged + REVIEW_PAY * audits
        margin_ok = (
            paisa(margin["invoice"]) == paisa(invoice)
            and paisa(margin["cost_pay"]) == paisa(UNIT_PAY * self.units)
            and paisa(margin["cost_review"]) == paisa(REVIEW_PAY * judged)
            and paisa(margin["cost_audit"]) == paisa(REVIEW_PAY * audits)
            and paisa(margin["margin"]) == paisa(invoice - costs)
        )
        figures = {
            "workers": self.workers,
            "units_accepted": len(self.canonical),
            "audits": audits,
            "earnings": str(paisa(earned)),
            "window_lines": str(paisa(lined)),
            "paid_by_rail": str(paisa(paid)),
            "workers_mismatched": len(mismatched),
            "lines_not_paid": dict(not_paid),
            "reconciliation_balanced": bool(run["balanced"]),
            "delta_lines": str(run["delta"]),  # the API names the earnings-vs-lines difference `delta`
            "delta_rail": str(run["delta_rail"]),
            "invoice": str(paisa(invoice)),
            "margin": str(margin["margin"]),
            "margin_matches": margin_ok,
            "errors": dict(self.errors),
            "window_id": window["id"],
        }
        notes = []
        if not run["balanced"]:
            notes.append("the window holds lines from outside the gate that did not settle; see the reconciliation run")
        passed = (
            paisa(earned) == paisa(lined) == paisa(paid)
            and not mismatched
            and not not_paid
            and bool(run["balanced"])
            and margin_ok
            and not self.errors
        )
        return GateResult("money-parity", passed, figures, notes)
