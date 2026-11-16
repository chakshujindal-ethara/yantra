"""Idempotent event consumers. Each module keeps a `consumed_event` table on its own schema; the event id is
inserted in the same transaction as the handler's writes, so a redelivered event is a no-op and a failed
handler leaves nothing behind. The message is acked only after the commit.

A failing message is redelivered with a delay that doubles per attempt (5 s, 10 s, ... capped at an hour, so
twenty attempts span hours); after the last attempt it is written to the module's `dead_event` table, logged at
ERROR and terminated, so nothing is ever dropped without a record.
A message that cannot even be decoded is dead-lettered at once."""

import asyncio
import logging
import uuid
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import TYPE_CHECKING

from nats.aio.msg import Msg
from nats.errors import TimeoutError as NatsTimeout
from nats.js import JetStreamContext
from pydantic import ValidationError
from sqlalchemy import DateTime, Integer, LargeBinary, String, Table, Text, Uuid, insert
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.sql.schema import Column, MetaData

from yantra_common.events import DEAD_LETTER_AFTER, Bus, Envelope
from yantra_common.metrics import CONSUMER_HANDLED, CONSUMER_OLDEST, Observer, Probe

log = logging.getLogger("yantra.consumer")
Handler = Callable[[Session, Envelope], None]


def consumed_table(metadata: MetaData, schema: str) -> Table:
    return Table(
        "consumed_event",
        metadata,
        Column("id", Uuid, primary_key=True),
        Column("type", String(120), nullable=False),
        Column("consumed_at", DateTime(timezone=True), nullable=False),
        schema=schema,
    )


def dead_table(metadata: MetaData, schema: str) -> Table:
    """Where a message goes after its last failed delivery. Someone reads this table; nothing is lost."""
    return Table(
        "dead_event",
        metadata,
        Column("id", Uuid, primary_key=True),
        Column("consumer", String(200), nullable=False),
        Column("deliveries", Integer, nullable=False),
        Column("reason", Text, nullable=False),
        Column("raw", LargeBinary, nullable=False),
        Column("dead_at", DateTime(timezone=True), nullable=False),
        schema=schema,
    )


def handle_in_transaction(factory: sessionmaker[Session], consumed: Table, handler: Handler, env: Envelope) -> bool:
    """Run one handler for one event in one transaction. Returns False when the event was already consumed."""
    session = factory()
    try:
        try:
            with session.begin_nested():
                session.execute(insert(consumed).values(id=env.id, type=env.type, consumed_at=datetime.now(UTC)))
        except IntegrityError:
            session.rollback()
            return False
        handler(session, env)
        session.commit()
        return True
    except BaseException:
        session.rollback()
        raise
    finally:
        session.close()


def _reason(e: BaseException) -> str:
    """Never the payload: a validation error's text would echo the event's fields."""
    return type(e).__name__ if isinstance(e, ValidationError) else f"{type(e).__name__}: {e}"[:500]


