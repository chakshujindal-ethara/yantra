"""The analytics routes through the work deployable: leadership, drill-downs, baselines, the rebuild request."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from yantra_analytics import marts
from yantra_analytics.testing import Warehouse
from yantra_work.app import create_app

OPS = {"X-Role": "ops", "X-Worker-Id": str(uuid.uuid4())}
FINANCE = {"X-Role": "finance", "X-Worker-Id": str(uuid.uuid4())}
ADMIN = {"X-Role": "admin", "X-Worker-Id": str(uuid.uuid4())}
WORKER = {"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4())}


@pytest.fixture
def client(factory):
    return TestClient(create_app(factory, rate_limit_per_minute=1000), raise_server_exceptions=False)


def test_leadership_is_for_operators_finance_and_admins(client):
    assert client.get("/v1/analytics/leadership", headers=WORKER).status_code == 403
    for who in (OPS, FINANCE, ADMIN):
        r = client.get("/v1/analytics/leadership", params={"days": 7}, headers=who)
        assert r.status_code == 200 and r.json()["window_days"] == 7
    body = client.get("/v1/analytics/leadership", headers=OPS).json()
    assert [t["key"] for t in body["numbers"]] == [
        "days_to_staff",
        "idle_cost",
        "first_pass_acceptance",
        "cost_per_accepted_unit",
    ]
    assert [t["key"] for t in body["watch"]] == ["on_time_payout", "fraud_per_1000", "incidents"]
    assert client.get("/v1/analytics/leadership", params={"days": 0}, headers=OPS).status_code == 422


def test_baselines_are_set_by_operators_and_keep_their_history(client):
    assert client.get("/v1/analytics/baselines", headers=OPS).status_code == 404
    assert client.put("/v1/analytics/baselines", json={}, headers=FINANCE).status_code == 403
    first = client.put("/v1/analytics/baselines", json={"days_to_staff": "4", "idle_hourly_cost": "120"}, headers=OPS)
    assert first.status_code == 200 and first.json()["days_to_staff"] == "4.00"
    second = client.put("/v1/analytics/baselines", json={"days_to_staff": "3"}, headers=OPS).json()
    assert client.get("/v1/analytics/baselines", headers=FINANCE).json()["id"] == second["id"]
    lead = client.get("/v1/analytics/leadership", headers=OPS).json()
    assert lead["numbers"][0]["baseline"] == "3.00" and lead["baseline_set_at"]
    assert client.put("/v1/analytics/baselines", json={"first_pass_acceptance": "2"}, headers=OPS).status_code == 422


def test_the_drill_downs(client, factory):
    project, batch, unit, w, r = (uuid.uuid4() for _ in range(5))
    now = datetime.now(UTC)
    with factory() as s:
        wh = Warehouse(s)
        wh.published(now, batch, project)
        wh.verdict(now, unit, batch, w, r)
        wh.put("tracking.session.ended.v1", now, {"session_id": uuid.uuid4(), "worker_id": w, "active_seconds": 3600})
        s.commit()
    marts.refresh_marts(factory)
    trend = client.get(f"/v1/analytics/projects/{project}/trend", params={"days": 2}, headers=OPS).json()
    assert trend["currency"] == "INR" and trend["days"][-1]["accepted"] == 1
    funnel = client.get("/v1/analytics/funnel", headers=OPS).json()
    assert funnel["stages_available"] == ["offered", "rejected", "accepted"]
    workforce = client.get("/v1/analytics/workforce", headers=FINANCE).json()
    assert workforce["workers"][0]["active_hours"] == "1.00"
    last_week = (now - timedelta(days=7)).date().isoformat()
    assert client.get("/v1/analytics/workforce", params={"week": last_week}, headers=OPS).json()["workers"] == []


def test_a_rebuild_is_an_admins_request(client):
    assert client.get("/v1/analytics/rebuild", headers=OPS).json()["status"] == "idle"
    assert client.post("/v1/analytics/rebuild", headers=OPS).status_code == 403
    r = client.post("/v1/analytics/rebuild", params={"mode": "purge"}, headers=ADMIN)
    assert r.status_code == 202 and r.json()["status"] == "requested" and r.json()["mode"] == "purge"
    again = client.post("/v1/analytics/rebuild", headers=ADMIN)
    assert again.status_code == 409 and again.json()["code"] == "rebuild_running"


def test_analytics_dead_letters_replay_whatever_generation_wrote_them(client, factory):
    from yantra_analytics.models import DEAD, Event
    from yantra_common.events import encode

    event_id = uuid.uuid4()
    raw = encode(event_id, "x.y.v1", "s", datetime.now(UTC), {"worker_id": str(uuid.uuid4())})
    with factory() as s:
        s.execute(
            DEAD.insert().values(
                id=event_id, consumer="analytics-all-g3", deliveries=20, reason="r", raw=raw, dead_at=datetime.now(UTC)
            )
        )
        s.commit()
    r = client.post(f"/v1/analytics/dead-letters/{event_id}/replay", headers=ADMIN)
    assert r.status_code == 200 and r.json()["fresh"] is True
    with factory() as s:
        assert s.get(Event, event_id) is not None
