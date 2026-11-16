"""Metrics: bounded route labels, the request histogram and /metrics, the probe's throttle and its isolation from
a failing observer, the outbox, dead-letter and job observers on a real schema, the consumer lag."""

import asyncio
import uuid
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from prometheus_client import REGISTRY
from sqlalchemy import MetaData, create_engine, insert, text
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session, sessionmaker

from yantra_common.consumer import dead_table, oldest_age, probe
from yantra_common.http import install_boundary
from yantra_common.metrics import Probe, install_metrics, normalize_path, route_label
from yantra_common.outbox import outbox_table
from yantra_common.scheduler import At, Job, job_lease_table, register
from yantra_common.testing import ADMIN_URL

NOW = datetime(2026, 11, 4, 12, 0, tzinfo=UTC)


def sample(name: str, **labels: str) -> float:
    return REGISTRY.get_sample_value(name, labels) or 0.0


def test_a_path_becomes_a_bounded_label():
    assert normalize_path("/v1/projects/7d0b8f8e-3c1a-4c2e-9b1a-2f6d5e4c3b2a/batches") == "/v1/projects/{id}/batches"
    assert normalize_path("/v1/claims/123/release") == "/v1/claims/{id}/release"
    assert normalize_path("/a/b/c/d/e/f/g/h") == "/a/b/c/d/e/f"
    assert normalize_path("/") == "/"


def test_the_gateway_labels_unrouted_answers_as_other():
    def request(answered: bool, route: object = None) -> SimpleNamespace:
        state = SimpleNamespace(upstream_answered=True) if answered else SimpleNamespace()
        return SimpleNamespace(url=SimpleNamespace(path="/v1/anything/xyz"), scope={"route": route}, state=state)

    assert route_label(request(True), 404, normalize=True) == "other"
    assert route_label(request(True), 401, normalize=True) == "other"
    assert route_label(request(True), 200, normalize=True) == "/v1/anything/xyz"
    assert route_label(request(True), 200, normalize=False) == "other"
    # the gateway's own answers (a 429, a 400, a 413) never label by the path a caller chose
    catch_all = SimpleNamespace(path="/v1/{path:path}")
    for status in (400, 413, 422, 429, 503):
        assert route_label(request(False, catch_all), status, normalize=True) == "other"
    assert route_label(request(False, SimpleNamespace(path="/ready")), 503, normalize=True) == "/ready"


def test_every_request_is_timed_by_its_route_template_and_metrics_is_served() -> None:
    app = FastAPI()
    install_boundary(app, 1000)
    install_metrics(app, "metricstest")

    @app.get("/v1/things/{thing_id}")
    def thing(thing_id: str) -> dict[str, str]:
        return {"id": thing_id}

    @app.get("/v1/boom")
    def boom() -> None:
        raise RuntimeError("boom")

    client = TestClient(app, raise_server_exceptions=False)
    before = sample(
        "yantra_http_request_duration_seconds_count",
        process="metricstest",
        method="GET",
        route="/v1/things/{thing_id}",
        status="200",
    )
    assert client.get(f"/v1/things/{uuid.uuid4()}").status_code == 200
    assert client.get("/v1/boom").status_code == 500
    body = client.get("/metrics").text
    assert 'route="/v1/things/{thing_id}"' in body and 'route="/v1/boom",status="500"' in body
    after = sample(
        "yantra_http_request_duration_seconds_count",
        process="metricstest",
        method="GET",
        route="/v1/things/{thing_id}",
        status="200",
    )
    assert after == before + 1
    assert 'route="/metrics"' not in body


def test_the_consumer_lag_is_the_oldest_fetched_message():
    old = SimpleNamespace(metadata=SimpleNamespace(timestamp=NOW - timedelta(seconds=90)))
    new = SimpleNamespace(metadata=SimpleNamespace(timestamp=NOW - timedelta(seconds=5)))
    assert oldest_age([new, old], NOW) == 90.0
    naive = SimpleNamespace(metadata=SimpleNamespace(timestamp=(NOW - timedelta(seconds=30)).replace(tzinfo=None)))
    assert oldest_age([naive], NOW) == 30.0  # what nats-py hands over: stream time in UTC, no zone
    assert oldest_age([SimpleNamespace(metadata=SimpleNamespace(num_delivered=1))], NOW) == 0.0
    assert oldest_age([], NOW) == 0.0


def test_the_probe_runs_at_most_once_per_interval_and_survives_a_failing_observer(caplog):
    ticks = iter([0.0, 5.0, 16.0])
    calls: list[str] = []

    def broken(session: Session, now: datetime) -> None:
        calls.append("broken")
        raise OperationalError("select", {}, Exception("down"))

    def fine(session: Session, now: datetime) -> None:
        calls.append("fine")

    class FakeSession:
        def __enter__(self) -> "FakeSession":
            return self

        def __exit__(self, *a: object) -> None:
            return None

        def rollback(self) -> None:
            calls.append("rollback")

    p = Probe(lambda: FakeSession(), [broken, fine], every=15.0, clock=lambda: next(ticks), now=lambda: NOW)
    assert asyncio.run(p()) == 0
    assert asyncio.run(p()) == 0  # 5 s later: throttled
    assert asyncio.run(p()) == 0
    assert calls == ["broken", "rollback", "fine"] * 2
    assert "metrics observer failed" in caplog.text


@pytest.fixture
def schema():
    engine = create_engine(ADMIN_URL, future=True)
    md = MetaData(schema="metrics_test")
    tables = SimpleNamespace(
        outbox=outbox_table(md, "metrics_test"),
        dead=dead_table(md, "metrics_test"),
        lease=job_lease_table(md, "metrics_test"),
    )
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA IF EXISTS metrics_test CASCADE"))
        c.execute(text("CREATE SCHEMA metrics_test"))
    md.create_all(engine)
    yield engine, tables
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA metrics_test CASCADE"))
    engine.dispose()


def test_the_standard_probe_reads_outboxes_dead_letters_and_job_leases(schema):
    engine, t = schema
    factory = sessionmaker(bind=engine)
    with engine.begin() as c:
        c.execute(
            insert(t.outbox).values(
                id=uuid.uuid4(), type="t", subject="s", payload={}, occurred_at=NOW - timedelta(seconds=40)
            )
        )
        c.execute(
            insert(t.dead).values(id=uuid.uuid4(), consumer="c", deliveries=20, reason="r", raw=b"x", dead_at=NOW)
        )
    late = Job("metrics_late", lambda: None, t.lease, every=timedelta(seconds=30))
    daily = Job("metrics_daily", lambda: None, t.lease, at=At(3, 0))
    register(factory, [late, daily], now=NOW - timedelta(hours=1))
    p = probe(factory, [t.outbox], [t.dead], [late, daily])
    p.now = lambda: NOW
    p.observe()
    assert sample("yantra_outbox_unpublished", schema="metrics_test") == 1
    assert sample("yantra_outbox_oldest_age_seconds", schema="metrics_test") == 40
    assert sample("yantra_dead_events", schema="metrics_test") == 1
    assert sample("yantra_job_overdue", job="metrics_late") == 1
    assert sample("yantra_job_overdue", job="metrics_daily") == 0
    with engine.begin() as c:
        c.execute(text("DELETE FROM metrics_test.outbox"))
    p.observe()
    assert sample("yantra_outbox_unpublished", schema="metrics_test") == 0
    assert sample("yantra_outbox_oldest_age_seconds", schema="metrics_test") == 0
