"""The new talent routes through the work deployable: the caller recorded from `X-Name`, people/me, policies,
documents through storage, erasure, attention, applicant names and hired-this-week."""

import hashlib
import uuid
from urllib.parse import quote

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from yantra_common.testing import FakeStorage
from yantra_talent import service
from yantra_talent.models import OUTBOX
from yantra_talent.testing import reset_policies
from yantra_work.app import create_app

OPS_ID = str(uuid.uuid4())
OPS = {"X-Role": "ops", "X-Worker-Id": OPS_ID, "X-Name": "Ops%20One"}
LISTING = {
    "title": "Hindi transcription",
    "domain": "transcription",
    "summary": "Short clips",
    "pay_min": "20",
    "pay_max": "30",
    "currency": "INR",
    "commitment": "task_based",
    "slots_total": 2,
    "cert_gate": "transcription",
    "questions": [{"key": "experience", "prompt": "Years", "kind": "text", "required": True}],
    "status": "open",
}


@pytest.fixture
def storage():
    return FakeStorage()


@pytest.fixture
def client(factory, storage):
    service._seen.clear()
    app = create_app(factory, rate_limit_per_minute=1000)
    app.state.storage = storage
    yield TestClient(app, raise_server_exceptions=False)
    with factory() as s:
        reset_policies(s)


def worker(name: str | None = "Worker One") -> dict[str, str]:
    headers = {"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4())}
    if name is not None:
        headers["X-Name"] = quote(name, safe="")
    return headers


def test_the_caller_is_recorded_from_x_name_and_people_me_returns_it(client, factory):
    w = worker("आशा रानी")
    me = client.put("/v1/talent/people/me", headers=w)
    assert me.status_code == 200 and me.json() == {"id": w["X-Worker-Id"], "name": "आशा रानी", "kind": "worker"}
    staff = client.put("/v1/talent/people/me", headers=OPS)
    assert staff.json()["kind"] == "staff" and staff.json()["name"] == "Ops One"
    nameless = client.put("/v1/talent/people/me", headers=worker(None))
    assert nameless.status_code == 404
    with factory() as s:
        seen = [p for (p,) in s.execute(select(OUTBOX.c.payload).where(OUTBOX.c.type == "talent.person.seen.v1"))]
    assert {p["name"] for p in seen} == {"आशा रानी", "Ops One"}


def test_policies_read_by_anyone_versioned_by_ops(client):
    anyone = {"X-Role": "client", "X-Worker-Id": str(uuid.uuid4())}
    rows = client.get("/v1/talent/policies", headers=anyone)
    assert rows.status_code == 200 and {p["slug"] for p in rows.json()} >= {"contractor-agreement", "pay-cycle"}
    body = {"title": "Pay cycle", "summary": "s", "sections": [{"title": "t", "paragraphs": ["p"]}]}
    assert client.put("/v1/talent/policies/pay-cycle", json=body, headers=worker()).status_code == 403
    v2 = client.put("/v1/talent/policies/pay-cycle", json=body, headers=OPS)
    assert v2.status_code == 200 and (v2.json()["revision"], v2.json()["version"]) == (2, "2")
    assert client.get("/v1/talent/policies/pay-cycle", headers=anyone).json()["revision"] == 2
    assert client.get("/v1/talent/policies/pay-cycle", params={"revision": 1}, headers=anyone).json()["revision"] == 1
    assert client.get("/v1/talent/policies/nope", headers=anyone).status_code == 404


def test_documents_go_through_storage_and_ops_get_a_short_link(client, storage):
    w = worker()
    presign = client.post(
        "/v1/talent/workers/me/documents/presign",
        json={"kind": "identity_front", "content_type": "image/png", "size_bytes": 4},
        headers=w,
    )
    assert presign.status_code == 200 and presign.json()["method"] == "PUT"
    key = presign.json()["key"]
    storage.put(key, b"\x89PNG", "image/png")
    body = {"key": key, "sha256": hashlib.sha256(b"\x89PNG").hexdigest(), "size_bytes": 4}
    doc = client.put("/v1/talent/workers/me/documents/identity_front", json=body, headers=w)
    assert doc.status_code == 200 and doc.json()["content_type"] == "image/png"
    assert [d["kind"] for d in client.get("/v1/talent/workers/me/documents", headers=w).json()] == ["identity_front"]
    wid = w["X-Worker-Id"]
    assert client.get(f"/v1/talent/workers/{wid}/documents", headers=w).status_code == 403
    assert len(client.get(f"/v1/talent/workers/{wid}/documents", headers=OPS).json()) == 1
    url = client.get(f"/v1/talent/workers/{wid}/documents/identity_front/url", headers=OPS)
    assert url.status_code == 200 and url.json()["url"].startswith("fake://")
    too_big = client.post(
        "/v1/talent/workers/me/documents/presign",
        json={"kind": "identity_front", "content_type": "image/png", "size_bytes": 11 * 1024 * 1024},
        headers=w,
    )
    assert too_big.status_code == 422
    onboarding = client.get("/v1/talent/workers/me/onboarding", headers=w).json()
    assert [d["kind"] for d in onboarding["documents"]] == ["identity_front"]


def test_documents_without_storage_are_a_503(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000), raise_server_exceptions=False)
    r = client.post(
        "/v1/talent/workers/me/documents/presign",
        json={"kind": "identity_front", "content_type": "image/png", "size_bytes": 4},
        headers=worker(),
    )
    assert r.status_code == 503 and r.json()["code"] == "storage_unconfigured"


