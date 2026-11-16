"""The HTTP surface through the work deployable, against the migrated test database."""

import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from yantra_common.events import Envelope
from yantra_market.consumers import on_assess_certified
from yantra_market.testing import SCHEMA_JSON, good_lines
from yantra_work.app import create_app

OPS = {"X-Role": "ops"}


@pytest.fixture
def client(factory):
    return TestClient(
        create_app(factory, rate_limit_per_minute=1000, max_body_bytes=200_000), raise_server_exceptions=False
    )


def certified_event(worker_id: uuid.UUID, gate: str) -> Envelope:
    data = {"worker_id": str(worker_id), "gate": gate, "paper_id": str(uuid.uuid4()), "score": "0.9"}
    return Envelope(uuid.uuid4(), "assess.certified.v1", f"worker/{worker_id}", datetime.now(UTC), data)


def make_batch(client: TestClient, **batch_fields) -> str:
    body = {"name": "p", "currency": "INR", "payload_schema": SCHEMA_JSON, "cert_gate": "t"}
    p = client.post("/v1/projects", json=body, headers=OPS)
    assert p.status_code == 201, p.text
    batch = {"title": "b", "unit_pay": "28", "unit_price": "60", **batch_fields}
    b = client.post(f"/v1/projects/{p.json()['id']}/batches", json=batch, headers=OPS)
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


def test_full_loop_over_http(client):
    batch_id = make_batch(client)
    dry = client.post(f"/v1/batches/{batch_id}/units/import", json={"lines": good_lines(2)}, headers=OPS)
    assert dry.status_code == 200 and dry.json() == {"total": 2, "accepted": 2, "dry_run": True, "errors": []}
    real = client.post(
        f"/v1/batches/{batch_id}/units/import", json={"lines": good_lines(2)}, params={"dry_run": "false"}, headers=OPS
    )
    assert real.status_code == 200 and real.json()["dry_run"] is False
    pub = client.post(f"/v1/batches/{batch_id}/publish", json={}, headers=OPS)
    assert pub.status_code == 200 and pub.json()["status"] == "published"
    assert Decimal(pub.json()["unit_price"]) == Decimal("60")
    worker = eligible(client)
    headers = {"X-Role": "worker", "X-Worker-Id": worker, "Idempotency-Key": "claim-0001"}
    c1 = client.post(f"/v1/batches/{batch_id}/claims", headers=headers)
    c2 = client.post(f"/v1/batches/{batch_id}/claims", headers=headers)
    assert c1.status_code == 201 and c2.status_code == 201 and c1.json()["id"] == c2.json()["id"]
    unit = client.get(f"/v1/units/{c1.json()['unit_id']}", headers=headers)
    assert unit.status_code == 200 and unit.json()["status"] == "claimed"
    assert Decimal(unit.json()["unit_pay"]) == Decimal("28") and "unit_price" not in unit.json()
    second = client.post(f"/v1/batches/{batch_id}/claims", headers={**headers, "Idempotency-Key": "claim-0002"})
    assert second.status_code == 409 and second.json()["code"] == "one_live_claim"
    sub = client.post(f"/v1/claims/{c1.json()['id']}/submission", json={"answer": {"t": 1}}, headers=headers)
    assert sub.status_code == 201 and sub.json()["rubric_version"] == "v1"
    assert client.get(f"/v1/units/{c1.json()['unit_id']}", headers=headers).json()["status"] == "submitted"
    assert client.post("/v1/claims/release-expired", headers=OPS).json() == {"released": 0, "more": False}
    assert client.get("/ready").json() == {
        "status": "ok",
        # published, claimed, submitted, and the gates the ops PUT set (worker.gates.set.v1)
        "outbox_unpublished": {"market": 4, "talent": 0, "assess": 0, "quality": 0, "tracker": 0},
        "outbox_stale": False,
    }


