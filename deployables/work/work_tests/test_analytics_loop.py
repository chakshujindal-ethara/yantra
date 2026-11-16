"""Analytics over NATS: the wildcard consumer stores every event the loop publishes beside the domain consumers,
and the rebuild drill replays the stream into a fresh durable with the same result.
Needs the test NATS (4223)."""

import uuid

from sqlalchemy import func, select

from yantra_analytics import service
from yantra_analytics.models import Event
from yantra_market.models import OUTBOX as MARKET_OUTBOX
from yantra_quality.models import OUTBOX as QUALITY_OUTBOX
from yantra_work.events import build

from .test_events import pump, submitted_unit, with_bus


def published(s) -> int:
    return sum(
        int(s.scalar(select(func.count()).select_from(t).where(t.c.published_at.is_not(None))) or 0)
        for t in (MARKET_OUTBOX, QUALITY_OUTBOX)
    )


def test_every_published_event_lands_in_the_warehouse_and_survives_a_rebuild(factory):
    submitted_unit(factory, "analytics-0001")

    async def scenario(bus) -> None:
        consumers, relays = build(factory, bus)
        await pump(bus, consumers, relays)
        with factory() as s:
            events = s.scalar(select(func.count()).select_from(Event))
            assert events == published(s) and events >= 3
            types = set(s.scalars(select(Event.type)))
            assert {"work.unit.published.v1", "work.unit.claimed.v1", "work.unit.submitted.v1"} <= types
            service.request_rebuild(s, "purge", uuid.uuid4(), service.now_utc())
            s.commit()
        await pump(bus, consumers, relays, rounds=60)
        await pump(bus, consumers, relays, rounds=10)  # the drill notices it has caught up
        with factory() as s:
            state = service.rebuild_state(s)
            assert state.status == "done" and state.generation == 1 and state.events == events
            assert s.scalar(select(func.count()).select_from(Event)) == events

    with_bus(scenario)