def test_erasure_request_ops_approval_and_attention(client):
    w = worker()
    made = client.post("/v1/talent/workers/me/erasure", headers=w)
    assert made.status_code == 201 and made.json()["status"] == "requested"
    again = client.post("/v1/talent/workers/me/erasure", headers=w)
    assert again.status_code == 409 and again.json()["code"] == "erasure_pending"
    assert client.get("/v1/talent/erasures", headers=w).status_code == 403
    assert [e["worker_id"] for e in client.get("/v1/talent/erasures", headers=OPS).json()] == [w["X-Worker-Id"]]
    approved = client.post(f"/v1/talent/erasures/{w['X-Worker-Id']}/approve", headers=OPS)
    assert approved.status_code == 200 and approved.json()["approved_by"] == OPS_ID
    assert (
        client.get("/v1/talent/erasures", params={"status": "approved"}, headers=OPS).json()[0]["status"] == "approved"
    )
    attention = client.get("/v1/talent/attention", headers=OPS)
    assert attention.status_code == 200 and attention.json()["erasures_due"] == 1
    assert client.get("/v1/talent/workers/me/onboarding", headers=w).json()["erasure"]["status"] == "approved"


def test_ops_see_names_steps_and_hired_this_week(client):
    listing = client.post("/v1/talent/listings", json={**LISTING, "steps": ["form", "availability"]}, headers=OPS)
    assert listing.status_code == 201 and listing.json()["steps"] == ["form", "availability"]
    lid = listing.json()["id"]
    w = worker("Asha Rani")
    app = client.post(f"/v1/talent/listings/{lid}/applications", json={"answers": {"experience": "3"}}, headers=w)
    assert app.status_code == 201 and app.json()["steps"] == [
        {"kind": "form", "status": "done"},
        {"kind": "availability", "status": "done"},
    ]
    client.post(f"/v1/talent/applications/{app.json()['id']}/decide", json={"decision": "offer"}, headers=OPS)
    client.post(f"/v1/talent/applications/{app.json()['id']}/offer", json={"accept": True}, headers=w)
    rows = client.get(f"/v1/talent/listings/{lid}/applications", headers=OPS).json()
    assert rows[0]["worker_name"] == "Asha Rani" and rows[0]["paper"] is None
    ops_list = client.get("/v1/talent/listings", params={"all": "true"}, headers=OPS).json()
    assert ops_list[0]["hired_this_week"] == 1
    assert client.get("/v1/talent/listings", headers=worker()).json()[0]["hired_this_week"] == 1
    assert client.get(f"/v1/talent/listings/{lid}", headers=worker()).json()["hired_this_week"] == 1
