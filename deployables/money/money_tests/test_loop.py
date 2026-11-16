"""The whole Stage 1 loop, end to end, through the real event bus:
claim -> submit -> review -> canonical accept -> earning -> window closed -> two finance approvals -> pay -> the rail
pays each line (dispatch and poll jobs) -> window paid -> reconciled to the paisa -> statement exported. Needs the
local Postgres and NATS. The audit sample is pinned, never rolled; the rail is the deterministic fake."""

import asyncio
import uuid
from collections.abc import Awaitable, Callable
from datetime import datetime, timedelta
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from yantra_common.consumer import run_round
from yantra_common.events import STREAM, Bus, encode
from yantra_common.testing import NATS_URL
from yantra_market.models import WorkUnit
from yantra_market.service import claim_unit, import_units, publish_batch, submit
from yantra_market.testing import eligible_worker, good_lines, make_batch, make_project
from yantra_money.app import create_app
from yantra_money.events import build as build_money
from yantra_money.events import jobs as money_jobs
from yantra_payout.models import Earning, WorkerAccount
from yantra_payout.paying import poll_processing
from yantra_payout.rails.fake import FakeRail
from yantra_payout.service import IST
from yantra_payout.testing import accepted, published, verified_account
from yantra_quality import service as quality_service
from yantra_quality.models import ReviewerGate
from yantra_quality.service import claim_review, record_review
from yantra_work.events import build as build_work

OPS = {"X-Role": "ops,finance"}


SCENARIO_DEADLINE_SECONDS = 600


def with_bus(scenario: Callable[[Bus], Awaitable[None]]) -> None:
    async def main() -> None:
        bus = await Bus.connect(NATS_URL)
        try:
            await bus.js.delete_stream(STREAM)
            await bus.ensure_stream()
            await scenario(bus)
        finally:
            await bus.close()

    # a deadline on the whole scenario: a stalled bus fails the test instead of holding the suite for hours
    asyncio.run(asyncio.wait_for(main(), timeout=SCENARIO_DEADLINE_SECONDS))


async def pump(bus: Bus, parts, rounds: int = 30) -> None:
    """Run rounds until two quiet rounds in a row, so timing never decides a test."""
    quiet = 0
    for _ in range(rounds):
        done = 0
        for consumers, relays in parts:
            done += await run_round(bus, consumers, relays)
        quiet = quiet + 1 if done == 0 else 0
        if quiet >= 2:
            break


def a_saturday_after(now: datetime) -> datetime:
    """An instant whose preceding completed week contains `now`: the next Saturday strictly after today."""
    days = (5 - now.weekday()) % 7 or 7
    return (now + timedelta(days=days)).replace(hour=10, minute=0, second=0, microsecond=0)


def ops_as(worker: uuid.UUID) -> dict[str, str]:
    return {**OPS, "X-Worker-Id": str(worker)}


