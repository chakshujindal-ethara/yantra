"""Claim-storm harness: N eligible workers race for M units through the HTTP API.
Passes only with every unit claimed once, zero double claims, p99 under the target and no errors.

  uv run python -m claim_storm --base http://localhost:8081 --workers 500 --units 2000 --p99-ms 500
"""

import argparse
import statistics
import sys
import threading
import time
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

import httpx

SCHEMA = {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}}
OPS = {"X-Role": "ops"}


def seed(base: str, units: int, workers: int) -> tuple[str, list[str]]:
    with httpx.Client(base_url=base, timeout=30, headers=OPS) as c:
        r = c.post("/v1/projects", json={"name": "storm", "currency": "INR", "payload_schema": SCHEMA})
        r.raise_for_status()
        r = c.post(
            f"/v1/projects/{r.json()['id']}/batches", json={"title": "storm", "unit_pay": "1", "unit_price": "2"}
        )
        r.raise_for_status()
        batch_id = str(r.json()["id"])
        for start in range(0, units, 5000):
            stop = min(start + 5000, units)
            lines = [{"external_ref": f"s{i}", "payload": {"text": "x"}} for i in range(start, stop)]
            c.post(
                f"/v1/batches/{batch_id}/units/import", params={"dry_run": "false"}, json={"lines": lines}
            ).raise_for_status()
        c.post(f"/v1/batches/{batch_id}/publish", json={}).raise_for_status()
        ids = [str(uuid.uuid4()) for _ in range(workers)]
        for w in ids:
            c.put(f"/v1/workers/{w}", json={"status": "eligible", "cert_gates": []}).raise_for_status()
    return batch_id, ids


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8081")
    ap.add_argument("--workers", type=int, default=500)
    ap.add_argument("--units", type=int, default=2000)
    ap.add_argument("--concurrency", type=int, default=64)
    ap.add_argument("--p99-ms", type=float, default=500.0)
    a = ap.parse_args()
    batch_id, workers = seed(a.base, a.units, a.workers)

    lock = threading.Lock()
    latencies: list[float] = []
    claimed: dict[str, list[str]] = {}
    errors: Counter[str] = Counter()
    per_worker = a.units // a.workers + 1

    def record(key: str) -> None:
        with lock:
            errors[key] += 1

    def one(worker: str) -> None:
        with httpx.Client(base_url=a.base, timeout=30, headers={"X-Role": "worker", "X-Worker-Id": worker}) as c:
            for n in range(per_worker):
                t0 = time.perf_counter()
                try:
                    r = c.post(f"/v1/batches/{batch_id}/claims", headers={"Idempotency-Key": f"{worker}-{n:04d}"})
                except httpx.HTTPError as e:
                    record(type(e).__name__)
                    return
                with lock:
                    latencies.append((time.perf_counter() - t0) * 1000)
                if r.status_code == 404:
                    return
                if r.status_code != 201:
                    record(f"claim {r.status_code}")
                    continue
                claim = r.json()
                with lock:
                    claimed.setdefault(claim["unit_id"], []).append(worker)
                try:
                    s = c.post(f"/v1/claims/{claim['id']}/submission", json={"answer": {"ok": True}})
                except httpx.HTTPError as e:
                    record(type(e).__name__)
                    return
                if s.status_code != 201:
                    record(f"submit {s.status_code}")

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=a.concurrency) as pool:
        list(pool.map(one, workers))
    wall = time.perf_counter() - t0
    doubles = sum(1 for ws in claimed.values() if len(ws) > 1)
    p99 = statistics.quantiles(latencies, n=100)[98] if len(latencies) >= 100 else max(latencies)
    print(
        f"units claimed {len(claimed)}/{a.units}  double claims {doubles}  calls {len(latencies)}  "
        f"p50 {statistics.median(latencies):.0f} ms  p99 {p99:.0f} ms  wall {wall:.1f} s  errors {dict(errors)}"
    )
    ok = doubles == 0 and len(claimed) == a.units and p99 <= a.p99_ms and not errors
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
