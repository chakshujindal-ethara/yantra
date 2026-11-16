"""The operator's surface of the market over HTTP: project lists and edits, batch summaries, the batch lifecycle,
the units table, the bench and client orgs. Pay and price side by side; every route needs the ops role."""

import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from yantra_market.consumers import on_verdict_accepted, on_verdict_rejected
from yantra_market.models import Claim
from yantra_market.testing import SCHEMA_JSON, good_lines, verdict_event
from yantra_work.app import create_app

OPS = {"X-Role": "ops"}
OPS_WORKER = {"X-Role": "ops,worker", "X-Worker-Id": str(uuid.uuid4())}


@pytest.fixture
def client(factory):
    return TestClient(
        create_app(factory, rate_limit_per_minute=1000, max_body_bytes=200_000), raise_server_exceptions=False
    )


def make_project(client: TestClient, **fields) -> str:
    body = {"name": "p", "currency": "INR", "payload_schema": SCHEMA_JSON, "cert_gate": "t", **fields}
    p = client.post("/v1/projects", json=body, headers=OPS)
    assert p.status_code == 201, p.text
    return p.json()["id"]


def make_batch(client: TestClient, project_id: str, **batch_fields) -> str:
    batch = {"title": "b", "unit_pay": "28", "unit_price": "60", **batch_fields}
    b = client.post(f"/v1/projects/{project_id}/batches", json=batch, headers=OPS)
    assert b.status_code == 201, b.text
    return b.json()["id"]


def eligible(client: TestClient, gates=("t",)) -> str:
    worker = str(uuid.uuid4())
    r = client.put(f"/v1/workers/{worker}", json={"status": "eligible", "cert_gates": list(gates)}, headers=OPS)
    assert r.status_code == 200, r.text
    return worker


def import_and_publish(client: TestClient, batch_id: str, n: int) -> None:
    r = client.post(
        f"/v1/batches/{batch_id}/units/import", json={"lines": good_lines(n)}, params={"dry_run": "false"}, headers=OPS
    )
    assert r.status_code == 200, r.text
    assert client.post(f"/v1/batches/{batch_id}/publish", json={}, headers=OPS).status_code == 200


def claim_and_submit(client: TestClient, batch_id: str, worker: str) -> dict:
    headers = {"X-Role": "worker", "X-Worker-Id": worker, "Idempotency-Key": f"k-{worker}"}
    c = client.post(f"/v1/batches/{batch_id}/claims", headers=headers)
    assert c.status_code == 201, c.text
    s = client.post(f"/v1/claims/{c.json()['id']}/submission", json={"answer": {"t": 1}}, headers=headers)
    assert s.status_code == 201, s.text
    return c.json()


ZERO = {
    k: 0 for k in ("total", "available", "claimed", "submitted", "in_review", "accepted", "rejected", "needs_edits")
}


def test_projects_list_and_detail_carry_counts_batches_reasons_and_feedback(client, factory):
    project_id = make_project(client)
    batch_id = make_batch(client, project_id)
    import_and_publish(client, batch_id, 3)
    worker = eligible(client)
    claim = claim_and_submit(client, batch_id, worker)
    with factory() as s:
        env = verdict_event(
            uuid.UUID(claim["unit_id"]), uuid.UUID(batch_id), uuid.UUID(worker), "needs_edits", "incomplete"
        )
        on_verdict_rejected(s, env)
        s.commit()
    rows = client.get("/v1/projects", headers=OPS)
    assert rows.status_code == 200 and len(rows.json()) == 1
    [row] = rows.json()
    assert row["id"] == project_id and row["batch_count"] == 1 and row["client_org_id"] is None
    assert row["units"] == {**ZERO, "total": 3, "available": 3} and row["created_at"]
    assert Decimal(row["margin_floor"] or "0") == 0 and row["cert_gate"] == "t"
    detail = client.get(f"/v1/projects/{project_id}", headers=OPS)
    assert detail.status_code == 200
    d = detail.json()
    assert d["payload_schema"] == SCHEMA_JSON and d["sensitive"] is False and d["rubric_log"] == []
    assert d["reasons"] == [{"reason_code": "incomplete", "count": 1, "billable": False}] and d["feedback"] == []
    [b] = d["batches"]
    assert b["id"] == batch_id and b["project_name"] == "p" and b["live_claims"] == 0 and b["manifest"] is None
    assert Decimal(b["unit_pay"]) == 28 and Decimal(b["unit_price"]) == 60
    assert client.get(f"/v1/projects/{uuid.uuid4()}", headers=OPS).status_code == 404
    assert client.get("/v1/projects").status_code == 403
    assert client.get("/v1/projects", headers={"X-Role": "client"}).status_code == 403


