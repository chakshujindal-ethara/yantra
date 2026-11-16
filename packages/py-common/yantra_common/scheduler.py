"""A small leased scheduler for the events processes: interval jobs ("every 30 s") and clock jobs ("03:00 IST",
"Saturday 00:05 IST"). Each module keeps a `job_lease` table on its own schema with one row per job: when it runs
next, when it last ran, what it returned, its last error, and who holds it now. A replica runs a job only after
winning the row in one UPDATE, so two replicas never run the same pass at once; the row also makes the schedule
visible on `/ready` and through `/v1/<module>/jobs`.

Rule: a job is one bounded pass (at most a few hundred rows, SKIP LOCKED). A pass that outlives its lease lets
another replica start the same job, which is wasteful and never wrong under that rule."""

import asyncio
import logging
import os
import socket
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from sqlalchemy import DateTime, Integer, String, Table, Text, select, update
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.sql.schema import Column, MetaData

from yantra_common.db import unit_of_work
from yantra_common.metrics import JOB_DURATION, JOB_FAILURES, JOB_LAST_SUCCESS

IST = ZoneInfo("Asia/Kolkata")
log = logging.getLogger("yantra.scheduler")


def job_lease_table(metadata: MetaData, schema: str) -> Table:
    """Every module that runs jobs owns a `job_lease` table on its own schema with this exact shape."""
    return Table(
        "job_lease",
        metadata,
        Column("name", String(80), primary_key=True),
        Column("next_run_at", DateTime(timezone=True), nullable=False),
        Column("last_run_at", DateTime(timezone=True), nullable=True),
        Column("last_finished_at", DateTime(timezone=True), nullable=True),
        Column("last_result", Integer, nullable=True),
        Column("last_error", Text, nullable=True),
        Column("locked_until", DateTime(timezone=True), nullable=True),
        Column("locked_by", String(120), nullable=True),
        Column("state", JSONB, nullable=False, server_default="{}"),
        schema=schema,
    )


@dataclass(frozen=True)
class At:
    """A clock slot: `hour:minute` in `tz`, every day or on one weekday (Monday is 0)."""

    hour: int
    minute: int
    weekday: int | None = None
    tz: ZoneInfo = IST


@dataclass(frozen=True)
class Job:
    name: str
    run: Callable[[], int | None]  # sync; opens its own sessions; returns a count for the log
    lease: Table
    every: timedelta | None = None
    at: At | None = None
    lease_seconds: int = 120

    def __post_init__(self) -> None:
        if (self.every is None) == (self.at is None):
            raise ValueError(f"job {self.name}: give exactly one of every= or at=")


def next_slot(after: datetime, at: At, inclusive: bool) -> datetime:
    """The first occurrence of `at` at or after (`inclusive`) or strictly after `after`, in UTC."""
    local = after.astimezone(at.tz)
    candidate = local.replace(hour=at.hour, minute=at.minute, second=0, microsecond=0)
    step = timedelta(days=1)
    if at.weekday is not None:
        candidate += timedelta(days=(at.weekday - local.weekday()) % 7)
        step = timedelta(days=7)
    if candidate < local or (candidate == local and not inclusive):
        candidate += step
    return candidate.astimezone(UTC)


def next_run(after: datetime, job: Job, inclusive: bool = False) -> datetime:
    if job.every is not None:
        return after if inclusive else after + job.every
    assert job.at is not None  # __post_init__ guarantees one of the two
    return next_slot(after, job.at, inclusive)


def overdue(job: Job, next_run_at: datetime, now: datetime) -> bool:
    """A job well past its slot: three intervals (at least five minutes) late, or an hour for a clock job."""
    grace = max(3 * job.every, timedelta(minutes=5)) if job.every is not None else timedelta(hours=1)
    return now - next_run_at > grace


def register(factory: sessionmaker[Session], jobs: list[Job], now: datetime | None = None) -> None:
    """One row per job, created once; a known job keeps its schedule across restarts."""
    now = now or datetime.now(UTC)
    with unit_of_work(factory) as session:
        for job in jobs:
            session.execute(
                pg_insert(job.lease)
                .values(name=job.name, next_run_at=next_run(now, job, inclusive=True), state={})
                .on_conflict_do_nothing(index_elements=["name"])
            )


def claim(session: Session, job: Job, now: datetime, holder: str) -> bool:
    """Win the job's row when it is due and nobody holds it. One statement, so two replicas cannot both win."""
    t = job.lease
    won = session.execute(
        update(t)
        .where(t.c.name == job.name, t.c.next_run_at <= now, (t.c.locked_until.is_(None)) | (t.c.locked_until < now))
        .values(locked_until=now + timedelta(seconds=job.lease_seconds), locked_by=holder, last_run_at=now)
        .returning(t.c.name)
    ).first()
    return won is not None


