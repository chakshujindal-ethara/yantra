"""The shared app base: readiness is the database alone; a stale outbox is reported, never fails it (a NATS outage
must not take every API pod out of its Service: the OutboxStale alert covers the relay)."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import MetaData, create_engine, insert, text
from sqlalchemy.orm import sessionmaker

from yantra_common.app import base_app
from yantra_common.outbox import outbox_table
from yantra_common.testing import ADMIN_URL


def test_ready_reports_backlog_and_a_stale_outbox_without_failing():
    engine = create_engine(ADMIN_URL, future=True)
    md = MetaData(schema="app_test")
    outbox = outbox_table(md, "app_test")
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA IF EXISTS app_test CASCADE"))
        c.execute(text("CREATE SCHEMA app_test"))
    md.create_all(engine)
    try:
        app = base_app("t", sessionmaker(bind=engine), [], [outbox], 100, 1000, stale_after_seconds=60)
        with TestClient(app) as client:
            assert client.get("/ready").json() == {
                "status": "ok",
                "outbox_unpublished": {"app_test": 0},
                "outbox_stale": False,
            }
            with engine.begin() as c:
                c.execute(
                    insert(outbox).values(
                        id=uuid.uuid4(), type="t", subject="s", payload={}, occurred_at=datetime.now(UTC)
                    )
                )
            assert client.get("/ready").status_code == 200
            with engine.begin() as c:
                c.execute(
                    insert(outbox).values(
                        id=uuid.uuid4(),
                        type="t",
                        subject="s",
                        payload={},
                        occurred_at=datetime.now(UTC) - timedelta(minutes=5),
                    )
                )
            r = client.get("/ready")
            assert r.status_code == 200 and r.json() == {
                "status": "ok",
                "outbox_unpublished": {"app_test": 2},
                "outbox_stale": True,
            }
            assert client.get("/health").json() == {"status": "ok"}
    finally:
        with engine.begin() as c:
            c.execute(text("DROP SCHEMA app_test CASCADE"))
        engine.dispose()


def test_ready_is_503_when_the_database_is_away_and_routes_answer_through_the_boundary(
    caplog: pytest.LogCaptureFixture,
) -> None:
    from fastapi import APIRouter

    router = APIRouter()

    @router.get("/echo")
    def echo(n: int) -> dict[str, int]:
        return {"n": n}

    engine = create_engine("postgresql+psycopg://nobody:nothing@127.0.0.1:1/none", future=True)
    md = MetaData(schema="away")
    app = base_app("t", sessionmaker(bind=engine), [router], [outbox_table(md, "away")], 100, 1000)
    with TestClient(app) as client:
        assert client.get("/echo", params={"n": 2}).json() == {"n": 2}
        r = client.get("/echo", params={"n": "two"})
        assert (r.status_code, r.json()["code"], r.json()["fields"]) == (422, "validation_error", ["query.n"])
        r = client.get("/ready")
        assert (r.status_code, r.json()) == (503, {"status": "database_unavailable"})
        assert client.get("/health").status_code == 200
    assert "ready: database unavailable" in caplog.text and "nothing" not in caplog.text
    engine.dispose()


def test_the_events_process_reports_its_loop_nats_jobs_and_dead_letters():
    from yantra_common.consumer import LoopState, dead_table
    from yantra_common.scheduler import Job, job_lease_table, register

    engine = create_engine(ADMIN_URL, future=True)
    md = MetaData(schema="events_app_test")
    outbox, dead = outbox_table(md, "events_app_test"), dead_table(md, "events_app_test")
    lease = job_lease_table(md, "events_app_test")
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA IF EXISTS events_app_test CASCADE"))
        c.execute(text("CREATE SCHEMA events_app_test"))
    md.create_all(engine)
    try:
        from yantra_common.app import events_app

        t0 = datetime(2026, 11, 6, tzinfo=UTC)
        now = [t0]
        factory = sessionmaker(bind=engine)
        job = Job("sweep", lambda: 0, lease, every=timedelta(seconds=30))
        unregistered = Job("later", lambda: 0, lease, every=timedelta(seconds=30))
        register(factory, [job], now=t0)
        state, nats = LoopState(), [True]
        app = events_app(factory, [outbox], [dead], [job, unregistered], state, lambda: nats[0], clock=lambda: now[0])
        client = TestClient(app)
        assert client.get("/health").json() == {"status": "ok"}
        r = client.get("/ready")
        assert (r.status_code, r.json()["status"], r.json()["last_round_at"]) == (503, "loop_stale", None)
        state.ok(t0)
        body = client.get("/ready").json()
        assert body == {
            "status": "ok",
            "last_round_at": t0.isoformat(),
            "nats_connected": True,
            "outbox_unpublished": {"events_app_test": 0},
            "outbox_stuck": [],
            "dead_letters": {"events_app_test": 0},
            "jobs": {
                "sweep": {"next_run_at": t0.isoformat(), "last_run_at": None, "last_error": None, "overdue": False}
            },
        }
        nats[0] = False
        assert client.get("/ready").json()["status"] == "nats_disconnected"
        nats[0] = True
        now[0] = t0 + timedelta(minutes=6)
        state.ok(now[0])
        r = client.get("/ready")
        assert (r.status_code, r.json()["status"]) == (503, "job_overdue")
        now[0] = t0 + timedelta(minutes=8)
        assert client.get("/ready").json()["status"] == "loop_stale"
        assert state.failed() == 1 and state.failed() == 2
        state.ok(now[0])
        assert state.failures == 0
    finally:
        with engine.begin() as c:
            c.execute(text("DROP SCHEMA events_app_test CASCADE"))
        engine.dispose()


def test_the_events_process_is_unready_when_its_outbox_is_old_and_not_draining():
    """A relay that stopped publishing: the oldest row is past the threshold AND the backlog did not shrink since the
    previous check. A big backlog that drains after a burst stays ready; so does an old row on the first check."""
    from yantra_common.app import events_app
    from yantra_common.consumer import LoopState

    engine = create_engine(ADMIN_URL, future=True)
    md = MetaData(schema="events_stuck_test")
    outbox = outbox_table(md, "events_stuck_test")
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA IF EXISTS events_stuck_test CASCADE"))
        c.execute(text("CREATE SCHEMA events_stuck_test"))
    md.create_all(engine)

    def add(n: int, age: timedelta) -> list[uuid.UUID]:
        ids = [uuid.uuid4() for _ in range(n)]
        with engine.begin() as c:
            for i in ids:
                c.execute(
                    insert(outbox).values(id=i, type="t", subject="s", payload={}, occurred_at=datetime.now(UTC) - age)
                )
        return ids

    def publish(ids: list[uuid.UUID]) -> None:
        with engine.begin() as c:
            c.execute(outbox.update().where(outbox.c.id.in_(ids)).values(published_at=datetime.now(UTC)))

    try:
        state = LoopState()
        state.ok(datetime.now(UTC))

        def client() -> TestClient:
            factory = sessionmaker(bind=engine)
            return TestClient(
                events_app(factory, [outbox], [], [], state, lambda: True, outbox_stuck_after_seconds=300)
            )

        young = client()
        fresh = add(3, timedelta(seconds=10))
        assert young.get("/ready").status_code == 200
        assert young.get("/ready").status_code == 200  # young rows, however long they sit, are not a wedge
        publish(fresh)
        watch = client()
        old = add(5, timedelta(minutes=10))
        r = watch.get("/ready")
        assert (r.status_code, r.json()["outbox_stuck"]) == (200, [])  # old, but nothing to compare with yet
        r = watch.get("/ready")
        assert (r.status_code, r.json()["status"], r.json()["outbox_stuck"]) == (
            503,
            "outbox_stuck",
            ["events_stuck_test"],
        )
        publish(old[:2])  # draining: ready again although the oldest row is still past the threshold
        r = watch.get("/ready")
        assert (r.status_code, r.json()["status"], r.json()["outbox_unpublished"]) == (
            200,
            "ok",
            {"events_stuck_test": 3},
        )
        assert watch.get("/ready").status_code == 503  # and stuck again once it stops
    finally:
        with engine.begin() as c:
            c.execute(text("DROP SCHEMA events_stuck_test CASCADE"))
        engine.dispose()