def test_patch_project_edits_fields_bumps_the_rubric_and_checks_the_answer_schema(client):
    project_id = make_project(client)
    org = client.post("/v1/client-orgs", json={"name": "Acme"}, headers=OPS).json()
    body = {
        "name": "Renamed",
        "status": "closed",
        "rubric_version": "v2",
        "rubric_note": "glossary",
        "margin_floor": "0.2",
        "cert_gate": "u",
        "brief": "brief",
        "llm_policy": "none",
        "sensitive": True,
        "client_org_id": org["id"],
        "answer_schema": {"type": "object"},
    }
    r = client.patch(f"/v1/projects/{project_id}", json=body, headers=OPS)
    assert r.status_code == 200, r.text
    d = r.json()
    assert (d["name"], d["status"], d["rubric_version"], d["cert_gate"]) == ("Renamed", "closed", "v2", "u")
    assert (d["brief"], d["llm_policy"], d["sensitive"], d["client_org_id"]) == ("brief", "none", True, org["id"])
    assert Decimal(d["margin_floor"]) == Decimal("0.2") and d["answer_schema"] == {"type": "object"}
    assert (
        len(d["rubric_log"]) == 1 and d["rubric_log"][0]["version"] == "v2" and d["rubric_log"][0]["note"] == "glossary"
    )
    assert client.patch(f"/v1/projects/{project_id}", json={"status": "nope"}, headers=OPS).status_code == 422
    assert client.patch(f"/v1/projects/{project_id}", json={"currency": "USD"}, headers=OPS).status_code == 422
    bad = client.patch(f"/v1/projects/{project_id}", json={"answer_schema": {"$ref": "#/x"}}, headers=OPS)
    assert bad.status_code == 422 and bad.json()["message"] == "answer_schema: $ref is not allowed"
    big = {"type": "string", "enum": [f"option-{i:06d}" for i in range(6000)]}
    huge = client.patch(f"/v1/projects/{project_id}", json={"answer_schema": big}, headers=OPS)
    assert huge.status_code == 422 and huge.json()["message"] == "answer_schema: over 64 KB"
    cleared = client.patch(f"/v1/projects/{project_id}", json={"answer_schema": None}, headers=OPS)
    assert cleared.status_code == 200 and cleared.json()["answer_schema"] is None
    missing_org = client.patch(f"/v1/projects/{project_id}", json={"client_org_id": str(uuid.uuid4())}, headers=OPS)
    assert missing_org.status_code == 404
    assert client.patch(f"/v1/projects/{uuid.uuid4()}", json={"name": "x"}, headers=OPS).status_code == 404
    assert client.patch(f"/v1/projects/{project_id}", json={"name": "x"}).status_code == 403


def test_batch_summary_counts_live_claims_and_the_manifest(client, factory):
    project_id = make_project(client)
    batch_id = make_batch(client, project_id)
    import_and_publish(client, batch_id, 2)
    w1, w2 = eligible(client), eligible(client)
    c1 = claim_and_submit(client, batch_id, w1)
    c2 = client.post(
        f"/v1/batches/{batch_id}/claims", headers={"X-Role": "worker", "X-Worker-Id": w2, "Idempotency-Key": f"k-{w2}"}
    )
    assert c2.status_code == 201
    r = client.get(f"/v1/batches/{batch_id}", headers=OPS)
    assert r.status_code == 200
    b = r.json()
    assert b["units"] == {**ZERO, "total": 2, "claimed": 1, "submitted": 1} and b["live_claims"] == 1
    assert b["status"] == "published" and b["published_at"] and b["manifest"] is None and b["project_id"] == project_id
    with factory() as s:
        s.get(Claim, uuid.UUID(c2.json()["id"])).expires_at = datetime.now(UTC) - timedelta(seconds=1)
        s.commit()
    assert client.get(f"/v1/batches/{batch_id}", headers=OPS).json()["live_claims"] == 0
    with factory() as s:  # back inside the TTL: the worker submits, both verdicts accept, the gate passes
        s.get(Claim, uuid.UUID(c2.json()["id"])).expires_at = datetime.now(UTC) + timedelta(hours=1)
        s.commit()
    sub = client.post(
        f"/v1/claims/{c2.json()['id']}/submission",
        json={"answer": {"t": 2}},
        headers={"X-Role": "worker", "X-Worker-Id": w2},
    )
    assert sub.status_code == 201, sub.text
    with factory() as s:
        on_verdict_accepted(s, verdict_event(uuid.UUID(c1["unit_id"]), uuid.UUID(batch_id), uuid.UUID(w1)))
        on_verdict_accepted(s, verdict_event(uuid.UUID(c2.json()["unit_id"]), uuid.UUID(batch_id), uuid.UUID(w2)))
        s.commit()
    assert client.get(f"/v1/batches/{batch_id}/manifest", headers=OPS).status_code == 200
    b = client.get(f"/v1/batches/{batch_id}", headers=OPS).json()
    assert b["status"] == "completed" and b["manifest"]["accepted_units"] == 2 and len(b["manifest"]["digest"]) == 64
    assert Decimal(b["manifest"]["total_price"]) == 120 and b["units"]["accepted"] == 2
    assert client.get(f"/v1/batches/{uuid.uuid4()}", headers=OPS).status_code == 404
    assert client.get(f"/v1/batches/{batch_id}").status_code == 403
    assert client.get(f"/v1/batches/{batch_id}", headers={"X-Role": "worker"}).status_code == 403