@pytest.mark.parametrize("sampled", [False, True])
def test_the_whole_loop_moves_money_only_on_the_canonical_accept(factory, monkeypatch, sampled):
    monkeypatch.setattr(quality_service, "sampled_for_audit", lambda unit_id, percent=10: sampled)
    rail = FakeRail()
    client = TestClient(create_app(factory, rate_limit_per_minute=1000, rail=rail))
    with factory() as s:
        project = make_project(s)
        batch = make_batch(s, project)
        import_units(s, batch.id, good_lines(3), dry_run=False)
        publish_batch(s, batch.id)
        s.commit()
        worker, reviewer, auditor = eligible_worker(s), eligible_worker(s), eligible_worker(s)
        for who in (worker, reviewer, auditor):
            verified_account(s, who)
        for who in (reviewer, auditor):  # reviewers hold the project's gate
            s.add(ReviewerGate(worker_id=who, gate=project.cert_gate, source="assess", at=datetime.now(IST)))
        # three units: one accepted, one rejected (client caused, billable), one left unreviewed
        for key in ("loop-00001", "loop-00002", "loop-00003"):
            c = claim_unit(s, batch.id, worker, idempotency_key=key)
            s.commit()
            submit(s, c.id, worker, {"transcript": key})
            s.commit()
        batch_id = batch.id

    async def scenario(bus: Bus) -> None:
        parts = [build_work(factory, bus), build_money(factory, bus)]
        await pump(bus, parts)
        with factory() as s:
            first = claim_review(s, reviewer)
            record_review(s, first.id, reviewer, "accept")
            s.commit()
            second = claim_review(s, reviewer)
            record_review(s, second.id, reviewer, "reject", reason_code="client_ambiguous_instruction")
            s.commit()
            accepted_unit, rejected_unit = first.unit_id, second.unit_id
            if sampled:  # the auditor's verdict wins
                audit = claim_review(s, auditor, kind="audit")
                assert audit.id == first.id
                record_review(s, audit.id, auditor, "accept")
                s.commit()
        await pump(bus, parts)
        with factory() as s:
            assert s.get(WorkUnit, accepted_unit).status == "accepted"
            back = s.get(WorkUnit, rejected_unit)  # a verdict against the work returns the unit for rework
            assert back.status == "available" and back.current_claim_id is None
            by_kind: dict[str, Decimal] = {}
            for e in s.scalars(select(Earning)):
                by_kind[e.kind] = by_kind.get(e.kind, Decimal(0)) + e.amount
            assert by_kind["unit"] == Decimal("28")  # one accepted unit; nothing for the rejected one
            assert by_kind["review"] == Decimal("12")  # two reviews
            assert by_kind.get("audit") == (Decimal("6") if sampled else None)
            for account in s.scalars(select(WorkerAccount)):
                account.first_paid_at = datetime.now(IST) - timedelta(days=30)
            s.commit()
        expected_gross = Decimal("46") if sampled else Decimal("40")
        as_of = a_saturday_after(datetime.now(IST))
        r = client.post("/v1/payout/windows/close", json={"currency": "INR", "as_of": as_of.isoformat()}, headers=OPS)
        assert r.status_code == 201, r.text
        window = r.json()
        assert Decimal(window["gross_total"]) == expected_gross and Decimal(window["held_total"]) == 0
        wid = window["id"]
        payer = ops_as(uuid.uuid4())
        assert client.post(f"/v1/payout/windows/{wid}/pay", headers=payer).status_code == 409  # not approved yet
        lead, cfo = uuid.uuid4(), uuid.uuid4()
        assert client.post(f"/v1/payout/windows/{wid}/approve", headers=ops_as(lead)).json()["status"] == "closed"
        r = client.post(f"/v1/payout/windows/{wid}/approve", headers=ops_as(lead))
        assert r.status_code == 409 and r.json()["code"] == "already_approved"
        assert client.post(f"/v1/payout/windows/{wid}/approve", headers={**OPS, "X-Approver": "x"}).status_code == 422
        assert client.post(f"/v1/payout/windows/{wid}/approve", headers=ops_as(cfo)).json()["status"] == "approved"
        r = client.post(f"/v1/payout/windows/{wid}/pay", headers=payer)
        assert r.status_code == 200 and r.json()["status"] == "paying"
        schedule = {j.name: j for j in money_jobs(factory, rail)}
        assert schedule["payout_dispatch"].run() == (3 if sampled else 2)
        poll_processing(factory, rail, now=datetime.now(IST) + timedelta(minutes=5))
        lines = {line["worker_id"]: line for line in client.get(f"/v1/payout/windows/{wid}/lines", headers=OPS).json()}
        assert Decimal(lines[str(worker)]["gross"]) == 28 and Decimal(lines[str(reviewer)]["gross"]) == 12
        assert (str(auditor) in lines) is sampled
        assert {line["status"] for line in lines.values()} == {"paid"} and all(x["utr"] for x in lines.values())
        assert client.get(f"/v1/payout/windows/{wid}", headers=OPS).json()["status"] == "paid"
        r = client.post(f"/v1/payout/windows/{wid}/reconcile", headers=OPS)
        report = r.json()
        assert report["balanced"] is True and Decimal(report["delta"]) == 0 and report["reconciled_at"]
        export = client.get(
            f"/v1/payout/statements/{wid}/export", headers={"X-Role": "worker", "X-Worker-Id": str(worker)}
        )
        assert export.status_code == 200 and ",28.00,INR," in export.text
        statement = client.get("/v1/payout/statement", headers={"X-Role": "worker", "X-Worker-Id": str(worker)}).json()
        assert statement["totals"] == {"paid": "28.00"} and len(statement["earnings"]) == 1
        [row] = [m for m in client.get("/v1/payout/margin", headers=OPS).json() if m["batch_id"] == str(batch_id)]
        assert row["units_accepted"] == 1 and row["billable_rework_units"] == 1 and row["invoice"] == "60.00"
        assert row["cost_audit"] == ("6.00" if sampled else "0.00")
        await pump(bus, parts)
        assert client.get("/ready").json() == {
            "status": "ok",
            "outbox_unpublished": {"payout": 0},
            "outbox_stale": False,
        }

    with_bus(scenario)


