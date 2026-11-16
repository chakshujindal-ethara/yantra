import uuid
from dataclasses import dataclass

import pytest
from nats.js.errors import NotFoundError
from sqlalchemy import func, select

from yantra_analytics import marts, service
from yantra_analytics.models import CONSUMED, Event, MartProjectDay
from yantra_analytics.rebuild import RebuildWatcher
from yantra_common.consumer import Consumer
from yantra_common.errors import Conflict

from .conftest import NOW, ids
from .test_marts import a_day


@dataclass
class Info:
    num_pending: int
    num_ack_pending: int


class FakeJs:
    def __init__(self) -> None:
        self.deleted: list[str] = []
        self.info: Info | None = None

    async def delete_consumer(self, stream: str, name: str) -> None:
        self.deleted.append(name)
        if name.endswith("g0"):
            raise NotFoundError

    async def consumer_info(self, stream: str, name: str) -> Info:
        if self.info is None:
            raise NotFoundError
        return self.info


class FakeBus:
    def __init__(self) -> None:
        self.js = FakeJs()


def test_a_rebuild_is_requested_once_at_a_time(session):
    assert service.rebuild_state(session).status == "idle"
    by = uuid.uuid4()
    out = service.request_rebuild(session, "repair", by, NOW)
    assert (out.status, out.mode, out.requested_by, out.generation) == ("requested", "repair", str(by), 0)
    with pytest.raises(Conflict) as e:
        service.request_rebuild(session, "purge", by, NOW)
    assert e.value.code == "rebuild_running"


def run(coro):
    import asyncio

    return asyncio.run(coro)


def test_the_watcher_moves_to_a_new_generation_and_finishes_when_caught_up(session, wh, factory):
    project, batch = ids(2)
    a_day(wh, project, batch)
    session.execute(CONSUMED.insert().values(id=uuid.uuid4(), type="x", consumed_at=NOW))
    session.commit()
    marts.refresh_marts(factory, NOW)
    bus = FakeBus()
    consumer = Consumer("analytics", ">", service.ingest, factory, CONSUMED, CONSUMED, durable="stale-name")
    watcher = RebuildWatcher(factory, bus, consumer)
    assert run(watcher()) == 0 and consumer.durable == "analytics-all-g0"  # idle: only the name is fixed
    service.request_rebuild(session, "repair", uuid.uuid4(), NOW)
    session.commit()
    assert run(watcher()) == 1
    session.expire_all()
    assert consumer.durable == "analytics-all-g1" and bus.js.deleted == ["analytics-all-g0"]
    assert session.scalar(select(func.count()).select_from(CONSUMED)) == 0
    assert session.scalar(select(func.count()).select_from(MartProjectDay)) == 0
    assert session.scalar(select(func.count()).select_from(Event)) > 0  # repair keeps the warehouse
    assert service.read_control(session, "refresh")["last_at"] == service.EPOCH.isoformat()
    assert service.rebuild_state(session).status == "running"
    assert run(watcher()) == 0  # not subscribed yet
    bus.js.info = Info(num_pending=3, num_ack_pending=0)
    assert run(watcher()) == 0 and service.rebuild_state(session).status == "running"
    bus.js.info = Info(num_pending=0, num_ack_pending=0)
    run(watcher())
    session.expire_all()
    done = service.rebuild_state(session)
    assert done.status == "done" and done.events and done.generation == 1
    # a second drill, purging: the warehouse rows inside the stream's horizon go too
    service.request_rebuild(session, "purge", uuid.uuid4(), NOW)
    session.commit()
    run(watcher())
    session.expire_all()
    assert bus.js.deleted[-1] == "analytics-all-g1" and consumer.durable == "analytics-all-g2"
    recent = session.scalar(select(func.count()).select_from(Event).where(Event.time >= NOW))
    assert recent == 0
