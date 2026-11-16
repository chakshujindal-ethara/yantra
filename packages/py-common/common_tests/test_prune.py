"""Pruning keeps unpublished rows, deletes only past the cutoff, and honours the chunk size."""

import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import MetaData, create_engine, func, insert, select, text
from sqlalchemy.orm import sessionmaker

from yantra_common.consumer import consumed_table
from yantra_common.outbox import outbox_table
from yantra_common.prune import prune_consumed, prune_published
from yantra_common.testing import ADMIN_URL

NOW = datetime(2026, 11, 6, tzinfo=UTC)


def test_prune_published_and_consumed():
    engine = create_engine(ADMIN_URL, future=True)
    md = MetaData(schema="prune_test")
    outbox, consumed = outbox_table(md, "prune_test"), consumed_table(md, "prune_test")
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA IF EXISTS prune_test CASCADE"))
        c.execute(text("CREATE SCHEMA prune_test"))
    md.create_all(engine)
    try:
        old, recent = NOW - timedelta(days=8), NOW - timedelta(days=1)
        with engine.begin() as c:
            for published in (old, old, old, recent, None):
                c.execute(
                    insert(outbox).values(
                        id=uuid.uuid4(), type="t", subject="s", payload={}, occurred_at=old, published_at=published
                    )
                )
            for at in (NOW - timedelta(days=31), recent):
                c.execute(insert(consumed).values(id=uuid.uuid4(), type="t", consumed_at=at))
        with sessionmaker(bind=engine)() as s:
            assert prune_published(s, outbox, timedelta(days=7), NOW, limit=2) == 2
            assert prune_published(s, outbox, timedelta(days=7), NOW) == 1
            assert prune_published(s, outbox, timedelta(days=7), NOW) == 0
            assert prune_consumed(s, consumed, timedelta(days=30), NOW) == 1
            s.commit()
            assert s.scalar(select(func.count()).select_from(outbox)) == 2  # the recent and the unpublished
            assert s.scalar(select(func.count()).select_from(consumed)) == 1
    finally:
        with engine.begin() as c:
            c.execute(text("DROP SCHEMA prune_test CASCADE"))
        engine.dispose()


def test_the_prune_job_runs_daily_at_three_ist_over_both_tables():
    from yantra_common.scheduler import At, job_lease_table

    engine = create_engine(ADMIN_URL, future=True)
    md = MetaData(schema="prune_job_test")
    outbox, consumed = outbox_table(md, "prune_job_test"), consumed_table(md, "prune_job_test")
    lease = job_lease_table(md, "prune_job_test")
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA IF EXISTS prune_job_test CASCADE"))
        c.execute(text("CREATE SCHEMA prune_job_test"))
    md.create_all(engine)
    try:
        from yantra_common.prune import prune_job

        long_ago = datetime.now(UTC) - timedelta(days=60)
        with engine.begin() as c:
            c.execute(
                insert(outbox).values(
                    id=uuid.uuid4(), type="t", subject="s", payload={}, occurred_at=long_ago, published_at=long_ago
                )
            )
            c.execute(insert(consumed).values(id=uuid.uuid4(), type="t", consumed_at=long_ago))
        factory = sessionmaker(bind=engine)
        job = prune_job(factory, "p", lease, outbox, consumed)
        assert job.at == At(3, 0) and job.run() == 2
        assert prune_job(factory, "q", lease, None, consumed).run() == 0
    finally:
        with engine.begin() as c:
            c.execute(text("DROP SCHEMA prune_job_test CASCADE"))
        engine.dispose()


def test_the_prune_job_drains_a_backlog_in_committed_chunks_within_its_time_budget():
    from yantra_common.prune import prune_job
    from yantra_common.scheduler import job_lease_table

    engine = create_engine(ADMIN_URL, future=True)
    md = MetaData(schema="prune_loop_test")
    outbox, consumed = outbox_table(md, "prune_loop_test"), consumed_table(md, "prune_loop_test")
    lease = job_lease_table(md, "prune_loop_test")
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA IF EXISTS prune_loop_test CASCADE"))
        c.execute(text("CREATE SCHEMA prune_loop_test"))
    md.create_all(engine)
    try:
        long_ago = datetime.now(UTC) - timedelta(days=60)

        def backlog(n: int) -> None:
            with engine.begin() as c:
                for _ in range(n):
                    c.execute(
                        insert(outbox).values(
                            id=uuid.uuid4(),
                            type="t",
                            subject="s",
                            payload={},
                            occurred_at=long_ago,
                            published_at=long_ago,
                        )
                    )
                    c.execute(insert(consumed).values(id=uuid.uuid4(), type="t", consumed_at=long_ago))

        def count(table) -> int:
            with engine.connect() as c:
                return int(c.scalar(select(func.count()).select_from(table)))

        factory = sessionmaker(bind=engine)
        backlog(5)
        # chunks of two: 2 + 2 + 1 per table, more than one chunk's worth, all gone in one pass
        assert prune_job(factory, "p", lease, outbox, consumed, limit=2).run() == 10
        assert count(outbox) == count(consumed) == 0
        backlog(5)
        ticks = iter([0.0, 0.0, 61.0, 61.0, 61.0])  # the budget runs out after the first chunk
        job = prune_job(factory, "p", lease, outbox, consumed, budget_seconds=60, clock=lambda: next(ticks), limit=2)
        assert job.run() == 2
        assert count(consumed) == 3 and count(outbox) == 5  # the first chunk stayed committed; the rest waits
    finally:
        with engine.begin() as c:
            c.execute(text("DROP SCHEMA prune_loop_test CASCADE"))
        engine.dispose()
