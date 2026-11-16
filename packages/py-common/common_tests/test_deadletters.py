"""Dead letters: listed without payload, replayed through the same handler, refused when they cannot be; the
module's jobs readable; one ERROR line per new dead letter."""

import logging
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import MetaData, create_engine, func, insert, select, text
from sqlalchemy.orm import sessionmaker

from yantra_common.consumer import consumed_table, dead_table
from yantra_common.deadletters import alert_new_dead_letters, dead_letter_router, jobs_router
from yantra_common.events import encode
from yantra_common.http import install_boundary
from yantra_common.scheduler import Job, job_lease_table, register
from yantra_common.testing import ADMIN_URL

OPS = {"X-Role": "ops"}
T0 = datetime(2026, 11, 6, tzinfo=UTC)


@pytest.fixture
def rig():
    engine = create_engine(ADMIN_URL, future=True)
    md = MetaData(schema="dead_test")
    consumed, dead, lease = (
        consumed_table(md, "dead_test"),
        dead_table(md, "dead_test"),
        job_lease_table(md, "dead_test"),
    )
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA IF EXISTS dead_test CASCADE"))
        c.execute(text("CREATE SCHEMA dead_test"))
    md.create_all(engine)
    factory = sessionmaker(bind=engine)
    seen: list[str] = []

    def handler(session, env):
        if env.data.get("fail"):
            raise RuntimeError("still broken")
        seen.append(env.type)

    app = FastAPI()
    app.state.factory = factory
    install_boundary(app, 1 << 20)
    app.include_router(dead_letter_router("/v1/demo/dead-letters", dead, consumed, {"demo-t-v1": handler}))
    app.include_router(jobs_router("/v1/demo/jobs", lease))
    yield TestClient(app), factory, consumed, dead, lease, seen
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA dead_test CASCADE"))
    engine.dispose()


def put_dead(factory, dead, raw: bytes, consumer: str = "demo-t-v1", at: datetime = T0) -> uuid.UUID:
    dead_id = uuid.uuid4()
    with factory() as s:
        s.execute(insert(dead).values(id=dead_id, consumer=consumer, deliveries=20, reason="boom", raw=raw, dead_at=at))
        s.commit()
    return dead_id


def test_list_hides_the_payload_and_replay_runs_the_handler_once(rig):
    client, factory, consumed, dead, _, seen = rig
    event_id = uuid.uuid4()
    good = put_dead(factory, dead, encode(event_id, "t.v1", "subj", T0, {"secret": "x"}))
    junk = put_dead(factory, dead, b"not json", at=T0 - timedelta(hours=1))
    listed = client.get("/v1/demo/dead-letters", headers=OPS).json()
    assert [d["id"] for d in listed] == [str(good), str(junk)]
    assert listed[0]["type"] == "t.v1" and listed[0]["subject"] == "subj" and "secret" not in str(listed)
    assert listed[1]["type"] is None
    r = client.post(f"/v1/demo/dead-letters/{good}/replay", headers=OPS)
    assert r.json() == {"replayed": True, "fresh": True} and seen == ["t.v1"]
    assert client.post(f"/v1/demo/dead-letters/{good}/replay", headers=OPS).status_code == 404
    r = client.post(f"/v1/demo/dead-letters/{junk}/replay", headers=OPS)
    assert (r.status_code, r.json()["code"]) == (409, "undecodable")


def test_replay_of_an_already_consumed_event_clears_the_row(rig):
    client, factory, consumed, dead, _, seen = rig
    event_id = uuid.uuid4()
    with factory() as s:
        s.execute(insert(consumed).values(id=event_id, type="t.v1", consumed_at=T0))
        s.commit()
    row = put_dead(factory, dead, encode(event_id, "t.v1", "s", T0, {}))
    assert client.post(f"/v1/demo/dead-letters/{row}/replay", headers=OPS).json() == {"replayed": True, "fresh": False}
    with factory() as s:
        assert s.scalar(select(func.count()).select_from(dead)) == 0
    assert seen == []


def test_replay_refuses_an_unknown_consumer_and_keeps_a_row_whose_handler_still_fails(rig):
    client, factory, _, dead, _, _ = rig
    stranger = put_dead(factory, dead, encode(uuid.uuid4(), "t.v1", "s", T0, {}), consumer="gone-t-v1")
    r = client.post(f"/v1/demo/dead-letters/{stranger}/replay", headers=OPS)
    assert (r.status_code, r.json()["code"]) == (409, "no_handler")
    failing = put_dead(factory, dead, encode(uuid.uuid4(), "t.v1", "s", T0, {"fail": True}))
    assert client.post(f"/v1/demo/dead-letters/{failing}/replay", headers=OPS).status_code == 500
    with factory() as s:
        assert s.scalar(select(func.count()).select_from(dead)) == 2


def test_roles_jobs_and_the_alert(rig, caplog):
    client, factory, _, dead, lease, _ = rig
    assert client.get("/v1/demo/dead-letters", headers={"X-Role": "worker"}).status_code == 403
    assert client.get("/v1/demo/jobs", headers={"X-Role": "admin"}).json() == []
    job = Job("alert", lambda: 0, lease, every=timedelta(minutes=5))
    register(factory, [job], now=T0)
    jobs = client.get("/v1/demo/jobs", headers={"X-Role": "admin"}).json()
    assert [j["name"] for j in jobs] == ["alert"] and jobs[0]["last_error"] is None

    put_dead(factory, dead, b"x", at=T0)
    with caplog.at_level(logging.ERROR, logger="yantra.deadletters"):
        with factory() as s:
            assert alert_new_dead_letters(s, job, [dead]) == 1
            assert alert_new_dead_letters(s, job, [dead]) == 0
            s.commit()
    assert caplog.text.count("dead letter waiting") == 1 and "schema=dead_test" in caplog.text
    put_dead(factory, dead, b"y", at=T0 + timedelta(minutes=1))
    with factory() as s:
        assert alert_new_dead_letters(s, job, [dead]) == 1
        assert alert_new_dead_letters(s, job, []) == 0


def test_handlers_of_and_the_alert_job(rig):
    from yantra_common.consumer import Consumer
    from yantra_common.deadletters import alert_job, handlers_of

    _, factory, consumed, dead, lease, _ = rig

    def h(session, env):
        return None

    cs = [Consumer("a", "x.v1", h, factory, consumed, dead), Consumer("b", "y.v1", h, factory, consumed, dead)]
    assert handlers_of(cs, "a") == {"a-x-v1": h}
    job = alert_job(factory, "alert", lease, [dead])
    register(factory, [job], now=T0)
    put_dead(factory, dead, b"x")
    assert job.every == timedelta(minutes=5) and job.run() == 1 and job.run() == 0
