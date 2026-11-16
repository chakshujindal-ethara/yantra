"""Over HTTP: nobody changes their own record or clearance, ops unassign a stuck rework unit and list the stuck ones,
a withdrawn consent refuses claims, a purged batch's deliverable is gone, SVG uploads are refused, and a reviewer
reads a task only while holding it."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from yantra_common.events import Envelope
from yantra_common.testing import FakeStorage
from yantra_market import service as market_service
from yantra_market.consumers import on_consent_withdrawn, on_verdict_rejected
from yantra_market.models import DeliveryManifest, WorkUnit
from yantra_market.testing import good_lines, verdict_event
from yantra_quality.testing import open_task
from yantra_work.app import create_app

OPS_ID = str(uuid.uuid4())
OPS = {"X-Role": "ops", "X-Worker-Id": OPS_ID}


@pytest.fixture
def client(factory):
    return TestClient(create_app(factory, rate_limit_per_minute=1000, storage=FakeStorage()))


def worker_headers(worker: str) -> dict[str, str]:
    return {"X-Role": "worker", "X-Worker-Id": worker}


def open_batch(client: TestClient, n: int = 1) -> str:
    p = client.post(
        "/v1/projects",
        json={"name": "p", "currency": "INR", "payload_schema": {"type": "object"}, "cert_gate": "t"},
        headers=OPS,
    ).json()["id"]
    b = client.post(
        f"/v1/projects/{p}/batches", json={"title": "b", "unit_pay": "28", "unit_price": "60"}, headers=OPS
    ).json()["id"]
    lines = good_lines(n)
    r = client.post(f"/v1/batches/{b}/units/import", json={"lines": lines}, params={"dry_run": "false"}, headers=OPS)
    assert r.status_code == 200, r.text
    assert client.post(f"/v1/batches/{b}/publish", json={}, headers=OPS).status_code == 200
    return b


def eligible(client: TestClient) -> str:
    w = str(uuid.uuid4())
    assert (
        client.put(f"/v1/workers/{w}", json={"status": "eligible", "cert_gates": ["t"]}, headers=OPS).status_code == 200
    )
    return w


def test_ops_never_set_their_own_worker_record_or_clearance(client):
    r = client.put(f"/v1/workers/{OPS_ID}", json={"status": "eligible", "cert_gates": ["t"]}, headers=OPS)
    assert (r.status_code, r.json()["code"]) == (403, "self_action")
    r = client.put(f"/v1/quality/reviewers/{OPS_ID}", json={"sensitive_cleared": True}, headers=OPS)
    assert (r.status_code, r.json()["code"]) == (403, "self_action")


def test_a_hand_set_replaces_the_hand_set_gates(client):
    w = eligible(client)
    r = client.put(f"/v1/workers/{w}", json={"status": "eligible", "cert_gates": ["u"]}, headers=OPS)
    assert r.json()["cert_gates"] == ["u"]


def test_unassign_and_the_stuck_assigned_list(client, factory):
    b = open_batch(client)
    author = eligible(client)
    claim = client.post(f"/v1/batches/{b}/claims", headers={**worker_headers(author), "Idempotency-Key": "k-000001"})
    sub = client.post(
        f"/v1/claims/{claim.json()['id']}/submission", json={"answer": {"t": 1}}, headers=worker_headers(author)
    )
    assert sub.status_code == 201, sub.text
    with factory() as s:
        unit = s.scalars(select(WorkUnit)).one()
        e = verdict_event(unit.id, uuid.UUID(b), uuid.UUID(author), "needs_edits", "incomplete")
        on_verdict_rejected(s, Envelope(e.id, e.type, e.subject, datetime.now(UTC) - timedelta(days=5), e.data))
        s.commit()
        unit_id = str(unit.id)
    stuck = client.get("/v1/units/stuck-assigned", headers=OPS).json()
    assert [(r["unit_id"], r["worker_id"], r["days_waiting"]) for r in stuck] == [(unit_id, author, 5)]
    assert client.get("/v1/attention", headers=OPS).json()["stuck_assigned_units"] == 1
    assert client.post(f"/v1/units/{unit_id}/unassign", headers=worker_headers(author)).status_code == 403
    r = client.post(f"/v1/units/{unit_id}/unassign", headers=OPS)
    assert r.status_code == 200 and r.json()["assigned_worker_id"] is None and r.json()["unassigned_by"] == OPS_ID
    again = client.post(f"/v1/units/{unit_id}/unassign", json={"assign_to": author}, headers=OPS)
    assert (again.status_code, again.json()["code"]) == (409, "unit_not_assigned")
    assert client.get("/v1/units/stuck-assigned", params={"days": 0}, headers=OPS).json() == []


def test_a_withdrawn_consent_refuses_claims_over_http(client, factory):
    b = open_batch(client)
    w = eligible(client)
    with factory() as s:
        on_consent_withdrawn(
            s, Envelope(uuid.uuid4(), "worker.consent.withdrawn.v1", "x", datetime.now(UTC), {"worker_id": w})
        )
        s.commit()
    r = client.post(f"/v1/batches/{b}/claims", headers={**worker_headers(w), "Idempotency-Key": "k-000002"})
    assert (r.status_code, r.json()["code"]) == (403, "consent_withdrawn")


def test_a_purged_batch_deliverable_is_gone(client, factory):
    b = open_batch(client)
    w = eligible(client)
    claim = client.post(f"/v1/batches/{b}/claims", headers={**worker_headers(w), "Idempotency-Key": "k-000003"})
    client.post(f"/v1/claims/{claim.json()['id']}/submission", json={"answer": {}}, headers=worker_headers(w))
    with factory() as s:
        s.scalars(select(WorkUnit)).one().status = "accepted"
        s.commit()
    assert client.get(f"/v1/batches/{b}/manifest", headers=OPS).status_code == 200
    with factory() as s:
        m = s.scalars(select(DeliveryManifest)).one()
        assert market_service.purge_due_batches(s, None, now=m.created_at + timedelta(days=181)) == 1
    r = client.get(f"/v1/batches/{b}/deliverable", headers=OPS)
    assert (r.status_code, r.json()["code"]) == (410, "batch_purged")


def test_svg_uploads_are_refused(client):
    p = client.post(
        "/v1/projects", json={"name": "p", "currency": "INR", "payload_schema": {"type": "object"}}, headers=OPS
    ).json()["id"]
    b = client.post(
        f"/v1/projects/{p}/batches", json={"title": "b", "unit_pay": "28", "unit_price": "60"}, headers=OPS
    ).json()["id"]
    files = [{"name": "x.svg", "content_type": "image/svg+xml", "size_bytes": 10}]
    assert client.post(f"/v1/batches/{b}/payload-uploads", json={"files": files}, headers=OPS).status_code == 422


def test_the_reviewer_loses_the_task_and_its_media_once_the_verdict_is_in(client, factory):
    reviewer = str(uuid.uuid4())
    h = {"X-Role": "reviewer", "X-Worker-Id": reviewer}
    with factory() as s:
        open_task(s, uuid.uuid4(), uuid.uuid4(), uuid.UUID(int=0))  # outside the audit sample
    task = client.post("/v1/quality/reviews/claim", headers=h).json()
    assert client.get(f"/v1/quality/tasks/{task['id']}", headers=h).status_code == 200
    assert (
        client.post(f"/v1/quality/tasks/{task['id']}/review", json={"verdict": "accept"}, headers=h).status_code == 200
    )
    assert client.get(f"/v1/quality/tasks/{task['id']}", headers=h).status_code == 404
    assert client.get(f"/v1/quality/tasks/{task['id']}/payload-url", headers=h).status_code == 404