def test_a_verdict_that_arrives_before_its_rate_is_retried_until_the_rate_lands(factory):
    """Different subjects have no ordering: the payout consumer must survive an accept before a publish."""
    batch_id = uuid.uuid4()
    worker, reviewer = uuid.uuid4(), uuid.uuid4()

    async def scenario(bus: Bus) -> None:
        consumers, relays = build_money(factory, bus, nak_delay=0.2)
        acc = accepted(batch_id, worker, reviewer)
        await bus.publish(acc.id, acc.type, encode(acc.id, acc.type, acc.subject, acc.occurred_at, acc.data))
        await pump(bus, [(consumers, relays)], rounds=3)
        with factory() as s:
            assert s.scalar(select(Earning)) is None
        pub = published(batch_id)
        await bus.publish(pub.id, pub.type, encode(pub.id, pub.type, pub.subject, pub.occurred_at, pub.data))
        await asyncio.sleep(1.0)
        await pump(bus, [(consumers, relays)], rounds=12)
        with factory() as s:
            assert {e.kind for e in s.scalars(select(Earning))} == {"unit", "review"}

    with_bus(scenario)


def test_ops_routes_envelopes_and_the_money_limiter(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000))
    assert client.post("/v1/payout/windows/close", json={"currency": "INR"}).status_code == 403
    assert client.get("/v1/payout/margin", headers={"X-Role": "worker"}).status_code == 403
    assert client.get("/v1/payout/margin", headers={"X-Role": "ops"}).status_code == 200  # Odoo reads as ops
    r = client.post("/v1/payout/windows/close", json={"currency": "INR"}, headers={"X-Role": "ops"})
    assert (r.status_code, r.json()["message"]) == (403, "finance role required")
    r = client.get(f"/v1/payout/windows/{uuid.uuid4()}/reconcile", headers=OPS)
    assert r.status_code == 404 and r.json()["code"] == "not_found"
    r = client.put(
        f"/v1/payout/accounts/{uuid.uuid4()}/hold",
        json={"reason": "duplicate_account"},
        headers={**OPS, "X-Worker-Id": str(uuid.uuid4())},
    )
    assert r.status_code == 200 and r.json()["hold_reason"] == "duplicate_account"
    naive = {"currency": "INR", "as_of": "2026-11-02T10:00:00"}
    r = client.post("/v1/payout/windows/close", json=naive, headers=OPS)
    assert r.status_code == 422 and r.json()["fields"] == ["body.as_of"]
    assert client.post("/v1/payout/windows/close", json={"currency": "=1+"}, headers=OPS).status_code == 422
    assert client.get("/v1/payout/statement", headers={"X-Role": "worker"}).status_code == 422
    assert client.get("/health").json() == {"status": "ok"}
    tight = TestClient(create_app(factory, rate_limit_per_minute=1))
    h = {"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4())}
    assert tight.get("/v1/payout/statement", headers=h).status_code == 200
    assert tight.get("/v1/payout/statement", headers=h).status_code == 429
