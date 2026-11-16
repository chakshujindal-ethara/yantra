"""The loop across modules through NATS: a submission becomes a review task, a verdict closes the unit.
Needs the local NATS: docker compose -f deployment/local/compose.yaml up -d nats"""

import asyncio
import uuid
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime

from sqlalchemy import func, select, update

from yantra_common.consumer import run_round
from yantra_common.events import STREAM, Bus, Envelope
from yantra_common.testing import NATS_URL
from yantra_market.consumers import on_verdict_accepted
from yantra_market.models import CONSUMED, OUTBOX, WorkUnit
from yantra_market.service import claim_unit, import_units, publish_batch, submit
from yantra_market.testing import eligible_worker, good_lines, make_batch, make_project
from yantra_notify.models import Notification
from yantra_notify.testing import FakeMailer, verified_channel
from yantra_quality import service as quality_service
from yantra_quality.models import ReviewTask
from yantra_quality.service import claim_review, record_review, upsert_reviewer_gate
from yantra_work.events import build, jobs

SCENARIO_DEADLINE_SECONDS = 600


def with_bus(scenario: Callable[[Bus], Awaitable[None]]) -> None:
    """Everything that touches NATS runs on one event loop, against a freshly recreated stream."""

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


async def pump(bus: Bus, consumers, relays, rounds: int = 30) -> int:
    """Run rounds until two quiet rounds in a row (or `rounds`), so timing never decides a test."""
    total, quiet = 0, 0
    for _ in range(rounds):
        done = await run_round(bus, consumers, relays)
        total += done
        quiet = quiet + 1 if done == 0 else 0
        if quiet >= 2:
            break
    return total


async def pump_until(bus: Bus, consumers, relays, done: Callable[[], bool], deadline: float = 120.0) -> None:
    """Pump until `done()` holds: quiet rounds alone can end before a busy machine delivers the last event, so a
    test that needs an outcome waits for that outcome, never past `deadline` seconds."""
    loop = asyncio.get_running_loop()
    stop = loop.time() + deadline
    while not done():
        assert loop.time() < stop, "the expected outcome did not arrive before the deadline"
        await pump(bus, consumers, relays, rounds=3)


def unsampled_unit() -> uuid.UUID:
    while True:
        u = uuid.uuid4()
        if not quality_service.sampled_for_audit(u):
            return u


def submitted_unit(factory, key: str) -> tuple[uuid.UUID, uuid.UUID]:
    with factory() as s:
        project = make_project(s)
        batch = make_batch(s, project)
        import_units(s, batch.id, good_lines(1), dry_run=False)
        # outside the audit sample, so one review decides it (a random id is sampled one run in ten)
        s.execute(update(WorkUnit).where(WorkUnit.batch_id == batch.id).values(id=unsampled_unit()))
        publish_batch(s, batch.id)
        s.commit()
        worker = eligible_worker(s)
        claim = claim_unit(s, batch.id, worker, idempotency_key=key)
        s.commit()
        submit(s, claim.id, worker, {"transcript": "namaste"})
        s.commit()
        return claim.unit_id, worker


def test_submission_flows_to_quality_and_the_verdict_flows_back_and_into_the_inbox(factory):
    unit_id, worker = submitted_unit(factory, "e2e-00001")
    mailer = FakeMailer()
    with factory() as s:
        verified_channel(s, worker, "worker@example.test")
        s.commit()

    async def scenario(bus: Bus) -> None:
        consumers, relays = build(factory, bus)
        [email] = [j for j in jobs(factory, mailer) if j.name == "notify_email"]
        await pump(bus, consumers, relays)
        with factory() as s:
            assert s.scalar(select(func.count()).select_from(OUTBOX).where(OUTBOX.c.published_at.is_(None))) == 0
            task = s.scalar(select(ReviewTask).where(ReviewTask.unit_id == unit_id))
            assert task is not None and task.worker_id == worker and task.status == "pending"
            reviewer = eligible_worker(s)
            upsert_reviewer_gate(s, reviewer, task.cert_gate, "ops", task.created_at)  # gated work needs the gate
            task = claim_review(s, reviewer)
            record_review(s, task.id, reviewer, "accept")
            s.commit()
        await pump(bus, consumers, relays)

        def noted() -> bool:
            with factory() as s:
                return s.scalar(select(func.count()).select_from(Notification)) == 1

        await pump_until(bus, consumers, relays, noted)
        assert email.run() == 1  # the scheduler's email job, off the relay round
        with factory() as s:
            assert s.get(WorkUnit, unit_id).status == "accepted"
            assert s.scalar(select(func.count()).select_from(CONSUMED)) == 1
            [note] = s.scalars(select(Notification)).all()
            assert note.worker_id == worker and note.kind == "verdict_accepted" and note.emailed_at is not None
        assert [(to, subject) for to, subject, _ in mailer.sent] == [("worker@example.test", "Your work was accepted")]
        # a replay of the whole stream changes nothing: every consumer is idempotent
        consumers2, relays2 = build(factory, bus)
        for c in consumers2:
            c.durable = c.durable + "-replay"
        await pump(bus, consumers2, relays2)
        with factory() as s:
            assert s.get(WorkUnit, unit_id).status == "accepted"
            assert s.scalar(select(func.count()).select_from(ReviewTask)) == 1
            assert s.scalar(select(func.count()).select_from(Notification)) == 1
        assert email.run() == 0 and len(mailer.sent) == 1

    with_bus(scenario)


