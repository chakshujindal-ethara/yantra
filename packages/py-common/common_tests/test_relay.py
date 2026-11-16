"""The relay against a bus that fails: nothing is marked published, the error reaches the caller."""

import asyncio
import uuid
from datetime import UTC, datetime

import pytest
from sqlalchemy import Column, DateTime, MetaData, String, Table, Uuid, create_engine, func, insert, select, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import sessionmaker

from yantra_common.relay import relay_once, relay_pass
from yantra_common.testing import ADMIN_URL


class BrokenBus:
    async def publish(self, event_id, type_, payload):
        raise ConnectionError("nats is down")


@pytest.fixture
def outbox():
    engine = create_engine(ADMIN_URL, future=True)
    md = MetaData(schema="relay_test")
    table = Table(
        "outbox",
        md,
        Column("id", Uuid, primary_key=True),
        Column("type", String(120)),
        Column("subject", String(200)),
        Column("payload", JSONB),
        Column("occurred_at", DateTime(timezone=True)),
        Column("published_at", DateTime(timezone=True)),
    )
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA IF EXISTS relay_test CASCADE"))
        c.execute(text("CREATE SCHEMA relay_test"))
    md.create_all(engine)
    with engine.begin() as c:
        c.execute(
            insert(table).values(id=uuid.uuid4(), type="t.v1", subject="s", payload={}, occurred_at=datetime.now(UTC))
        )
    yield table, sessionmaker(bind=engine)
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA relay_test CASCADE"))
    engine.dispose()


def test_a_failed_publish_leaves_the_row_unpublished(outbox):
    table, factory = outbox
    with pytest.raises(ConnectionError):
        asyncio.run(relay_once(factory, table, BrokenBus()))
    with factory() as s:
        assert s.scalar(select(table.c.published_at)) is None


class RecordingBus:
    def __init__(self) -> None:
        self.published: list[str] = []

    async def publish(self, event_id, type_, payload):
        self.published.append(type_)


def test_rows_are_published_in_occurred_at_then_id_order_and_limited(outbox):
    table, factory = outbox
    t0 = datetime(2026, 1, 1, tzinfo=UTC)
    ids = [uuid.UUID(int=3), uuid.UUID(int=1), uuid.UUID(int=2)]
    with factory() as s:
        s.execute(text("DELETE FROM relay_test.outbox"))
        for i, (eid, when) in enumerate(zip(ids, [t0, t0, t0.replace(year=2025)], strict=True)):
            s.execute(insert(table).values(id=eid, type=f"t{i}.v1", subject="s", payload={}, occurred_at=when))
        s.commit()
    bus = RecordingBus()
    assert asyncio.run(relay_pass(factory, table, bus, limit=2)) == 2
    assert bus.published == ["t2.v1", "t1.v1"]  # 2025 first, then the lower id among equal times
    assert asyncio.run(relay_pass(factory, table, bus)) == 1
    assert bus.published[-1] == "t0.v1"
    with factory() as s:
        assert s.scalar(select(func.count()).select_from(table).where(table.c.published_at.is_(None))) == 0


def rows(factory, table, n: int) -> list[uuid.UUID]:
    ids = [uuid.uuid4() for _ in range(n)]
    with factory() as s:
        s.execute(text("DELETE FROM relay_test.outbox"))
        now = datetime.now(UTC)
        s.execute(insert(table), [dict(id=i, type="t.v1", subject="s", payload={}, occurred_at=now) for i in ids])
        s.commit()
    return ids


def unpublished(factory, table) -> set[uuid.UUID]:
    with factory() as s:
        return set(s.scalars(select(table.c.id).where(table.c.published_at.is_(None))))


def test_a_publish_that_is_not_acked_leaves_its_row_unpublished_and_the_acked_ones_marked(outbox):
    table, factory = outbox
    ids = rows(factory, table, 5)

    class FlakyBus:
        async def publish(self, event_id, type_, payload):
            if event_id == ids[2]:
                raise TimeoutError("no ack")

    with pytest.raises(TimeoutError):
        asyncio.run(relay_once(factory, table, FlakyBus()))
    assert unpublished(factory, table) == {ids[2]}  # at-least-once: only the unacked row goes again
    assert asyncio.run(relay_once(factory, table, RecordingBus())) == 1 and unpublished(factory, table) == set()


def test_the_relay_drains_a_backlog_in_full_batches_within_its_budget(outbox):
    table, factory = outbox
    rows(factory, table, 7)
    bus = RecordingBus()
    assert asyncio.run(relay_once(factory, table, bus, limit=2)) == 7  # 2 + 2 + 2 + 1: passes until one is short
    rows(factory, table, 7)
    ticks = iter([0.0, 0.0, 9.0])  # the budget is spent after the second pass
    assert asyncio.run(relay_once(factory, table, bus, limit=2, budget_seconds=5, clock=lambda: next(ticks))) == 4
    assert len(unpublished(factory, table)) == 3  # left for the next turn of the loop


def test_five_thousand_rows_reach_the_test_nats_in_one_relay_turn(outbox):
    """Against the test NATS (4223): 5,000 rows in one bounded turn, every one acked and marked."""
    import time

    from yantra_common.events import STREAM, Bus
    from yantra_common.testing import NATS_URL

    table, factory = outbox
    ids = [uuid.uuid4() for _ in range(5000)]
    with factory() as s:
        s.execute(text("DELETE FROM relay_test.outbox"))
        now = datetime.now(UTC)
        s.execute(
            insert(table),
            [dict(id=i, type="analytics.fxrelay.v1", subject="s", payload={"n": 1}, occurred_at=now) for i in ids],
        )
        s.commit()

    async def scenario() -> tuple[int, float, int]:
        bus = await Bus.connect(NATS_URL)
        try:
            await bus.js.purge_stream(STREAM, subject="analytics.fxrelay.v1")
            start = time.perf_counter()
            relayed = await relay_once(factory, table, bus, budget_seconds=30)
            took = time.perf_counter() - start
            info = await bus.js.stream_info(STREAM, subjects_filter="analytics.fxrelay.v1")
            stored = (info.state.subjects or {}).get("analytics.fxrelay.v1", 0)
            await bus.js.purge_stream(STREAM, subject="analytics.fxrelay.v1")
            return relayed, took, stored
        finally:
            await bus.close()

    relayed, took, stored = asyncio.run(scenario())
    assert relayed == 5000 and stored == 5000 and unpublished(factory, table) == set()
    assert took < 10, f"5,000 rows took {took:.1f}s"  # about 0.3 s on a laptop; 50 rows a turn before
