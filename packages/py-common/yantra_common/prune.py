"""Housekeeping for the bookkeeping tables: published outbox rows and consumed-event ids past their use.
Deletes in chunks so no statement nears the 5 s statement timeout, each chunk its own short transaction; a pass
loops until a table is done or its time budget runs out, so a backlog drains in one daily run instead of 5,000 rows
a day."""

import time
from collections.abc import Callable
from datetime import UTC, datetime, timedelta

from sqlalchemy import Table, delete, select
from sqlalchemy.orm import Session, sessionmaker

from yantra_common.db import unit_of_work
from yantra_common.scheduler import At, Job

CHUNK = 5000
BUDGET_SECONDS = 60.0  # one pass of the daily job, across both tables


def _prune(session: Session, table: Table, column: str, cutoff: datetime, limit: int) -> int:
    col = table.c[column]
    key = next(iter(table.primary_key.columns))
    ids = select(key).where(col.is_not(None), col < cutoff).limit(limit).scalar_subquery()
    return int(session.execute(delete(table).where(key.in_(ids))).rowcount or 0)


def prune_published(session: Session, outbox: Table, keep: timedelta, now: datetime, limit: int = CHUNK) -> int:
    """Outbox rows published more than `keep` ago, one chunk. An unpublished row is never touched, however old."""
    return _prune(session, outbox, "published_at", now - keep, limit)


def prune_consumed(session: Session, consumed: Table, keep: timedelta, now: datetime, limit: int = CHUNK) -> int:
    """Consumed-event ids older than `keep`, one chunk: JetStream redelivers within hours, the stream keeps thirty
    days."""
    return _prune(session, consumed, "consumed_at", now - keep, limit)


Chunk = Callable[[Session, Table, timedelta, datetime, int], int]


def prune_until_done(
    factory: sessionmaker[Session],
    chunk: Chunk,
    table: Table,
    keep: timedelta,
    now: datetime,
    deadline: float,
    clock: Callable[[], float] = time.monotonic,
    limit: int = CHUNK,
) -> int:
    """Chunks, each committed on its own, until one comes back short (the table is done) or `deadline` (on `clock`)
    passes; what is left waits for the next run."""
    pruned = 0
    while clock() < deadline:
        with unit_of_work(factory) as session:
            n = chunk(session, table, keep, now, limit)
        pruned += n
        if n < limit:
            break
    return pruned


def prune_job(
    factory: sessionmaker[Session],
    name: str,
    lease: Table,
    outbox: Table | None,
    consumed: Table,
    budget_seconds: float = BUDGET_SECONDS,
    clock: Callable[[], float] = time.monotonic,
    limit: int = CHUNK,
) -> Job:
    """A module's daily housekeeping at 03:00 IST: consumed ids after thirty days, published outbox rows after seven,
    in chunks until done or `budget_seconds` is spent."""

    def run() -> int:
        now, deadline = datetime.now(UTC), clock() + budget_seconds
        pruned = prune_until_done(factory, prune_consumed, consumed, timedelta(days=30), now, deadline, clock, limit)
        if outbox is not None:
            pruned += prune_until_done(factory, prune_published, outbox, timedelta(days=7), now, deadline, clock, limit)
        return pruned

    return Job(name, run, lease, at=At(3, 0), lease_seconds=600)