def test_a_failing_handler_is_retried_not_lost(factory, caplog):
    unit_id, _ = submitted_unit(factory, "retry-00001")
    calls = {"n": 0}
    real = quality_service.on_unit_submitted

    def flaky(session, env):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("first delivery fails")
        real(session, env)

    async def scenario(bus: Bus) -> None:
        consumers, relays = build(factory, bus, nak_delay=0.2)
        consumers[0].handler = flaky
        with caplog.at_level("ERROR", logger="yantra.consumer"):
            await run_round(bus, consumers, relays)  # relay, then the first delivery fails
        assert "handler failed" in caplog.text
        with factory() as s:
            assert s.scalar(select(ReviewTask).where(ReviewTask.unit_id == unit_id)) is None
        await asyncio.sleep(0.5)  # past the nak delay; the redelivery succeeds
        await pump(bus, consumers, relays)
        with factory() as s:
            assert s.scalar(select(ReviewTask).where(ReviewTask.unit_id == unit_id)) is not None
        assert calls["n"] == 2

    with_bus(scenario)


def test_unknown_or_out_of_state_units_are_logged_not_crashed(factory, caplog):
    env = Envelope(
        id=uuid.uuid4(),
        type="quality.verdict.accepted.v1",
        subject="unit/x",
        occurred_at=datetime.now(UTC),
        data={
            "unit_id": str(uuid.uuid4()),
            "batch_id": str(uuid.uuid4()),
            "submission_id": str(uuid.uuid4()),
            "worker_id": str(uuid.uuid4()),
            "reviewer_id": str(uuid.uuid4()),
            "auditor_id": None,
            "rubric_version": "v1",
        },
    )
    with factory() as s, caplog.at_level("WARNING", logger="yantra.market"):
        on_verdict_accepted(s, env)
        assert s.scalar(select(func.count()).select_from(WorkUnit)) == 0
    assert "unknown unit" in caplog.text


def test_rejected_verdicts_and_out_of_state_units_are_handled(factory, caplog):
    from yantra_market.consumers import on_verdict_rejected
    from yantra_market.service import claim_unit, import_units, publish_batch
    from yantra_market.testing import eligible_worker, good_lines, make_batch, make_project

    with factory() as s:
        batch = make_batch(s, make_project(s))
        import_units(s, batch.id, good_lines(1), dry_run=False)
        publish_batch(s, batch.id)
        s.commit()
        c = claim_unit(s, batch.id, eligible_worker(s), idempotency_key="rej-000001")
        s.commit()
        env = Envelope(
            id=uuid.uuid4(),
            type="quality.verdict.rejected.v1",
            subject="unit/x",
            occurred_at=datetime.now(UTC),
            data={
                "unit_id": str(c.unit_id),
                "batch_id": str(batch.id),
                "submission_id": str(uuid.uuid4()),
                "worker_id": str(c.worker_id),
                "reviewer_id": str(uuid.uuid4()),
                "auditor_id": None,
                "rubric_version": "v1",
                "verdict": "needs_edits",
                "reason_code": "incomplete",
                "billable": False,
            },
        )
        with caplog.at_level("WARNING", logger="yantra.market"):
            on_verdict_rejected(s, env)  # the unit is still 'claimed', not 'submitted'
        s.commit()
        assert s.get(WorkUnit, c.unit_id).status == "claimed"  # untouched
    assert "verdict ignored" in caplog.text