def test_the_units_table_filters_and_pages_with_a_capped_limit(client):
    project_id = make_project(client)
    batch_id = make_batch(client, project_id)
    import_and_publish(client, batch_id, 3)
    worker = eligible(client)
    claim = claim_and_submit(client, batch_id, worker)
    page = client.get(f"/v1/batches/{batch_id}/units", params={"limit": 2}, headers=OPS)
    assert page.status_code == 200 and page.json()["total"] == 3 and len(page.json()["items"]) == 2
    assert set(page.json()["items"][0]) == {
        "id",
        "external_ref",
        "status",
        "assigned_worker_id",
        "current_claim_id",
        "created_at",
    }
    rest = client.get(f"/v1/batches/{batch_id}/units", params={"limit": 2, "offset": 2}, headers=OPS).json()
    assert rest["total"] == 3 and len(rest["items"]) == 1
    sub = client.get(f"/v1/batches/{batch_id}/units", params={"status": "submitted"}, headers=OPS).json()
    assert (
        sub["total"] == 1
        and sub["items"][0]["id"] == claim["unit_id"]
        and sub["items"][0]["current_claim_id"] == claim["id"]
    )
    bad = client.get(f"/v1/batches/{batch_id}/units", params={"status": "nope"}, headers=OPS)
    assert bad.status_code == 422 and bad.json()["message"].startswith("status: not one of")
    assert client.get(f"/v1/batches/{batch_id}/units", params={"limit": 201}, headers=OPS).status_code == 422
    assert client.get(f"/v1/batches/{batch_id}/units", params={"limit": 0}, headers=OPS).status_code == 422
    assert client.get(f"/v1/batches/{batch_id}/units", params={"offset": -1}, headers=OPS).status_code == 422
    assert client.get(f"/v1/batches/{uuid.uuid4()}/units", headers=OPS).status_code == 404
    assert client.get(f"/v1/batches/{batch_id}/units").status_code == 403


def test_pause_resume_and_cancel_over_http(client):
    project_id = make_project(client)
    batch_id = make_batch(client, project_id)
    assert client.post(f"/v1/batches/{batch_id}/pause", headers=OPS).status_code == 409
    import_and_publish(client, batch_id, 2)
    worker, other = eligible(client), eligible(client)
    headers = {"X-Role": "worker", "X-Worker-Id": worker, "Idempotency-Key": "pause-0001"}
    c = client.post(f"/v1/batches/{batch_id}/claims", headers=headers)
    assert c.status_code == 201
    paused = client.post(f"/v1/batches/{batch_id}/pause", headers=OPS)
    assert paused.status_code == 200 and paused.json()["status"] == "paused" and paused.json()["live_claims"] == 1
    assert client.get("/v1/batches", headers={"X-Role": "worker", "X-Worker-Id": other}).json() == []
    refused = client.post(
        f"/v1/batches/{batch_id}/claims",
        headers={"X-Role": "worker", "X-Worker-Id": other, "Idempotency-Key": "pause-0002"},
    )
    assert refused.status_code == 409 and refused.json()["code"] == "batch_paused"
    cancel = client.post(f"/v1/batches/{batch_id}/cancel", headers=OPS)
    assert cancel.status_code == 409 and cancel.json()["code"] == "batch_has_live_claims"
    sub = client.post(f"/v1/claims/{c.json()['id']}/submission", json={"answer": {"t": 1}}, headers=headers)
    assert sub.status_code == 201  # in flight: still submits on a paused batch
    assert client.post(f"/v1/batches/{batch_id}/resume", headers=OPS).json()["status"] == "published"
    assert client.post(f"/v1/batches/{batch_id}/resume", headers=OPS).status_code == 409
    assert len(client.get("/v1/batches", headers={"X-Role": "worker", "X-Worker-Id": other}).json()) == 1
    done = client.post(f"/v1/batches/{batch_id}/cancel", headers=OPS)
    assert done.status_code == 200 and done.json()["status"] == "cancelled"
    assert client.post(f"/v1/batches/{batch_id}/cancel", headers=OPS).status_code == 409
    assert client.post(f"/v1/batches/{uuid.uuid4()}/pause", headers=OPS).status_code == 404
    for move in ("pause", "resume", "cancel"):
        assert client.post(f"/v1/batches/{batch_id}/{move}").status_code == 403


