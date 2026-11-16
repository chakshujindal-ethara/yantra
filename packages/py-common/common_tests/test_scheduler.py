"""The leased scheduler: slot arithmetic in IST, exclusive leases, outcomes recorded, slow jobs isolated."""

import asyncio
import threading
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import MetaData, create_engine, select, text
from sqlalchemy.orm import sessionmaker

from yantra_common.scheduler import (
    IST,
    At,
    Job,
    Scheduler,
    claim,
    finish,
    in_session,
    job_lease_table,
    next_run,
    next_slot,
    overdue,
    read_state,
    register,
    write_state,
)
from yantra_common.testing import ADMIN_URL

T0 = datetime(2026, 11, 6, 20, 0, tzinfo=UTC)  # Friday 01:30 IST on Saturday 7 Nov


@pytest.fixture
def lease():
    engine = create_engine(ADMIN_URL, future=True, pool_size=10)
    md = MetaData(schema="scheduler_test")
    table = job_lease_table(md, "scheduler_test")
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA IF EXISTS scheduler_test CASCADE"))
        c.execute(text("CREATE SCHEMA scheduler_test"))
    md.create_all(engine)
    yield sessionmaker(bind=engine), table
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA scheduler_test CASCADE"))
    engine.dispose()


def ist(y, mo, d, h, mi, s=0):
    return datetime(y, mo, d, h, mi, s, tzinfo=IST).astimezone(UTC)


def test_a_job_has_exactly_one_kind_of_schedule():
    with pytest.raises(ValueError, match="exactly one"):
        Job("x", lambda: 0, None)
    with pytest.raises(ValueError, match="exactly one"):
        Job("x", lambda: 0, None, every=timedelta(seconds=1), at=At(3, 0))


def test_daily_slots_in_ist():
    daily = At(2, 0)
    assert next_slot(ist(2026, 11, 5, 1, 59), daily, inclusive=False) == ist(2026, 11, 5, 2, 0)
    assert next_slot(ist(2026, 11, 5, 2, 0, 30), daily, inclusive=False) == ist(2026, 11, 6, 2, 0)
    assert next_slot(ist(2026, 11, 5, 2, 0), daily, inclusive=True) == ist(2026, 11, 5, 2, 0)
    assert next_slot(ist(2026, 11, 5, 2, 0), daily, inclusive=False) == ist(2026, 11, 6, 2, 0)
    assert next_slot(ist(2026, 11, 5, 2, 0), daily, inclusive=True).tzinfo == UTC


def test_weekly_slots_cross_weeks_and_months():
    saturday = At(0, 5, weekday=5)
    assert next_slot(ist(2026, 11, 6, 23, 59), saturday, inclusive=False) == ist(2026, 11, 7, 0, 5)  # a Friday
    assert next_slot(ist(2026, 11, 7, 0, 6), saturday, inclusive=False) == ist(2026, 11, 14, 0, 5)
    assert next_slot(ist(2026, 11, 29, 12, 0), saturday, inclusive=False) == ist(2026, 12, 5, 0, 5)  # a Sunday


def test_next_run_and_overdue():
    every = Job("e", lambda: 0, None, every=timedelta(seconds=30))
    daily = Job("d", lambda: 0, None, at=At(3, 0))
    assert next_run(T0, every) == T0 + timedelta(seconds=30) and next_run(T0, every, inclusive=True) == T0
    assert next_run(T0, daily) == ist(2026, 11, 7, 3, 0)
    assert not overdue(every, T0, T0 + timedelta(minutes=5)) and overdue(
        every, T0, T0 + timedelta(minutes=5, seconds=1)
    )
    hourly = Job("h", lambda: 0, None, every=timedelta(hours=1))
    assert not overdue(hourly, T0, T0 + timedelta(hours=3)) and overdue(hourly, T0, T0 + timedelta(hours=3, seconds=1))
    assert not overdue(daily, T0, T0 + timedelta(hours=1)) and overdue(daily, T0, T0 + timedelta(hours=1, seconds=1))


def test_register_is_idempotent_and_keeps_a_known_schedule(lease):
    factory, table = lease
    every = Job("every", lambda: 0, table, every=timedelta(seconds=30))
    daily = Job("daily", lambda: 0, table, at=At(3, 0))
    register(factory, [every, daily], now=T0)
    register(factory, [every, daily], now=T0 + timedelta(days=3))
    with factory() as s:
        rows = {r.name: r for r in s.execute(select(table))}
    assert rows["every"].next_run_at == T0 and rows["daily"].next_run_at == ist(2026, 11, 7, 3, 0)


def test_only_one_holder_wins_a_due_job_until_its_lease_lapses(lease):
    factory, table = lease
    job = Job("j", lambda: 0, table, every=timedelta(seconds=30), lease_seconds=60)
    register(factory, [job], now=T0)
    results: list[bool] = []
    barrier = threading.Barrier(2)

    def contend(holder: str) -> None:
        with factory() as s:
            barrier.wait()
            results.append(claim(s, job, T0, holder))
            s.commit()

    threads = [threading.Thread(target=contend, args=(h,)) for h in ("a", "b")]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(results) == [False, True]
    with factory() as s:
        assert not claim(s, job, T0 + timedelta(seconds=59), "c")
        assert claim(s, job, T0 + timedelta(seconds=61), "c")
        s.commit()


