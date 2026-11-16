"""Gate `claim-storm`: N eligible workers race for M units of one published batch. The plan's gate: zero double
claims, every unit claimed exactly once, claim p99 under 500 ms (1.5x the largest cohort: 500 workers, 2,000 units)."""

import math
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

from yantra_cli.gates import GateResult
from yantra_cli.gates.direct import Actor, Direct, DirectError

SCHEMA = {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}
IMPORT_CHUNK = 1000


def percentile(values: list[float], q: float) -> float:
    """Nearest-rank percentile (q in 0..100); 0 for no values."""
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(1, math.ceil(q / 100 * len(ordered)))
    return ordered[rank - 1]


def published_batch(api: Direct, ops: Actor, name: str, units: int, pay: str = "1", price: str = "2") -> str:
    """A project, one batch of `units` units, published: the shared setup of the load gates."""
    project = api.post(ops, "/v1/projects", {"name": name, "currency": "INR", "payload_schema": SCHEMA})
    batch = api.post(
        ops,
        f"/v1/projects/{project['id']}/batches",
        {"title": name, "unit_pay": pay, "unit_price": price, "review_pay": "2", "claim_ttl_minutes": 120},
    )
    for start in range(0, units, IMPORT_CHUNK):
        lines = [
            {"external_ref": f"{name}-{i}", "payload": {"text": f"unit {i}"}}
            for i in range(start, min(start + IMPORT_CHUNK, units))
        ]
        api.post(ops, f"/v1/batches/{batch['id']}/units/import", {"lines": lines}, dry_run="false")
    api.post(ops, f"/v1/batches/{batch['id']}/publish")
    return str(batch["id"])


@dataclass
class ClaimStorm:
    api: Direct
    workers: int = 500
    units: int = 2000
    concurrency: int = 64
    p99_ms: float = 500.0
    latencies: list[float] = field(default_factory=list)
    claimed: dict[str, list[str]] = field(default_factory=dict)
    errors: Counter[str] = field(default_factory=Counter)

    def run(self) -> GateResult:
        ops = Actor.new("ops")
        tag = Actor.new("x").id[:6]
        batch_id = published_batch(self.api, ops, f"Load test · claim storm {tag}", self.units)
        crowd = [Actor.new("worker") for _ in range(self.workers)]
        for w in crowd:
            self.api.put(ops, f"/v1/workers/{w.id}", {"status": "eligible", "cert_gates": []})
        lock = threading.Lock()

        def one(worker: Actor) -> None:
            while True:
                t0 = time.perf_counter()
                try:
                    claim = self.api.post(worker, f"/v1/batches/{batch_id}/claims")
                except DirectError as e:
                    with lock:
                        self.latencies.append((time.perf_counter() - t0) * 1000)
                        if e.status != 404:
                            self.errors[f"claim {e.status} {e.code}"] += 1
                    return  # 404: nothing left for this worker
                with lock:
                    self.latencies.append((time.perf_counter() - t0) * 1000)
                    self.claimed.setdefault(str(claim["unit_id"]), []).append(worker.id)
                try:
                    self.api.post(worker, f"/v1/claims/{claim['id']}/submission", {"answer": {"text": "ok"}})
                except DirectError as e:
                    with lock:
                        self.errors[f"submit {e.status} {e.code}"] += 1

        t0 = time.perf_counter()
        with ThreadPoolExecutor(max_workers=self.concurrency) as pool:
            list(pool.map(one, crowd))
        wall = time.perf_counter() - t0
        summary = self.api.get(ops, f"/v1/batches/{batch_id}")
        doubles = sum(1 for holders in self.claimed.values() if len(holders) > 1)
        submitted = int(summary["units"]["submitted"]) + int(summary["units"].get("in_review", 0))
        p99 = percentile(self.latencies, 99)
        figures = {
            "workers": self.workers,
            "units": self.units,
            "claimed_once": sum(1 for h in self.claimed.values() if len(h) == 1),
            "double_claims": doubles,
            "units_submitted": submitted,
            "live_claims_left": summary["live_claims"],
            "p50_ms": round(percentile(self.latencies, 50)),
            "p95_ms": round(percentile(self.latencies, 95)),
            "p99_ms": round(p99),
            "claims_per_s": round(len(self.claimed) / wall, 1) if wall else 0,
            "wall_s": round(wall, 1),
            "errors": dict(self.errors),
            "batch_id": batch_id,
        }
        passed = (
            doubles == 0
            and len(self.claimed) == self.units
            and submitted == self.units
            and summary["live_claims"] == 0
            and p99 < self.p99_ms
            and not self.errors
        )
        notes = [] if p99 < self.p99_ms else [f"p99 {p99:.0f} ms is over the {self.p99_ms:.0f} ms target"]
        return GateResult("claim-storm", passed, figures, notes)
