"""The outbox relay: reads unpublished rows of one module's outbox in order, publishes them, marks the acked ones.
At-least-once by construction: a row is marked only after JetStream acked it, so an unacked row (or a crash between
publish and mark) is published again; JetStream dedups on the id and consumers dedup on it too. Rows are locked
with SKIP LOCKED so two relays never fight.

Throughput: a pass takes up to 500 rows and issues their publishes together (one ack round trip per pass, not per
row), and `relay_once` keeps passing while full batches come back, inside a time budget, so a backlog drains in one
turn of the events loop instead of one small batch per turn (the loop also waits on every consumer between turns)."""

import asyncio
import logging
import time
from collections.abc import Callable
from datetime import UTC, datetime

from sqlalchemy import Table, select, update
from sqlalchemy.orm import Session, sessionmaker

from yantra_common.events import Bus, encode

log = logging.getLogger("yantra.relay")
BATCH = 500
BUDGET_SECONDS = 5.0  # one relay's share of an events-loop turn; the consumers get theirs after it


async def relay_pass(factory: sessionmaker[Session], outbox: Table, bus: Bus, limit: int = BATCH) -> int:
    """Publish up to `limit` rows at once and mark those JetStream acked; returns how many were marked. When any
    publish failed the acked ones are still marked (committed) and the first error is raised after."""
    session = factory()
    try:
        rows = session.execute(
            select(outbox)
            .where(outbox.c.published_at.is_(None))
            .order_by(outbox.c.occurred_at, outbox.c.id)
            .limit(limit)
            .with_for_update(skip_locked=True)
        ).all()
        results = await asyncio.gather(
            *(
                bus.publish(row.id, row.type, encode(row.id, row.type, row.subject, row.occurred_at, row.payload))
                for row in rows
            ),
            return_exceptions=True,
        )
        acked = [row.id for row, result in zip(rows, results, strict=True) if not isinstance(result, BaseException)]
        if acked:
            session.execute(update(outbox).where(outbox.c.id.in_(acked)).values(published_at=datetime.now(UTC)))
        session.commit()
        if acked:
            log.info("relayed outbox=%s count=%d", outbox.fullname, len(acked))
        failed = [r for r in results if isinstance(r, BaseException)]
        if failed:
            log.warning("relay publishes failed outbox=%s failed=%d acked=%d", outbox.fullname, len(failed), len(acked))
            raise failed[0]
        return len(acked)
    except BaseException:
        session.rollback()
        raise
    finally:
        session.close()


async def relay_once(
    factory: sessionmaker[Session],
    outbox: Table,
    bus: Bus,
    limit: int = BATCH,
    budget_seconds: float = BUDGET_SECONDS,
    clock: Callable[[], float] = time.monotonic,
) -> int:
    """Passes until one comes back short (the backlog is under a batch) or the budget is spent; returns how many
    rows were published. Bounded, so a large backlog never starves the consumers that share the loop."""
    deadline = clock() + budget_seconds
    total = 0
    while True:
        n = await relay_pass(factory, outbox, bus, limit)
        total += n
        if n < limit or clock() >= deadline:
            return total