class Consumer:
    """One durable pull consumer: a module name, a subject, a handler."""

    def __init__(
        self,
        module: str,
        subject: str,
        handler: Handler,
        factory: sessionmaker[Session],
        consumed: Table,
        dead: Table,
        nak_delay: float = 5.0,
        max_nak_delay: float = 3600.0,
        durable: str | None = None,
    ) -> None:
        """`durable` names the JetStream consumer; by default it is derived from the module and the subject, which
        a wildcard subject (`>`) cannot do, so a wildcard consumer names its own."""
        self.module, self.subject, self.handler, self.factory = module, subject, handler, factory
        self.consumed, self.dead, self.nak_delay, self.max_nak_delay = consumed, dead, nak_delay, max_nak_delay
        self.durable = durable or f"{module}-{subject.replace('.', '-')}"
        self._sub: JetStreamContext.PullSubscription | None = None

    def resubscribe(self, durable: str) -> None:
        """Read from another durable from the next fetch on (a replay drill starts a fresh one at sequence 1)."""
        self.durable, self._sub = durable, None

    async def subscription(self, bus: Bus) -> JetStreamContext.PullSubscription:
        if self._sub is None:
            self._sub = await bus.pull_subscription(self.durable, self.subject)
        return self._sub

    def redelivery_delay(self, deliveries: int) -> float:
        return float(min(self.max_nak_delay, self.nak_delay * 2 ** (deliveries - 1)))

    def dead_letter(self, raw: bytes, event_id: object, deliveries: int, reason: str) -> None:
        with self.factory() as session:
            session.execute(
                insert(self.dead).values(
                    id=event_id or uuid.uuid4(),
                    consumer=self.durable,
                    deliveries=deliveries,
                    reason=reason,
                    raw=raw,
                    dead_at=datetime.now(UTC),
                )
            )
            session.commit()
        log.error(
            "dead-lettered consumer=%s event_id=%s deliveries=%d reason=%s", self.durable, event_id, deliveries, reason
        )

    async def _dead(self, msg: Msg, event_id: uuid.UUID | None, deliveries: int, reason: str) -> None:
        """Store the message as a dead letter, then end its redelivery. When the store fails the message is naked,
        never acked or terminated: the server redelivers it (MAX_DELIVER leaves room past DEAD_LETTER_AFTER)."""
        try:
            self.dead_letter(msg.data, event_id, deliveries, reason)
        except IntegrityError:  # stored on an earlier delivery whose terminate never reached the server
            log.info("dead letter already stored consumer=%s event_id=%s", self.durable, event_id)
        except SQLAlchemyError as e:
            log.error(
                "dead letter not stored, redelivering consumer=%s event_id=%s delivery=%d error=%s",
                self.durable,
                event_id,
                deliveries,
                type(e).__name__,
            )
            await msg.nak(delay=self.redelivery_delay(deliveries))
            CONSUMER_HANDLED.labels(self.durable, "naked").inc()
            return
        await msg.term()
        CONSUMER_HANDLED.labels(self.durable, "dead").inc()

    async def run_once(self, bus: Bus, batch: int = 50, wait: float = 0.5) -> int:
        """Pull up to `batch` messages, handle each, ack on success, nak on failure, dead-letter on the last
        failure or on a message that cannot be decoded. Returns the handled count."""
        sub = await self.subscription(bus)
        try:
            msgs = await sub.fetch(batch, timeout=wait)
        except NatsTimeout:
            CONSUMER_OLDEST.labels(self.durable).set(0)
            return 0
        handled = 0
        log.debug("fetched consumer=%s count=%d", self.durable, len(msgs))
        CONSUMER_OLDEST.labels(self.durable).set(oldest_age(msgs, datetime.now(UTC)))
        for msg in msgs:
            deliveries = int(msg.metadata.num_delivered or 1)
            try:
                env = Envelope.from_bytes(msg.data)
            except (ValueError, KeyError, TypeError) as e:
                await self._dead(msg, None, deliveries, "undecodable: " + _reason(e))
                continue
            try:
                fresh = handle_in_transaction(self.factory, self.consumed, self.handler, env)
            except Exception as e:
                if deliveries >= DEAD_LETTER_AFTER:
                    await self._dead(msg, env.id, deliveries, _reason(e))
                    continue
                if isinstance(e, ValidationError):
                    log.error(
                        "handler rejected consumer=%s event_id=%s delivery=%d reason=%s",
                        self.durable,
                        env.id,
                        deliveries,
                        _reason(e),
                    )
                else:
                    log.exception(
                        "handler failed consumer=%s event_id=%s delivery=%d", self.durable, env.id, deliveries
                    )
                await msg.nak(delay=self.redelivery_delay(deliveries))
                CONSUMER_HANDLED.labels(self.durable, "naked").inc()
                continue
            await msg.ack()
            handled += 1
            CONSUMER_HANDLED.labels(self.durable, "acked" if fresh else "duplicate").inc()
            if not fresh:
                log.info("duplicate skipped consumer=%s event_id=%s", self.durable, env.id)
        return handled


def oldest_age(msgs: Sequence[object], now: datetime) -> float:
    """Seconds since the oldest fetched message was stored in the stream: how far behind this consumer is. NATS
    hands the stream time over without a zone; it is UTC."""
    stamps = [
        t if t.tzinfo else t.replace(tzinfo=UTC)
        for m in msgs
        if isinstance(t := getattr(getattr(m, "metadata", None), "timestamp", None), datetime)
    ]
    return max(0.0, (now - min(stamps)).total_seconds()) if stamps else 0.0


Relay = Callable[[], Awaitable[int]]
Build = Callable[[sessionmaker[Session], Bus], tuple[list[Consumer], list[Relay]]]


@dataclass
class LoopState:
    """What the events process's `/ready` reads: when the last round finished cleanly and how many failed since."""

    last_round_at: datetime | None = None
    failures: int = 0

    def ok(self, at: datetime) -> None:
        self.last_round_at, self.failures = at, 0

    def failed(self) -> int:
        self.failures += 1
        return self.failures


