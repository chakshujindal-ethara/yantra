"""What an operator does about the background: read the dead letters of a module and replay one after the cause is
fixed, read the module's job schedule, and get one ERROR line per new dead letter from a periodic job.

A dead row keeps the message bytes and the consumer's durable name. The handler's transaction rolled back, so the
event id is not in `consumed_event` and the same handler can run it again; a replay that finds the id consumed
(another delivery got through meanwhile) still clears the row and says so (`fresh: false`). The payload is never
returned: it carries worker ids and, for a submission, the task's content."""

import logging
import uuid
from collections.abc import Mapping
from datetime import datetime, timedelta
from typing import Any

from fastapi import APIRouter, Request
from pydantic import BaseModel, ConfigDict
from sqlalchemy import Table, delete, select
from sqlalchemy.orm import Session, sessionmaker

from yantra_common.consumer import Consumer, Handler, handle_in_transaction
from yantra_common.db import unit_of_work
from yantra_common.deps import DB, AdminOrOps
from yantra_common.errors import Conflict, NotFound
from yantra_common.events import Envelope
from yantra_common.scheduler import Job, read_state, write_state

log = logging.getLogger("yantra.deadletters")


class DeadLetterOut(BaseModel):
    id: uuid.UUID
    consumer: str
    type: str | None
    subject: str | None
    deliveries: int
    reason: str
    dead_at: datetime


class ReplayOut(BaseModel):
    replayed: bool
    fresh: bool


class JobOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    name: str
    next_run_at: datetime
    last_run_at: datetime | None
    last_finished_at: datetime | None
    last_result: int | None
    last_error: str | None
    locked_until: datetime | None


def _decode(raw: bytes) -> Envelope | None:
    try:
        return Envelope.from_bytes(raw)
    except (ValueError, KeyError, TypeError):
        return None


def dead_letter_router(prefix: str, dead: Table, consumed: Table, handlers: Mapping[str, Handler]) -> APIRouter:
    """`GET {prefix}` lists the newest 200; `POST {prefix}/{id}/replay` runs the row's handler again.
    `handlers` maps a consumer's durable name to its handler."""
    router = APIRouter(prefix=prefix, tags=["operations"], dependencies=[AdminOrOps])

    @router.get("", response_model=list[DeadLetterOut])
    def list_dead(session: DB) -> list[DeadLetterOut]:
        rows = session.execute(select(dead).order_by(dead.c.dead_at.desc()).limit(200)).all()
        out = []
        for r in rows:
            env = _decode(r.raw)
            out.append(
                DeadLetterOut(
                    id=r.id,
                    consumer=r.consumer,
                    type=env.type if env else None,
                    subject=env.subject if env else None,
                    deliveries=r.deliveries,
                    reason=r.reason,
                    dead_at=r.dead_at,
                )
            )
        return out

    @router.post("/{dead_id}/replay", response_model=ReplayOut)
    def replay(dead_id: uuid.UUID, request: Request) -> ReplayOut:
        factory = request.app.state.factory
        with factory() as session:
            row = session.execute(select(dead).where(dead.c.id == dead_id)).first()
        if row is None:
            raise NotFound("no such dead letter", id=str(dead_id))
        env = _decode(row.raw)
        if env is None:
            raise Conflict("the message cannot be decoded; it cannot be replayed").with_code("undecodable")
        handler = handlers.get(row.consumer)
        if handler is None:
            raise Conflict("no consumer by that name runs here", consumer=row.consumer).with_code("no_handler")
        fresh = handle_in_transaction(factory, consumed, handler, env)
        with unit_of_work(factory) as session:
            session.execute(delete(dead).where(dead.c.id == dead_id))
        log.info("dead letter replayed consumer=%s event_id=%s fresh=%s", row.consumer, env.id, fresh)
        return ReplayOut(replayed=True, fresh=fresh)

    return router


def jobs_router(prefix: str, lease: Table) -> APIRouter:
    """`GET {prefix}`: every job of the module with its schedule and last outcome."""
    router = APIRouter(prefix=prefix, tags=["operations"], dependencies=[AdminOrOps])

    @router.get("", response_model=list[JobOut])
    def list_jobs(session: DB) -> list[Any]:
        return list(session.execute(select(lease).order_by(lease.c.name)).all())

    return router


def alert_new_dead_letters(session: Session, job: Job, dead_tables: list[Table], limit: int = 500) -> int:
    """One ERROR line per dead letter newer than the job's high-water mark, then move the mark. The first run
    reports every row once. Returns how many it reported."""
    state = read_state(session, job)
    mark = datetime.fromisoformat(state["mark"]) if "mark" in state else None
    latest = mark
    reported = 0
    for t in dead_tables:
        q = select(t.c.id, t.c.consumer, t.c.reason, t.c.dead_at).order_by(t.c.dead_at).limit(limit)
        if mark is not None:
            q = q.where(t.c.dead_at > mark)
        for r in session.execute(q):
            log.error("dead letter waiting schema=%s consumer=%s id=%s reason=%s", t.schema, r.consumer, r.id, r.reason)
            reported += 1
            latest = r.dead_at if latest is None or r.dead_at > latest else latest
    if latest is not None and latest != mark:
        write_state(session, job, {**state, "mark": latest.isoformat()})
    return reported


def handlers_of(consumers: list[Consumer], module: str) -> dict[str, Handler]:
    """The replay table of one module: each of its consumers' durable names to the handler."""
    return {c.durable: c.handler for c in consumers if c.module == module}


def alert_job(factory: sessionmaker[Session], name: str, lease: Table, dead_tables: list[Table]) -> Job:
    """The periodic job that turns each new dead letter into one ERROR line (every five minutes)."""

    def run() -> int:
        with unit_of_work(factory) as session:
            return alert_new_dead_letters(session, job, dead_tables)

    job = Job(name, run, lease, every=timedelta(minutes=5))
    return job
