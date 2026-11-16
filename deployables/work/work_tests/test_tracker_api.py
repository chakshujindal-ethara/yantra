"""The tracker routes through the work deployable: the worker's sessions and samples, screenshots, the operator's
anomalies and caps, the policy."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from yantra_tracker.models import AnomalyFlag
from yantra_tracker.testing import FakePresigner, device
from yantra_work.app import create_app

OPS = {"X-Role": "ops", "X-Worker-Id": str(uuid.uuid4())}


@pytest.fixture
def client(factory):
    return TestClient(create_app(factory, rate_limit_per_minute=1000), raise_server_exceptions=False)


@pytest.fixture
def stored(factory):
    fake = FakePresigner()
    return TestClient(
        create_app(factory, rate_limit_per_minute=1000, storage=fake), raise_server_exceptions=False
    ), fake


def worker() -> dict[str, str]:
    return {"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4())}


def start(client: TestClient, headers: dict[str, str], **body) -> dict:
    r = client.post("/v1/tracker/sessions", json={"device_hash": device(), **body}, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


def test_a_worker_runs_a_session_from_start_to_end(client):
    w = worker()
    s = start(client, w)
    again = client.post("/v1/tracker/sessions", json={"device_hash": device()}, headers=w)
    assert again.status_code == 409 and again.json()["code"] == "session_open"
    now = datetime.now(UTC)
    batch = {"samples": [{"at": (now - timedelta(seconds=30 * i)).isoformat(), "kind": "active"} for i in range(3)]}
    r = client.post(f"/v1/tracker/sessions/{s['id']}/samples", json=batch, headers=w)
    assert r.status_code == 200 and r.json()["accepted"] >= 2 and r.json()["week"]["cap_source"] == "default"
    dup = client.post(f"/v1/tracker/sessions/{s['id']}/samples", json=batch, headers=w).json()
    assert dup["accepted"] == 0 and dup["duplicates"] == 3
    future = {"samples": [{"at": (now + timedelta(hours=1)).isoformat(), "kind": "idle"}]}
    bad = client.post(f"/v1/tracker/sessions/{s['id']}/samples", json=future, headers=w)
    assert bad.status_code == 422 and bad.json()["code"] == "sample_out_of_range"
    assert client.post(f"/v1/tracker/sessions/{s['id']}/samples", json={"samples": []}, headers=w).status_code == 422
    stranger = client.post(f"/v1/tracker/sessions/{s['id']}/samples", json=batch, headers=worker())
    assert stranger.status_code == 404
    ended = client.post(f"/v1/tracker/sessions/{s['id']}/end", headers=w)
    assert ended.status_code == 200 and ended.json()["end_reason"] == "client"
    late = client.post(f"/v1/tracker/sessions/{s['id']}/samples", json=batch, headers=w)
    assert late.status_code == 409 and late.json()["code"] == "session_ended"
    mine = client.get("/v1/tracker/sessions/me", headers=w).json()
    assert mine["open_session_id"] is None and [x["id"] for x in mine["sessions"]] == [s["id"]]
    ranged = client.get(
        "/v1/tracker/sessions/me",
        params={"from": (now - timedelta(days=30)).isoformat(), "to": (now + timedelta(days=1)).isoformat()},
        headers=w,
    )
    assert ranged.status_code == 200 and len(ranged.json()["sessions"]) == 1


def test_worker_routes_refuse_a_client_and_ops_routes_refuse_a_worker(client):
    client_only = {"X-Role": "client", "X-Worker-Id": str(uuid.uuid4())}
    assert client.post("/v1/tracker/sessions", json={"device_hash": device()}, headers=client_only).status_code == 403
    assert client.get("/v1/tracker/sessions/me", headers=client_only).status_code == 403
    w = worker()
    for path in ("/v1/tracker/sessions", "/v1/tracker/anomalies", "/v1/tracker/caps"):
        assert client.get(path, headers=w).status_code == 403
    assert client.get("/v1/tracker/policy", headers=client_only).json()["slug"] == "tracking"
    bad = client.post("/v1/tracker/sessions", json={"device_hash": "short"}, headers=w)
    assert bad.status_code == 422


def test_screenshots_need_storage_and_register_under_the_session_at_their_size(client, stored):
    w = worker()
    s = start(client, w)
    presign = {"session_id": s["id"], "content_type": "image/png", "size_bytes": 2048}
    none = client.post("/v1/tracker/screenshots/presign", json=presign, headers=w)
    assert none.status_code == 503 and none.json()["code"] == "storage_unconfigured"
    with_storage, fake = stored
    huge = with_storage.post(
        "/v1/tracker/screenshots/presign", json={**presign, "size_bytes": 5 * 2**20 + 1}, headers=w
    )
    assert huge.status_code == 422
    signed = with_storage.post(
        "/v1/tracker/screenshots/presign", json={**presign, "content_type": "image/jpeg"}, headers=w
    )
    assert signed.status_code == 200, signed.text
    body = signed.json()
    assert body["object_key"].endswith(".jpg") and body["put_url"].startswith("fake://")
    assert fake.puts == [(body["object_key"], "image/jpeg", 2048, 2048)]
    taken = datetime.now(UTC).isoformat()
    reg = {"object_key": body["object_key"], "size_bytes": 2048, "taken_at": taken}
    path = f"/v1/tracker/sessions/{s['id']}/screenshots"
    assert client.post(path, json=reg, headers=w).json()["code"] == "storage_unconfigured"
    missing = with_storage.post(path, json=reg, headers=w)
    assert missing.status_code == 422 and missing.json()["code"] == "object_missing"
    fake.objects[body["object_key"]] = 4096  # a bigger body than declared
    wrong = with_storage.post(path, json=reg, headers=w)
    assert wrong.status_code == 422 and wrong.json()["code"] == "size_mismatch" and fake.deleted == [body["object_key"]]
    fake.objects[body["object_key"]] = 2048
    ok = with_storage.post(path, json=reg, headers=w)
    assert ok.status_code == 201 and ok.json()["content_type"] == "image/jpeg"


def test_a_worker_who_withdrew_consent_is_refused_and_ops_never_decide_their_own_flags(client, factory):
    from yantra_tracker.service import consent_withdrawn

    w = worker()
    s = start(client, w)
    wid = uuid.UUID(w["X-Worker-Id"])
    with factory() as session:
        consent_withdrawn(session, wid, datetime.now(UTC))
        flag = AnomalyFlag(worker_id=wid, kind="pattern", detail={}, status="open", created_at=datetime.now(UTC))
        session.add(flag)
        session.commit()
        flag_id = flag.id
    for path, body in (
        ("/v1/tracker/sessions", {"device_hash": device()}),
        (
            f"/v1/tracker/sessions/{s['id']}/samples",
            {"samples": [{"at": datetime.now(UTC).isoformat(), "kind": "active"}]},
        ),
    ):
        r = client.post(path, json=body, headers=w)
        assert r.status_code == 403 and r.json()["code"] == "consent_withdrawn"
    as_ops = {"X-Role": "ops", "X-Worker-Id": str(wid)}
    for action in ("dismiss", "uphold"):
        r = client.post(f"/v1/tracker/anomalies/{flag_id}/{action}", json={}, headers=as_ops)
        assert r.status_code == 403 and r.json()["code"] == "self_action"


def test_operators_list_decide_and_cap(client, factory):
    w = worker()
    s = start(client, w)
    wid = uuid.UUID(w["X-Worker-Id"])
    with factory() as session:
        session.add(
            AnomalyFlag(
                worker_id=wid,
                kind="duplicate_device",
                detail={"device_hash": "d"},
                status="open",
                created_at=datetime.now(UTC),
            )
        )
        session.add(
            AnomalyFlag(worker_id=wid, kind="no_live_claim", detail={}, status="open", created_at=datetime.now(UTC))
        )
        session.commit()
    sessions = client.get("/v1/tracker/sessions", params={"worker_id": str(wid)}, headers=OPS).json()
    assert [x["id"] for x in sessions] == [s["id"]]
    flags = client.get("/v1/tracker/anomalies", headers=OPS).json()
    assert len(flags) == 2
    upheld = client.post(f"/v1/tracker/anomalies/{flags[0]['id']}/uphold", json={"note": "confirmed"}, headers=OPS)
    assert upheld.status_code == 200 and upheld.json()["status"] == "upheld"
    dismissed = client.post(f"/v1/tracker/anomalies/{flags[1]['id']}/dismiss", json={}, headers=OPS)
    assert dismissed.json()["status"] == "dismissed"
    twice = client.post(f"/v1/tracker/anomalies/{flags[1]['id']}/uphold", json={}, headers=OPS)
    assert twice.status_code == 409 and twice.json()["code"] == "anomaly_decided"
    assert (
        client.get("/v1/tracker/anomalies", params={"status": "upheld"}, headers=OPS).json()[0]["note"] == "confirmed"
    )
    cap = client.put(f"/v1/tracker/caps/worker/{wid}", json={"weekly_cap_hours": "12.5"}, headers=OPS)
    assert cap.status_code == 200 and cap.json()["weekly_cap_hours"] == "12.50"
    assert client.put(f"/v1/tracker/caps/team/{wid}", json={"weekly_cap_hours": "1"}, headers=OPS).status_code == 422
    assert (
        client.put(f"/v1/tracker/caps/worker/{wid}", json={"weekly_cap_hours": "200"}, headers=OPS).status_code == 422
    )
    assert [c["scope"] for c in client.get("/v1/tracker/caps", headers=OPS).json()] == ["worker"]
    assert client.get("/v1/tracker/sessions/me", headers=w).json()["week"]["cap_hours"] == "12.50"
