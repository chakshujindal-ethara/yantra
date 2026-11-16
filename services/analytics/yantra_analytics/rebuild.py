"""The rebuild drill, carried out by the events process (it owns the subscription), as a relay that runs every
round. A request moves to the next generation: the marts and the consumed ids are emptied (`purge` also deletes
the warehouse rows the stream still holds), the old durable is deleted and the consumer starts a fresh one at
sequence 1. The drill is done when the new durable has nothing pending; the mart cursor is reset, so the next
refresh recomputes everything.

Stated limit: the stream keeps 30 days, so a replay reaches back 30 days; `repair` (the default) keeps every older
warehouse row."""

import logging
from datetime import timedelta

from nats.js.errors import NotFoundError
from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session, sessionmaker

from yantra_analytics import marts, service
from yantra_analytics.models import CONSUMED, MARTS, Event
from yantra_common.consumer import Consumer
from yantra_common.db import unit_of_work
from yantra_common.events import RETENTION_SECONDS, STREAM, Bus

log = logging.getLogger("yantra.analytics")


class RebuildWatcher:
    def __init__(self, factory: sessionmaker[Session], bus: Bus, consumer: Consumer) -> None:
        self.factory, self.bus, self.consumer = factory, bus, consumer

    async def __call__(self) -> int:
        with unit_of_work(self.factory) as session:
            doc = {"generation": 0, "status": "idle", **service.read_control(session, "rebuild")}
        current = service.durable_name(int(doc["generation"]))
        if self.consumer.durable != current:
            self.consumer.resubscribe(current)
        if doc["status"] == "requested":
            await self.start(doc)
            return 1
        if doc["status"] == "running":
            await self.finish_when_caught_up(doc)
        return 0

    async def start(self, doc: dict[str, object]) -> None:
        old = self.consumer.durable
        generation = int(str(doc["generation"])) + 1
        now = service.now_utc()
        with unit_of_work(self.factory) as session:
            session.execute(delete(CONSUMED))
            for mart in MARTS:
                session.execute(delete(mart))
            if doc.get("mode") == "purge":
                session.execute(delete(Event).where(Event.time >= now - timedelta(seconds=RETENTION_SECONDS)))
            marts.reset_cursor(session, now)
            service.write_control(
                session,
                "rebuild",
                {**doc, "generation": generation, "status": "running", "started_at": now.isoformat()},
                now,
            )
        try:
            await self.bus.js.delete_consumer(STREAM, old)
        except NotFoundError:
            pass
        self.consumer.resubscribe(service.durable_name(generation))
        log.info("rebuild started generation=%d mode=%s", generation, doc.get("mode"))

    async def finish_when_caught_up(self, doc: dict[str, object]) -> None:
        try:
            info = await self.bus.js.consumer_info(STREAM, self.consumer.durable)
        except NotFoundError:
            return  # the consumer has not subscribed yet this round
        if info.num_pending or info.num_ack_pending:
            return
        now = service.now_utc()
        with unit_of_work(self.factory) as session:
            events = int(session.scalar(select(func.count()).select_from(Event)) or 0)
            service.write_control(
                session, "rebuild", {**doc, "status": "done", "finished_at": now.isoformat(), "events": events}, now
            )
        log.info("rebuild done generation=%s events=%d", doc["generation"], events)