def test_a_job_that_is_not_due_is_not_claimed_and_finish_advances_it(lease):
    factory, table = lease
    job = Job("j", lambda: 0, table, every=timedelta(seconds=30))
    register(factory, [job], now=T0)
    with factory() as s:
        assert not claim(s, job, T0 - timedelta(seconds=1), "a")
        assert claim(s, job, T0, "a")
        assert finish(s, job, T0 + timedelta(seconds=2), "a", result=7)
        s.commit()
        row = s.execute(select(table)).one()
    assert (row.last_result, row.last_error, row.locked_by) == (7, None, None)
    assert row.next_run_at == T0 + timedelta(seconds=32) and row.last_run_at == T0


def test_state_is_a_jobs_own_cursor(lease):
    factory, table = lease
    job = Job("j", lambda: 0, table, every=timedelta(seconds=30))
    register(factory, [job], now=T0)
    with factory() as s:
        assert read_state(s, job) == {}
        write_state(s, job, {"mark": "x"})
        s.commit()
        assert read_state(s, job) == {"mark": "x"}


def test_the_scheduler_runs_due_jobs_once_records_errors_and_isolates_a_slow_job(lease):
    factory, table = lease
    now = [T0]
    calls: list[str] = []
    release = threading.Event()

    def slow() -> int:
        calls.append("slow")
        release.wait(5)
        return 1

    def boom() -> int:
        calls.append("boom")
        raise RuntimeError("nope")

    seen: list[int] = []
    jobs = [
        Job("slow", slow, table, every=timedelta(seconds=30)),
        Job("boom", boom, table, every=timedelta(seconds=30)),
        Job("quick", in_session(factory, lambda s: seen.append(1) or 3), table, every=timedelta(seconds=30)),
    ]
    register(factory, jobs, now=T0)
    scheduler = Scheduler(factory, jobs, concurrency=2, holder="me", clock=lambda: now[0])

    async def scenario() -> None:
        assert await scheduler.tick() == 2  # slow and boom; quick waits for a free slot
        await asyncio.sleep(0.05)
        assert await scheduler.tick() == 1  # boom finished: quick starts while slow still runs
        assert await scheduler.tick() == 0  # slow is running, the rest are not due
        release.set()
        await scheduler.drain()
        assert await scheduler.tick() == 0  # nothing due until the clock moves
        now[0] = T0 + timedelta(seconds=31)
        assert await scheduler.tick() == 2
        await scheduler.drain()

    asyncio.run(scenario())
    with factory() as s:
        rows = {r.name: r for r in s.execute(select(table))}
    assert rows["boom"].last_error == "RuntimeError: nope" and rows["boom"].next_run_at > T0
    assert rows["slow"].last_result == 1 and rows["quick"].last_result == 3 and seen
    assert calls.count("slow") >= 1 and calls.count("boom") >= 1


def test_an_outcome_that_cannot_be_recorded_still_frees_the_job(lease, monkeypatch):
    factory, table = lease
    job = Job("j", lambda: 1, table, every=timedelta(seconds=30))
    register(factory, [job], now=T0)
    scheduler = Scheduler(factory, [job], clock=lambda: T0)
    import yantra_common.scheduler as mod

    def broken(*_a, **_k):
        raise RuntimeError("db away")

    monkeypatch.setattr(mod, "finish", broken)

    async def scenario() -> None:
        assert await scheduler.tick() == 1
        await scheduler.drain()

    asyncio.run(scenario())
    assert scheduler._running == {}
    assert Scheduler(factory, []).holder


def test_a_late_finisher_never_clears_the_lock_of_the_holder_that_took_over(lease):
    factory, table = lease
    job = Job("j", lambda: 0, table, every=timedelta(seconds=30), lease_seconds=60)
    register(factory, [job], now=T0)
    with factory() as s:
        assert claim(s, job, T0, "a")
        assert claim(s, job, T0 + timedelta(seconds=61), "b")  # a's lease lapsed: b runs the job now
        assert not finish(s, job, T0 + timedelta(seconds=62), "a", result=1)  # a's pass ends late
        s.commit()
        row = s.execute(select(table)).one()
    assert row.locked_by == "b" and row.locked_until is not None and row.last_result is None
    with factory() as s:
        assert finish(s, job, T0 + timedelta(seconds=63), "b", result=2)
        s.commit()
        row = s.execute(select(table)).one()
    assert (row.locked_by, row.last_result) == (None, 2)


def test_a_cancelled_pass_is_a_failure_and_keeps_its_weekly_slot(lease):
    factory, table = lease
    started, release = threading.Event(), threading.Event()

    def close_window() -> int:
        started.set()
        release.wait(5)
        return 1

    weekly = Job("weekly", close_window, table, at=At(0, 5, weekday=5))
    saturday = ist(2026, 11, 7, 0, 5)
    register(factory, [weekly], now=saturday)
    scheduler = Scheduler(factory, [weekly], holder="me", clock=lambda: saturday)

    async def scenario() -> None:
        assert await scheduler.tick() == 1
        await asyncio.to_thread(started.wait, 5)
        task = scheduler._running["weekly"]
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        release.set()

    asyncio.run(scenario())
    with factory() as s:
        row = s.execute(select(table)).one()
    assert row.last_error == "cancelled" and row.locked_by is None
    assert row.next_run_at == saturday  # not moved to next Saturday: the close runs again
    assert scheduler._running == {}
