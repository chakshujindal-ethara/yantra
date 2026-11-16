"""Gate `delivery-gate`: a batch with one unit sent back is held at the delivery gate (409 batch_held with the
counts); once its author redoes it and it is accepted, the manifest builds, and the deliverable written to object
storage has one line per accepted unit and the checksum the manifest recorded."""

import hashlib
import json
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import httpx

from yantra_cli.gates import GateAborted, GateResult
from yantra_cli.gates.direct import Actor, Direct, DirectError
from yantra_cli.gates.storm import published_batch

UNITS = 3


@dataclass
class DeliveryGate:
    api: Direct
    http: httpx.Client
    wait_seconds: float = 120.0
    sleep: Callable[[float], None] = time.sleep

    def run(self) -> GateResult:
        ops = Actor.new("ops")
        authors = [Actor.new("worker"), Actor.new("worker")]
        reviewers = [Actor.new("worker,reviewer"), Actor.new("worker,reviewer")]
        tag = ops.id[:6]
        batch_id = published_batch(self.api, ops, f"delivery-{tag}", UNITS)
        for w in authors + reviewers:
            self.api.put(ops, f"/v1/workers/{w.id}", {"status": "eligible", "cert_gates": []})
        owner: dict[str, Actor] = {}
        for n in range(UNITS):
            author = authors[n % 2]
            claim = self.api.post(author, f"/v1/batches/{batch_id}/claims")
            self.api.post(author, f"/v1/claims/{claim['id']}/submission", {"answer": {"text": f"answer {n}"}})
            owner[str(claim["unit_id"])] = author
        sent_back = ""
        for n in range(UNITS):
            task = self._next(reviewers[0], batch_id, "review")
            if n == 0:
                verdict = {"verdict": "needs_edits", "reason_code": "client_glossary_change"}
                sent_back = str(task["unit_id"])
            else:
                verdict = {"verdict": "accept"}
            done = self.api.post(reviewers[0], f"/v1/quality/tasks/{task['id']}/review", verdict)
            self._audit_if_sampled(done, reviewers[1], batch_id)
        held = self._held(ops, batch_id)
        author = owner[sent_back]
        redo = self._until_claimable(author, batch_id)
        self.api.post(author, f"/v1/claims/{redo['id']}/submission", {"answer": {"text": "fixed"}})
        task = self._next(reviewers[0], batch_id, "review")
        done = self.api.post(reviewers[0], f"/v1/quality/tasks/{task['id']}/review", {"verdict": "accept"})
        self._audit_if_sampled(done, reviewers[1], batch_id)
        manifest = self._manifest(ops, batch_id)
        got = self.api.get(ops, f"/v1/batches/{batch_id}/deliverable")
        body = self.http.get(got["jsonl"]["url"]).content
        lines = [ln for ln in body.decode().splitlines() if ln.strip()]
        sha = hashlib.sha256(body).hexdigest()
        stored = json.loads(self.http.get(got["manifest"]["url"]).content)
        figures = {
            "held_status": held[0],
            "held_counts": held[1],
            "redo_unit_back_to_author": redo["unit_id"] == sent_back,
            "accepted_units": manifest["accepted_units"],
            "deliverable_lines": len(lines),
            "sha256_matches": sha == got["jsonl"]["sha256"],
            "manifest_digest": got["digest"] == manifest["digest"] == stored.get("digest"),
            "batch_id": batch_id,
        }
        passed = (
            held[0] == 409
            and bool(held[1])
            and figures["redo_unit_back_to_author"] is True
            and manifest["accepted_units"] == UNITS == len(lines)
            and figures["sha256_matches"] is True
            and figures["manifest_digest"] is True
        )
        return GateResult("delivery-gate", passed, figures)

    def _wait(self, what: str, probe: Callable[[], Any]) -> Any:
        deadline = time.monotonic() + self.wait_seconds
        while True:
            got = probe()
            if got is not None:
                return got
            if time.monotonic() > deadline:
                raise GateAborted(f"timed out waiting for {what}")
            self.sleep(1.0)

    def _next(self, reviewer: Actor, batch_id: str, kind: str) -> Any:
        def probe() -> Any:
            try:
                return self.api.post(reviewer, "/v1/quality/reviews/claim", kind=kind, batch_id=batch_id)
            except DirectError as e:
                if e.status != 404:
                    raise
                return None

        return self._wait(f"a {kind} task", probe)

    def _audit_if_sampled(self, done: Any, auditor: Actor, batch_id: str) -> None:
        """Only accepts are sampled for audit; the auditor agrees, so the accept stands."""
        if done["status"] == "audit_pending":
            task = self._next(auditor, batch_id, "audit")
            self.api.post(auditor, f"/v1/quality/tasks/{task['id']}/review", {"verdict": "accept"})

    def _held(self, ops: Actor, batch_id: str) -> tuple[int, dict[str, Any]]:
        """The manifest must be refused while a unit is out; the counts say which."""
        try:
            self.api.get(ops, f"/v1/batches/{batch_id}/manifest")
        except DirectError as e:
            if e.code != "batch_held":
                raise
            return e.status, dict(e.body.get("held", {}))
        return 200, {}

    def _until_claimable(self, author: Actor, batch_id: str) -> Any:
        def probe() -> Any:
            try:
                return self.api.post(author, f"/v1/batches/{batch_id}/claims")
            except DirectError as e:
                if e.status != 404:
                    raise
                return None

        return self._wait("the unit sent back to reach its author", probe)

    def _manifest(self, ops: Actor, batch_id: str) -> Any:
        def probe() -> Any:
            try:
                return self.api.get(ops, f"/v1/batches/{batch_id}/manifest")
            except DirectError as e:
                if e.code != "batch_held":
                    raise
                return None

        return self._wait("the manifest after the redo", probe)