def finish(
    session: Session,
    job: Job,
    now: datetime,
    holder: str,
    result: int | None = None,
    error: str | None = None,
    advance: bool = True,
) -> bool:
    """Record the outcome and the next slot, only while `holder` still holds the row: a pass that outlived its lease
    must not clear the lock of the replica that took the job over. A failing job still advances, so a broken daily
    job never spins; `advance` False keeps the slot (a pass cancelled at shutdown runs again). Returns whether the
    outcome was recorded."""
    t = job.lease
    values: dict[str, Any] = {
        "last_finished_at": now,
        "last_result": result,
        "last_error": error,
        "locked_until": None,
        "locked_by": None,
    }
    if advance:
        values["next_run_at"] = next_run(now, job)
    done = session.execute(
        update(t).where(t.c.name == job.name, t.c.locked_by == holder).values(**values).returning(t.c.name)
    ).first()
    if done is None:
        log.warning("job outcome dropped: the lease passed to another holder name=%s holder=%s", job.name, holder)
    return done is not None


def read_state(session: Session, job: Job) -> dict[str, Any]:
    """A job's own small cursor (a high-water mark), kept on its lease row."""
    state = session.scalar(select(job.lease.c.state).where(job.lease.c.name == job.name))
    return dict(state or {})


def write_state(session: Session, job: Job, state: dict[str, Any]) -> None:
    session.execute(update(job.lease).where(job.lease.c.name == job.name).values(state=state))


def in_session(factory: sessionmaker[Session], fn: Callable[[Session], int | None]) -> Callable[[], int | None]:
    """A job body from a function of a session: one unit of work per pass."""

    def run() -> int | None:
        with unit_of_work(factory) as session:
            return fn(session)

    return run


class Scheduler:
    """Starts due jobs, at most `concurrency` at a time, each in a worker thread so a slow job (an SMTP server that
    does not answer) never holds the relays or the other jobs."""

    def __init__(
        self,
        factory: sessionmaker[Session],
        jobs: list[Job],
        concurrency: int = 2,
        holder: str | None = None,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self.factory, self.jobs, self.concurrency, self.clock = factory, jobs, concurrency, clock
        self.holder = holder or f"{socket.gethostname()}:{os.getpid()}"
        self._running: dict[str, asyncio.Task[None]] = {}

    async def tick(self) -> int:
        """Claim and start what is due; returns how many jobs started."""
        started = 0
        for job in self.jobs:
            if len(self._running) >= self.concurrency:
                break
            if job.name in self._running:
                continue
            now = self.clock()
            with unit_of_work(self.factory) as session:
                won = claim(session, job, now, self.holder)
            if won:
                self._running[job.name] = asyncio.create_task(self._run(job))
                started += 1
        return started

    async def _run(self, job: Job) -> None:
        result: int | None = None
        error: str | None = None
        advance = True
        start = time.perf_counter()
        try:
            result = await asyncio.to_thread(job.run)
            JOB_LAST_SUCCESS.labels(job.name).set(self.clock().timestamp())
            if result:
                log.info("job ran name=%s result=%s", job.name, result)
        except asyncio.CancelledError:
            # shutdown mid-pass: a failure, and the slot stays so the pass runs again (a weekly close is not skipped)
            error, advance = "cancelled", False
            JOB_FAILURES.labels(job.name).inc()
            log.warning("job cancelled name=%s", job.name)
            raise
        except Exception as e:
            error = f"{type(e).__name__}: {e}"[:500]
            JOB_FAILURES.labels(job.name).inc()
            log.exception("job failed name=%s", job.name)
        finally:
            JOB_DURATION.labels(job.name).observe(time.perf_counter() - start)
            try:
                with unit_of_work(self.factory) as session:
                    finish(session, job, self.clock(), self.holder, result, error, advance)
            except Exception:  # the lease lapses on its own; the job runs again after it
                log.exception("job outcome not recorded name=%s", job.name)
            finally:
                self._running.pop(job.name, None)

    async def drain(self) -> None:
        """Wait for every running job (tests and shutdown)."""
        while self._running:
            await asyncio.gather(*list(self._running.values()))

    async def run_forever(self, interval: float = 1.0) -> None:  # pragma: no cover - an endless loop over tick
        failures = 0
        while True:
            try:
                await self.tick()
                failures = 0
            except Exception:
                failures += 1
                log.exception("scheduler tick failed failures=%d", failures)
                await asyncio.sleep(min(60.0, 2.0**failures))
                continue
            await asyncio.sleep(interval)