def test_a_unit_is_visible_only_to_the_worker_holding_its_claim(client):
    batch_id = make_batch(client)
    import_and_publish(client, batch_id, 2)
    a, b = eligible(client), eligible(client)
    c = client.post(
        f"/v1/batches/{batch_id}/claims", headers={"X-Role": "worker", "X-Worker-Id": a, "Idempotency-Key": "a-000001"}
    )
    unit_id = c.json()["unit_id"]
    assert client.get(f"/v1/units/{unit_id}", headers={"X-Role": "worker", "X-Worker-Id": a}).status_code == 200
    assert client.get(f"/v1/units/{unit_id}", headers={"X-Role": "worker", "X-Worker-Id": b}).status_code == 404
    assert client.get(f"/v1/units/{uuid.uuid4()}", headers={"X-Role": "worker", "X-Worker-Id": a}).status_code == 404
    assert client.get(f"/v1/units/{unit_id}", headers={"X-Role": "worker"}).status_code == 422


def test_ops_routes_require_the_ops_role(client):
    body = {"name": "p", "currency": "INR", "payload_schema": SCHEMA_JSON}
    r = client.post("/v1/projects", json=body)
    assert r.status_code == 403 and r.json()["code"] == "forbidden"
    assert client.post("/v1/projects", json=body, headers={"X-Role": "worker"}).status_code == 403
    assert client.post("/v1/claims/release-expired").status_code == 403
    assert client.put(f"/v1/workers/{uuid.uuid4()}", json={"status": "eligible"}).status_code == 403


def test_a_project_schema_is_checked_before_it_is_stored(client):
    bad = {"name": "p", "currency": "INR", "payload_schema": {"$ref": "https://x/y"}}
    r = client.post("/v1/projects", json=bad, headers=OPS)
    assert r.status_code == 422 and r.json()["code"] == "invalid" and "$ref" in r.json()["message"]


def test_a_project_schema_over_64_kb_is_refused_before_it_is_checked(client):
    big = {"type": "string", "enum": [f"option-{i:06d}" for i in range(6000)]}  # about 96 KB
    for name in ("payload_schema", "answer_schema"):
        body = {"name": "p", "currency": "INR", "payload_schema": SCHEMA_JSON, name: big}
        r = client.post("/v1/projects", json=body, headers=OPS)
        assert r.status_code == 422 and r.json()["message"] == f"{name}: over 64 KB"


def test_errors_are_json_with_a_code_and_the_request_id_is_echoed(client):
    r = client.post(f"/v1/batches/{uuid.uuid4()}/publish", json={}, headers={**OPS, "X-Request-Id": "req-abc-1"})
    assert r.status_code == 404 and r.json()["code"] == "not_found"
    assert r.headers["X-Request-Id"] == "req-abc-1" and r.json()["request_id"] == "req-abc-1"
    r = client.post(
        f"/v1/batches/{uuid.uuid4()}/claims",
        headers={"X-Role": "worker", "X-Worker-Id": "nope", "Idempotency-Key": "k" * 8},
    )
    assert r.status_code == 422 and r.json()["code"] == "validation_error"
    assert r.json()["fields"] == ["header.X-Worker-Id"] and r.headers["X-Request-Id"]