async def run_round(bus: Bus, consumers: list[Consumer], relays: list[Relay]) -> int:
    """Relay every outbox, then serve every consumer at once. Each consumer keeps its own order (one fetch at a time,
    acked in order); serving them together lets an idle consumer's fetch wait overlap the others, so a round costs one
    wait instead of one per consumer. A failing consumer fails the round, as before; the others finish theirs."""
    busy = 0
    for relay in relays:
        busy += await relay()
    results = await asyncio.gather(*(c.run_once(bus) for c in consumers), return_exceptions=True)
    for r in results:
        if isinstance(r, BaseException):
            raise r
        busy += r
    return busy


def backoff_after(failures: int, cap: float = 60.0) -> float:
    return float(min(cap, 2**failures))


async def run_forever(  # pragma: no cover - an endless loop; run_round and backoff_after are the tested units
    bus: Bus, consumers: list[Consumer], relays: list[Relay], idle: float = 0.5, state: LoopState | None = None
) -> None:
    """The event loop of a deployable: relay every outbox, then serve every consumer, and keep going.
    An error (NATS or Postgres away) is logged once per round and backed off; the process never exits."""
    state = state or LoopState()
    while True:
        try:
            busy = await run_round(bus, consumers, relays)
        except Exception:
            failures = state.failed()
            log.exception("event round failed failures=%d", failures)
            await asyncio.sleep(backoff_after(failures))
            continue
        state.ok(datetime.now(UTC))
        if not busy:
            await asyncio.sleep(idle)


if TYPE_CHECKING:
    from fastapi import FastAPI

    from yantra_common.config import Settings
    from yantra_common.scheduler import Job

JobsFor = Callable[[sessionmaker[Session]], list["Job"]]


def probe(
    factory: sessionmaker[Session],
    outboxes: Sequence[Table],
    dead_tables: Sequence[Table],
    jobs: Sequence["Job"],
    observers: Sequence[Observer] = (),
) -> Probe:
    """The metrics relay of an events process: its outboxes, dead letters and job leases, then the deployable's own
    invariants."""
    from yantra_common.metrics import observe_dead, observe_jobs, observe_outboxes

    return Probe(factory, [observe_outboxes(outboxes), observe_dead(dead_tables), observe_jobs(jobs), *observers])


def health_app(
    s: "Settings",
    factory: sessionmaker[Session],
    outboxes: Sequence[Table],
    dead_tables: Sequence[Table],
    jobs: list["Job"],
    state: LoopState,
    connected: Callable[[], bool],
) -> "FastAPI":
    """The events process's own `/health`, `/ready` and `/metrics`, with the process's stuck-outbox threshold."""
    from yantra_common.app import events_app

    return events_app(
        factory,
        list(outboxes),
        list(dead_tables),
        jobs,
        state,
        connected,
        outbox_stuck_after_seconds=s.outbox_stuck_seconds,
    )


async def serve(  # pragma: no cover - the process entry point of every events runner
    build: Build,
    jobs: JobsFor | None = None,
    outboxes: Sequence[Table] = (),
    dead_tables: Sequence[Table] = (),
    process: str = "events",
    observers: Sequence[Observer] = (),
) -> None:
    """Wire settings, the database and the bus, then run three things side by side: the consumers and relays (with
    the metrics probe among them), the leased scheduler, and the process's own `/health`, `/ready` and `/metrics`
    on `YANTRA_EVENTS_PORT`."""
    import uvicorn

    from yantra_common.boot import boot
    from yantra_common.config import settings
    from yantra_common.db import make_engine, make_session_factory
    from yantra_common.scheduler import Scheduler, register

    boot(process)
    s = settings()
    factory = make_session_factory(make_engine(str(s.database_url)))
    bus = await Bus.connect(s.nats_url)
    consumers, relays = build(factory, bus)
    job_list = jobs(factory) if jobs else []
    register(factory, job_list)
    relays = [*relays, probe(factory, outboxes, dead_tables, job_list, observers)]
    state = LoopState()
    health = health_app(s, factory, outboxes, dead_tables, job_list, state, lambda: bus.nc.is_connected)
    server = uvicorn.Server(uvicorn.Config(health, host="0.0.0.0", port=s.events_port, log_level="warning"))
    scheduler = Scheduler(factory, job_list, concurrency=s.scheduler_concurrency)
    try:
        await asyncio.gather(run_forever(bus, consumers, relays, state=state), scheduler.run_forever(), server.serve())
    finally:
        await bus.close()