def test_the_bench_lists_and_reads_workers_with_availability(client):
    a = eligible(client, gates=("t", "u"))
    b = eligible(client, gates=("u",))
    client.put(f"/v1/workers/{uuid.uuid4()}", json={"status": "suspended", "cert_gates": []}, headers=OPS)
    pause = (datetime.now(UTC) + timedelta(days=2)).replace(microsecond=0)
    client.put(
        "/v1/workers/me/availability",
        json={"weekly_hours": 9, "paused_until": pause.isoformat()},
        headers={"X-Role": "worker", "X-Worker-Id": a},
    )
    page = client.get("/v1/workers", headers=OPS)
    assert page.status_code == 200 and page.json()["total"] == 3 and len(page.json()["items"]) == 3
    gated = client.get("/v1/workers", params={"gate": "t"}, headers=OPS).json()
    assert gated["total"] == 1 and gated["items"][0]["id"] == a
    assert gated["items"][0]["availability"]["weekly_hours"] == 9 and gated["items"][0]["cert_gates"] == ["t", "u"]
    assert client.get("/v1/workers", params={"status": "suspended"}, headers=OPS).json()["total"] == 1
    prefix = client.get("/v1/workers", params={"q": a[:6]}, headers=OPS).json()
    assert prefix["total"] == 1 and prefix["items"][0]["id"] == a
    assert client.get("/v1/workers", params={"q": "zz%"}, headers=OPS).status_code == 422
    assert client.get("/v1/workers", params={"limit": 1, "offset": 1}, headers=OPS).json()["total"] == 3
    one = client.get(f"/v1/workers/{b}", headers=OPS)
    assert one.status_code == 200 and one.json()["id"] == b and one.json()["availability"] is None
    assert one.json()["status"] == "eligible" and one.json()["updated_at"]
    assert client.get(f"/v1/workers/{uuid.uuid4()}", headers=OPS).status_code == 404
    assert client.get("/v1/workers").status_code == 403
    assert client.get(f"/v1/workers/{b}").status_code == 403
    assert (
        client.get("/v1/workers/me", headers={"X-Role": "worker", "X-Worker-Id": b}).json()["status"] == "eligible"
    )  # still the worker's own route


def test_client_orgs_and_membership(client):
    r = client.post("/v1/client-orgs", json={"name": "Acme"}, headers=OPS)
    assert r.status_code == 201 and r.json()["name"] == "Acme" and r.json()["members"] == [] and r.json()["created_at"]
    org_id = r.json()["id"]
    user = str(uuid.uuid4())
    put = client.put(f"/v1/client-orgs/{org_id}/members/{user}", headers=OPS)
    assert put.status_code == 200 and put.json() == {"org_id": org_id, "user_id": user, "member": True}
    assert client.put(f"/v1/client-orgs/{org_id}/members/{user}", headers=OPS).status_code == 200
    assert client.get("/v1/client-orgs", headers=OPS).json() == [{**r.json(), "members": [user]}]
    gone = client.delete(f"/v1/client-orgs/{org_id}/members/{user}", headers=OPS)
    assert gone.status_code == 200 and gone.json()["member"] is False
    assert client.get("/v1/client-orgs", headers=OPS).json()[0]["members"] == []
    assert client.put(f"/v1/client-orgs/{uuid.uuid4()}/members/{user}", headers=OPS).status_code == 404
    assert client.delete(f"/v1/client-orgs/{uuid.uuid4()}/members/{user}", headers=OPS).status_code == 404
    assert client.post("/v1/client-orgs", json={"name": ""}, headers=OPS).status_code == 422
    assert client.post("/v1/client-orgs", json={"name": "x"}, headers={"X-Role": "client"}).status_code == 403
    assert client.get("/v1/client-orgs").status_code == 403
    assert client.put(f"/v1/client-orgs/{org_id}/members/{user}", headers={"X-Role": "worker"}).status_code == 403


def test_an_operator_who_is_also_a_worker_passes_every_ops_gate(client):
    assert client.get("/v1/projects", headers=OPS_WORKER).status_code == 200
    assert client.get("/v1/workers", headers=OPS_WORKER).status_code == 200
    assert client.get("/v1/client-orgs", headers=OPS_WORKER).status_code == 200