def test_every_not_found_and_wrong_state_has_a_code(client):
    missing = uuid.uuid4()
    b = {"title": "b", "unit_pay": "1", "unit_price": "2"}
    assert client.post(f"/v1/projects/{missing}/batches", json=b, headers=OPS).status_code == 404
    h = {"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4())}
    assert client.post(f"/v1/claims/{missing}/submission", json={"answer": {}}, headers=h).status_code == 404
    batch_id = make_batch(client)
    draft_claim = client.post(f"/v1/batches/{batch_id}/claims", headers={**h, "Idempotency-Key": "draft-00001"})
    assert draft_claim.status_code == 409 and draft_claim.json()["status"] == "draft"
    import_and_publish(client, batch_id, 1)
    late = client.post(
        f"/v1/batches/{batch_id}/units/import", json={"lines": good_lines(1)}, params={"dry_run": "false"}, headers=OPS
    )
    assert late.status_code == 409


def test_oversized_bodies_and_deep_answers_are_refused(client):
    batch_id = make_batch(client)
    import_and_publish(client, batch_id, 1)
    worker = eligible(client)
    headers = {"X-Role": "worker", "X-Worker-Id": worker, "Idempotency-Key": "deep-000001"}
    c = client.post(f"/v1/batches/{batch_id}/claims", headers=headers)
    deep: dict = {"v": 1}
    for _ in range(40):
        deep = {"n": deep}
    r = client.post(f"/v1/claims/{c.json()['id']}/submission", json={"answer": deep}, headers=headers)
    assert r.status_code == 422 and "nests deeper" in r.json()["message"]
    big = client.post(
        f"/v1/batches/{batch_id}/units/import",
        content=b"{" + b" " * 300_000 + b"}",
        headers={**OPS, "content-type": "application/json"},
    )
    assert big.status_code == 413 and big.json()["code"] == "payload_too_large"


def test_worker_upsert_updates_an_existing_profile(client):
    worker = str(uuid.uuid4())
    client.put(f"/v1/workers/{worker}", json={"status": "suspended", "cert_gates": []}, headers=OPS)
    r = client.put(
        f"/v1/workers/{worker}", json={"status": "eligible", "cert_gates": ["t"], "partner_ref": 7}, headers=OPS
    )
    assert r.status_code == 200 and r.json()["id"] == worker and r.json()["partner_ref"] == 7
    batch_id = make_batch(client)
    import_and_publish(client, batch_id, 1)
    c = client.post(
        f"/v1/batches/{batch_id}/claims",
        headers={"X-Role": "worker", "X-Worker-Id": worker, "Idempotency-Key": "up-00001"},
    )
    assert c.status_code == 201


def test_rate_limit_answers_429_with_retry_after_and_ignores_made_up_ids(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=2))
    h = {"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4())}
    assert client.get("/v1/units/x", headers=h).status_code == 422
    assert client.get("/v1/units/x", headers=h).status_code == 422
    r = client.get("/v1/units/x", headers=h)
    assert r.status_code == 429 and r.headers["Retry-After"] == "60" and r.json()["code"] == "rate_limited"
    assert client.get("/v1/units/x", headers={"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4())}).status_code == 422
    # a made-up id is not a fresh bucket: it falls back to the client address bucket
    assert client.get("/v1/units/x", headers={"X-Role": "worker", "X-Worker-Id": "fake-1"}).status_code == 422
    assert client.get("/v1/units/x", headers={"X-Role": "worker", "X-Worker-Id": "fake-2"}).status_code == 422
    assert client.get("/v1/units/x", headers={"X-Role": "worker", "X-Worker-Id": "fake-3"}).status_code == 429
    assert client.get("/health").status_code == 200  # exempt


def test_an_unhandled_error_is_a_json_500_with_the_request_id(client, monkeypatch):
    from yantra_market import service

    def explode(*a, **k):
        raise RuntimeError("boom")

    monkeypatch.setattr(service, "release_expired_claims", explode)
    r = client.post("/v1/claims/release-expired", headers={**OPS, "X-Request-Id": "rid-500"})
    assert r.status_code == 500 and r.json() == {
        "code": "internal_error",
        "message": "internal error",
        "request_id": "rid-500",
    }
    assert r.headers["X-Request-Id"] == "rid-500"


def test_workers_browse_open_batches_and_their_active_claim(client, factory):
    batch_id = make_batch(client)
    worker = eligible(client)
    assert client.get("/v1/batches", headers={"X-Role": "worker", "X-Worker-Id": worker}).json() == []
    import_and_publish(client, batch_id, 2)
    [row] = client.get("/v1/batches", headers={"X-Role": "worker", "X-Worker-Id": worker}).json()
    assert row["id"] == batch_id and row["available_units"] == 2 and "unit_price" not in row
    none = client.get("/v1/claims/active", headers={"X-Role": "worker", "X-Worker-Id": worker})
    assert none.status_code == 200 and none.json() == {"claim": None, "unit": None, "batch": None}
    c = client.post(
        f"/v1/batches/{batch_id}/claims",
        headers={"X-Role": "worker", "X-Worker-Id": worker, "Idempotency-Key": "k-000001"},
    )
    mine = client.get("/v1/claims/active", headers={"X-Role": "worker", "X-Worker-Id": worker}).json()
    assert mine["claim"]["id"] == c.json()["id"] and mine["unit"]["status"] == "claimed"
    assert (
        mine["batch"]["id"] == batch_id and mine["batch"]["project_name"] == "p" and "unit_price" not in mine["batch"]
    )
    assert "unit_price" not in mine["unit"]
    assert (
        client.get("/v1/batches", headers={"X-Role": "worker", "X-Worker-Id": worker}).json()[0]["available_units"] == 1
    )


def test_an_oversized_answer_is_422(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000, max_body_bytes=8 << 20))
    batch_id = make_batch(client)
    import_and_publish(client, batch_id, 1)
    w = eligible(client)
    c = client.post(
        f"/v1/batches/{batch_id}/claims",
        headers={"X-Role": "worker", "X-Worker-Id": w, "Idempotency-Key": "big-000001"},
    )
    big = {"answer": {"blob": "x" * (256 * 1024 + 1)}}
    r = client.post(f"/v1/claims/{c.json()['id']}/submission", json=big, headers={"X-Role": "worker", "X-Worker-Id": w})
    assert r.status_code == 422 and "256 KB" in r.json()["message"]


def test_the_delivery_gate_holds_a_batch_until_every_unit_is_accepted(client, factory):
    from yantra_market.models import WorkUnit

    batch_id = make_batch(client)
    import_and_publish(client, batch_id, 2)
    assert client.get(f"/v1/batches/{batch_id}/manifest").status_code == 403
    held = client.get(f"/v1/batches/{batch_id}/manifest", headers=OPS)
    assert held.status_code == 409 and held.json()["code"] == "batch_held" and held.json()["held"] == {"available": 2}
    for _ in range(2):
        w = eligible(client)
        c = client.post(
            f"/v1/batches/{batch_id}/claims",
            headers={"X-Role": "worker", "X-Worker-Id": w, "Idempotency-Key": f"k-{w}"},
        )
        assert (
            client.post(
                f"/v1/claims/{c.json()['id']}/submission",
                json={"answer": {"t": 1}},
                headers={"X-Role": "worker", "X-Worker-Id": w},
            ).status_code
            == 201
        )
    with factory() as s:
        for u in s.query(WorkUnit).all():
            u.status = "accepted"
        s.commit()
    m = client.get(f"/v1/batches/{batch_id}/manifest", headers=OPS)
    assert m.status_code == 200 and m.json()["accepted_units"] == 2 and Decimal(m.json()["total_price"]) == 120
    assert m.json()["units"][0]["answer"] == {"t": 1} and len(m.json()["digest"]) == 64
    assert client.get(f"/v1/batches/{batch_id}/manifest", headers=OPS).json()["id"] == m.json()["id"]


ANSWER_SCHEMA = {"type": "object", "required": ["transcript"], "properties": {"transcript": {"type": "string"}}}


def test_me_is_never_404_and_shows_the_profile_and_availability_once_they_exist(client):
    worker = str(uuid.uuid4())
    r = client.get("/v1/workers/me", headers={"X-Role": "worker", "X-Worker-Id": worker})
    assert r.status_code == 200 and r.json() == {
        "id": worker,
        "status": "unknown",
        "cert_gates": [],
        "partner_ref": None,
        "updated_at": None,
        "availability": None,
    }
    assert client.get("/v1/workers/me", headers={"X-Role": "worker"}).status_code == 422
    client.put(f"/v1/workers/{worker}", json={"status": "eligible", "cert_gates": ["t"], "partner_ref": 9}, headers=OPS)
    pause = (datetime.now(UTC) + timedelta(days=30)).replace(microsecond=0)
    a = client.put(
        "/v1/workers/me/availability",
        json={"weekly_hours": 12, "paused_until": pause.isoformat()},
        headers={"X-Role": "worker", "X-Worker-Id": worker},
    )
    assert a.status_code == 200 and a.json()["weekly_hours"] == 12 and a.json()["updated_at"]
    assert a.json()["paused_until"] == pause.isoformat().replace("+00:00", "Z")
    me = client.get("/v1/workers/me", headers={"X-Role": "worker", "X-Worker-Id": worker}).json()
    assert (me["status"], me["cert_gates"], me["partner_ref"]) == ("eligible", ["t"], 9) and me["updated_at"]
    assert me["availability"] == a.json()


def test_an_odoo_push_merges_gates_and_never_wipes_one_granted_by_an_event(client, factory):
    worker = str(uuid.uuid4())
    with factory() as s:
        on_assess_certified(s, certified_event(uuid.UUID(worker), "hindi-translation"))
        s.commit()
    pushed = client.put(f"/v1/workers/{worker}", json={"status": "eligible", "cert_gates": ["t"]}, headers=OPS)
    assert pushed.status_code == 200 and pushed.json()["cert_gates"] == ["hindi-translation", "t"]
    again = client.put(f"/v1/workers/{worker}", json={"status": "active", "partner_ref": 7}, headers=OPS)
    assert (again.json()["status"], again.json()["cert_gates"], again.json()["partner_ref"]) == (
        "active",
        ["hindi-translation", "t"],
        7,
    )
    fresh = client.put(f"/v1/workers/{uuid.uuid4()}", json={"status": "eligible"}, headers=OPS)
    assert fresh.status_code == 200 and fresh.json()["cert_gates"] == []


def test_a_client_only_caller_is_refused_every_worker_surface_and_an_operator_may_walk_it(client):
    batch_id = make_batch(client)
    client_only, ops_only = (
        {"X-Role": "client", "X-Worker-Id": str(uuid.uuid4())},
        {"X-Role": "ops", "X-Worker-Id": str(uuid.uuid4())},
    )
    for method, path in (
        ("GET", "/v1/batches"),
        ("GET", "/v1/claims/active"),
        ("POST", f"/v1/batches/{batch_id}/claims"),
        ("POST", f"/v1/claims/{uuid.uuid4()}/submission"),
        ("GET", f"/v1/units/{uuid.uuid4()}"),
        ("GET", "/v1/workers/me"),
        ("PUT", "/v1/workers/me/availability"),
    ):
        r = client.request(method, path, headers={**client_only, "Idempotency-Key": "client-0001"}, json={})
        assert (r.status_code, r.json()["message"]) == (403, "worker role required"), (method, path, r.text)
        assert client.request(method, path, headers={**ops_only, "Idempotency-Key": "ops-00001"}).status_code != 403
    assert client.get("/v1/batches", headers={"X-Role": "", "X-Worker-Id": str(uuid.uuid4())}).status_code == 403


def test_availability_needs_no_profile_and_rejects_more_than_80_hours_or_a_naive_pause(client):
    worker = {"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4())}
    r = client.put("/v1/workers/me/availability", json={"weekly_hours": 0}, headers=worker)
    assert r.status_code == 200 and r.json()["paused_until"] is None
    again = client.put("/v1/workers/me/availability", json={"weekly_hours": 80, "paused_until": None}, headers=worker)
    assert again.status_code == 200 and again.json()["weekly_hours"] == 80
    assert client.get("/v1/workers/me", headers=worker).json()["availability"]["weekly_hours"] == 80
    too_many = client.put("/v1/workers/me/availability", json={"weekly_hours": 81}, headers=worker)
    assert too_many.status_code == 422 and too_many.json()["code"] == "validation_error"
    assert too_many.json()["fields"] == ["body.weekly_hours"]
    naive = client.put(
        "/v1/workers/me/availability", json={"weekly_hours": 1, "paused_until": "2030-01-01T00:00:00"}, headers=worker
    )
    assert naive.status_code == 422 and naive.json()["fields"] == ["body.paused_until"]
    assert client.put("/v1/workers/me/availability", json={"weekly_hours": -1}, headers=worker).status_code == 422
    far = (datetime.now(UTC) + timedelta(days=91)).isoformat()
    too_far = client.put("/v1/workers/me/availability", json={"weekly_hours": 1, "paused_until": far}, headers=worker)
    assert too_far.status_code == 422 and too_far.json()["message"] == "paused_until: more than 90 days ahead"
    lapsed = (datetime.now(UTC) - timedelta(minutes=1)).isoformat()
    back = client.put("/v1/workers/me/availability", json={"weekly_hours": 1, "paused_until": lapsed}, headers=worker)
    assert back.status_code == 200 and back.json()["paused_until"] is None


def test_a_paused_worker_sees_no_batches_and_a_claim_is_403_availability_paused(client):
    batch_id = make_batch(client)
    import_and_publish(client, batch_id, 1)
    worker = eligible(client)
    headers = {"X-Role": "worker", "X-Worker-Id": worker, "Idempotency-Key": "paused-0001"}
    assert len(client.get("/v1/batches", headers=headers).json()) == 1
    r = client.put(
        "/v1/workers/me/availability",
        json={"weekly_hours": 10, "paused_until": (datetime.now(UTC) + timedelta(days=1)).isoformat()},
        headers=headers,
    )
    assert r.status_code == 200
    assert client.get("/v1/batches", headers=headers).json() == []
    c = client.post(f"/v1/batches/{batch_id}/claims", headers=headers)
    assert c.status_code == 403 and c.json()["code"] == "availability_paused"
    client.put("/v1/workers/me/availability", json={"weekly_hours": 10, "paused_until": None}, headers=headers)
    assert client.post(f"/v1/batches/{batch_id}/claims", headers=headers).status_code == 201


def test_an_answer_schema_is_checked_like_the_payload_schema_and_shown_to_workers(client):
    body = {"name": "p", "currency": "INR", "payload_schema": SCHEMA_JSON, "answer_schema": {"type": "nope"}}
    bad = client.post("/v1/projects", json=body, headers=OPS)
    assert bad.status_code == 422 and bad.json()["message"].startswith("answer_schema: not a valid JSON Schema")
    assert client.post("/v1/projects", json={**body, "answer_schema": {"$ref": "#/x"}}, headers=OPS).status_code == 422
    p = client.post("/v1/projects", json={**body, "answer_schema": ANSWER_SCHEMA, "cert_gate": "t"}, headers=OPS)
    assert p.status_code == 201 and p.json()["answer_schema"] == ANSWER_SCHEMA
    plain = client.post(
        "/v1/projects", json={"name": "q", "currency": "INR", "payload_schema": SCHEMA_JSON}, headers=OPS
    )
    assert plain.status_code == 201 and plain.json()["answer_schema"] is None
    b = client.post(
        f"/v1/projects/{p.json()['id']}/batches", json={"title": "b", "unit_pay": "28", "unit_price": "60"}, headers=OPS
    )
    import_and_publish(client, b.json()["id"], 1)
    worker = eligible(client)
    headers = {"X-Role": "worker", "X-Worker-Id": worker, "Idempotency-Key": "schema-0001"}
    [row] = client.get("/v1/batches", headers=headers).json()
    assert row["project_name"] == "p" and row["answer_schema"] == ANSWER_SCHEMA and row["available_units"] == 1
    assert "unit_price" not in row
    c = client.post(f"/v1/batches/{b.json()['id']}/claims", headers=headers)
    assert c.status_code == 201
    mine = client.get("/v1/claims/active", headers=headers).json()
    assert mine["batch"] == {
        "id": b.json()["id"],
        "project_id": p.json()["id"],
        "project_name": "p",
        "title": "b",
        "currency": "INR",
        "unit_pay": "28.000000",
        "review_pay": "0.000000",
        "claim_ttl_minutes": 240,
        "rubric_version": "v1",
        "answer_schema": ANSWER_SCHEMA,
    }
    rejected = client.post(
        f"/v1/claims/{c.json()['id']}/submission", json={"answer": {"transcript": 1}}, headers=headers
    )
    assert rejected.status_code == 422 and rejected.json()["message"] == "answer: transcript: 1 is not of type 'string'"
    assert client.get("/v1/claims/active", headers=headers).json()["claim"]["status"] == "active"
    ok = client.post(f"/v1/claims/{c.json()['id']}/submission", json={"answer": {"transcript": "x"}}, headers=headers)
    assert ok.status_code == 201
    assert client.get("/v1/claims/active", headers=headers).json() == {"claim": None, "unit": None, "batch": None}
