"""Over HTTP: stored media (uploads, import refs, the payload link), the deliverable, stuck work in market and
quality, a worker releasing a claim, names, the bench summary, the ops feedback answer, batch edits, the client's
next delivery, reviewers and reasons, flags and the attention list."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from yantra_common.events import Envelope
from yantra_common.testing import FakeStorage
from yantra_market.consumers import on_hold_set, on_person_seen, on_verdict_accepted
from yantra_market.models import Claim, WorkUnit
from yantra_market.testing import SCHEMA_JSON, good_lines, verdict_event
from yantra_quality import service as quality_service
from yantra_quality.models import ReviewTask, RubricFlag
from yantra_quality.testing import open_task, submitted_envelope
from yantra_work.app import create_app

OPS_ID = str(uuid.uuid4())
OPS = {"X-Role": "ops", "X-Worker-Id": OPS_ID}
ADMIN = {"X-Role": "admin", "X-Worker-Id": str(uuid.uuid4())}
AUDIO_SCHEMA = {"type": "object", "properties": {"audio": {"type": "string"}, "text": {"type": "string"}}}


@pytest.fixture
def store():
    return FakeStorage()


@pytest.fixture
def client(factory, store):
    app = create_app(factory, rate_limit_per_minute=1000, max_body_bytes=200_000, storage=store)
    return TestClient(app, raise_server_exceptions=False)


@pytest.fixture
def bare(factory):
    return TestClient(
        create_app(factory, rate_limit_per_minute=1000, max_body_bytes=200_000), raise_server_exceptions=False
    )


def project(client, schema=AUDIO_SCHEMA, **fields) -> str:
    body = {"name": "p", "currency": "INR", "payload_schema": schema, "cert_gate": "t", **fields}
    r = client.post("/v1/projects", json=body, headers=OPS)
    assert r.status_code == 201, r.text
    return r.json()["id"]


def batch(client, project_id, **fields) -> str:
    r = client.post(
        f"/v1/projects/{project_id}/batches",
        json={"title": "b", "unit_pay": "28", "unit_price": "60", **fields},
        headers=OPS,
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


def eligible(client) -> str:
    w = str(uuid.uuid4())
    assert (
        client.put(f"/v1/workers/{w}", json={"status": "eligible", "cert_gates": ["t"]}, headers=OPS).status_code == 200
    )
    return w


def worker(w: str, key: str = "") -> dict:
    return {"X-Role": "worker", "X-Worker-Id": w, "Idempotency-Key": key or f"k-{w}"}


def publish(client, b, lines):
    r = client.post(f"/v1/batches/{b}/units/import", json={"lines": lines}, params={"dry_run": "false"}, headers=OPS)
    assert r.status_code == 200, r.text
    assert client.post(f"/v1/batches/{b}/publish", json={}, headers=OPS).status_code == 200


def env(type_, data):
    return Envelope(uuid.uuid4(), type_, "x", datetime.now(UTC), data)


# ---------- stored media ----------


def test_upload_import_and_the_payload_link(client, store, factory):
    p = project(client)
    b = batch(client, p)
    r = client.post(
        f"/v1/batches/{b}/payload-uploads",
        json={"files": [{"name": "clip-01.wav", "content_type": "audio/wav", "size_bytes": 1000}]},
        headers=OPS,
    )
    assert r.status_code == 200, r.text
    up = r.json()["uploads"][0]
    assert up["key"].startswith(f"projects/{p}/units/") and up["ref"] == f"s3://yantra/{up['key']}"
    assert up["headers"] == {"content-type": "audio/wav"} and up["max_bytes"] == 1000
    bad = client.post(
        f"/v1/batches/{b}/payload-uploads",
        json={"files": [{"name": "../x", "content_type": "audio/wav", "size_bytes": 1}]},
        headers=OPS,
    )
    assert bad.status_code == 422
    wrong_type = client.post(
        f"/v1/batches/{b}/payload-uploads",
        json={"files": [{"name": "x.exe", "content_type": "application/x-msdownload", "size_bytes": 1}]},
        headers=OPS,
    )
    assert wrong_type.status_code == 422
    dry = client.post(
        f"/v1/batches/{b}/units/import",
        json={"lines": [{"external_ref": "x", "payload": {"audio": "s3://yantra/projects/other/a.wav"}}]},
        headers=OPS,
    )
    assert dry.json()["errors"][0]["reason"] == "payload: audio: ref outside the project"
    publish(client, b, [{"external_ref": "a", "payload": {"audio": up["ref"], "text": "hi"}}])
    w, stranger = eligible(client), eligible(client)
    unit_id = client.post(f"/v1/batches/{b}/claims", headers=worker(w)).json()["unit_id"]
    link = client.get(f"/v1/units/{unit_id}/payload-url", headers=worker(w))
    assert link.status_code == 200 and link.json()["url"] == f"fake://yantra/{up['key']}?method=GET"
    assert client.get(f"/v1/units/{unit_id}/payload-url", headers=worker(stranger)).status_code == 404
    assert client.get(f"/v1/units/{unit_id}/payload-url", headers=OPS).status_code == 200
    with factory() as s:
        s.get(WorkUnit, uuid.UUID(unit_id)).payload_uri = None
        s.commit()
    gone = client.get(f"/v1/units/{unit_id}/payload-url", headers=OPS)
    assert gone.status_code == 404 and gone.json()["code"] == "no_payload_object"
    published = client.post(
        f"/v1/batches/{b}/payload-uploads",
        json={"files": [{"name": "a.wav", "content_type": "audio/wav", "size_bytes": 1}]},
        headers=OPS,
    )
    assert published.status_code == 409 and published.json()["code"] == "batch_not_draft"


def test_routes_that_need_storage_answer_503_without_it(bare):
    p = project(bare)
    b = batch(bare, p)
    r = bare.post(
        f"/v1/batches/{b}/payload-uploads",
        json={"files": [{"name": "a.wav", "content_type": "audio/wav", "size_bytes": 1}]},
        headers=OPS,
    )
    assert r.status_code == 503 and r.json()["code"] == "storage_unconfigured"
    plain = bare.post(
        f"/v1/batches/{b}/units/import",
        json={"lines": [{"external_ref": "a", "payload": {"audio": f"projects/{p}/units/x/a.wav"}}]},
        headers=OPS,
    )
    assert plain.status_code == 200 and plain.json()["errors"] == []


def deliver(client, factory, n=2):
    p = project(client, schema=SCHEMA_JSON)
    b = batch(client, p)
    publish(client, b, good_lines(n))
    for _ in range(n):
        w = eligible(client)
        c = client.post(f"/v1/batches/{b}/claims", headers=worker(w)).json()
        assert (
            client.post(f"/v1/claims/{c['id']}/submission", json={"answer": {"t": 1}}, headers=worker(w)).status_code
            == 201
        )
    with factory() as s:
        for u in s.scalars(select(WorkUnit).where(WorkUnit.batch_id == uuid.UUID(b))):
            on_verdict_accepted(s, verdict_event(u.id, u.batch_id, uuid.uuid4()))
        s.commit()
    return p, b


def test_the_deliverable_for_ops_and_the_client(client, store, factory):
    client_user = str(uuid.uuid4())
    p, b = deliver(client, factory)
    org = client.post("/v1/client-orgs", json={"name": "Acme"}, headers=OPS).json()["id"]
    client.put(f"/v1/client-orgs/{org}/members/{client_user}", headers=OPS)
    client.patch(f"/v1/projects/{p}", json={"client_org_id": org}, headers=OPS)
    cl = {"X-Role": "client", "X-Worker-Id": client_user}
    assert client.get(f"/v1/client/batches/{b}/deliverable", headers=cl).status_code == 404  # no manifest yet
    d = client.get(f"/v1/batches/{b}/deliverable", headers=OPS)
    assert d.status_code == 200, d.text
    body = d.json()
    assert body["jsonl"]["line_count"] == 2 and len(body["jsonl"]["sha256"]) == 64
    assert body["jsonl"]["url"].endswith("units.jsonl?method=GET") and body["manifest"]["url"].endswith(
        "manifest.json?method=GET"
    )
    assert len(store.objects) == 2
    again = client.get(f"/v1/client/batches/{b}/deliverable", headers=cl)
    assert again.status_code == 200 and again.json()["jsonl"]["sha256"] == body["jsonl"]["sha256"]
    other = {"X-Role": "client", "X-Worker-Id": str(uuid.uuid4())}
    assert client.get(f"/v1/client/batches/{b}/deliverable", headers=other).status_code == 404


def test_the_deliverable_waits_for_the_gate(client):
    p = project(client, schema=SCHEMA_JSON)
    b = batch(client, p)
    publish(client, b, good_lines(1))
    held = client.get(f"/v1/batches/{b}/deliverable", headers=OPS)
    assert held.status_code == 409 and held.json()["code"] == "batch_held"


# ---------- stuck work and claim release ----------


def test_stuck_claims_listed_released_and_shown_in_history(client, factory):
    p = project(client, schema=SCHEMA_JSON)
    b = batch(client, p)
    publish(client, b, good_lines(3))
    workers = [eligible(client) for _ in range(3)]
    claims = [client.post(f"/v1/batches/{b}/claims", headers=worker(w)).json() for w in workers]
    with factory() as s:
        for c in claims[:2]:
            s.get(Claim, uuid.UUID(c["id"])).expires_at = datetime.now(UTC) - timedelta(minutes=10)
        s.commit()
        on_person_seen(s, env("talent.person.seen.v1", {"id": workers[0], "name": "Asha", "kind": "worker"}))
        s.commit()
    assert client.get("/v1/claims/expired", headers=worker(workers[2])).status_code == 403
    rows = client.get("/v1/claims/expired", headers=ADMIN).json()
    assert len(rows) == 2 and rows[0]["minutes_overdue"] >= 9 and rows[0]["project_name"] == "p"
    assert {r["worker_name"] for r in rows} == {"Asha", None}
    not_yet = client.post(f"/v1/claims/{claims[2]['id']}/release-expired", headers=ADMIN)
    assert not_yet.status_code == 409 and not_yet.json()["code"] == "claim_not_expired"
    one = client.post(f"/v1/claims/{claims[0]['id']}/release-expired", headers=ADMIN)
    assert one.status_code == 200 and one.json()["status"] == "expired"
    all_ = client.post("/v1/claims/release-expired", headers=OPS)
    assert all_.json() == {"released": 1, "more": False}
    back = client.post(f"/v1/claims/{claims[2]['id']}/release", headers=worker(workers[2]))
    assert back.status_code == 200 and back.json()["status"] == "released"
    again = client.post(f"/v1/claims/{claims[2]['id']}/release", headers=worker(workers[2]))
    assert again.status_code == 409 and again.json()["code"] == "claim_not_live"
    history = client.get("/v1/claims/released", params={"days": 1}, headers=ADMIN).json()
    by = {h["claim_id"]: h for h in history}
    assert by[claims[0]["id"]]["released_by"] == ADMIN["X-Worker-Id"]
    assert by[claims[1]["id"]]["released_by"] == OPS_ID and by[claims[2]["id"]]["status"] == "released"
    assert by[claims[0]["id"]]["worker_name"] == "Asha"


def test_stuck_reviews_and_reviewer_release_over_http(client, factory):
    reviewer = str(uuid.uuid4())
    rv = {"X-Role": "reviewer", "X-Worker-Id": reviewer}
    with factory() as s:
        open_task(s, uuid.uuid4(), uuid.uuid4())
        open_task(s, uuid.uuid4(), uuid.uuid4())
    t = client.post("/v1/quality/reviews/claim", headers=rv).json()
    assert client.post(f"/v1/quality/reviews/{t['id']}/release", headers=rv).json()["status"] == "pending"
    t = client.post("/v1/quality/reviews/claim", headers=rv).json()
    with factory() as s:
        s.get(ReviewTask, uuid.UUID(t["id"])).claim_expires_at = datetime.now(UTC) - timedelta(minutes=5)
        s.commit()
    late = client.post(f"/v1/quality/tasks/{t['id']}/review", json={"verdict": "accept"}, headers=rv)
    assert late.status_code == 409 and late.json()["code"] == "review_expired"
    t = client.post("/v1/quality/reviews/claim", headers=rv).json()
    with factory() as s:
        s.get(ReviewTask, uuid.UUID(t["id"])).claim_expires_at = datetime.now(UTC) - timedelta(minutes=5)
        s.commit()
    rows = client.get("/v1/quality/reviews/expired", headers=ADMIN).json()
    assert (
        [r["task_id"] for r in rows] == [t["id"]] and rows[0]["kind"] == "review" and rows[0]["holder_id"] == reviewer
    )
    assert client.post(f"/v1/quality/reviews/{t['id']}/release-expired", headers=ADMIN).json()["status"] == "pending"
    assert client.post("/v1/quality/reviews/release-expired", headers=ADMIN).json() == {"released": 0}
    history = client.get("/v1/quality/reviews/released", headers=ADMIN).json()
    assert {h["reason"] for h in history} == {"holder", "expired"}
    assert client.get("/v1/quality/reviews/expired", headers=rv).status_code == 403


# ---------- quality: who may review, reasons, flags, the media link ----------


def test_reviewer_clearance_reasons_and_flags(client, factory):
    reviewer = str(uuid.uuid4())
    rv = {"X-Role": "reviewer", "X-Worker-Id": reviewer}
    with factory() as s:
        e = submitted_envelope(uuid.uuid4(), uuid.uuid4())
        e.data["sensitive"] = True
        quality_service.on_unit_submitted(s, e)
        s.commit()
    blocked = client.post("/v1/quality/reviews/claim", headers=rv)
    assert blocked.status_code == 404 and blocked.json()["waiting_for_clearance"] == 1
    assert (
        client.post("/v1/quality/reviews/claim", headers={"X-Role": "worker", "X-Worker-Id": reviewer}).status_code
        == 403
    )
    cleared = client.put(f"/v1/quality/reviewers/{reviewer}", json={"sensitive_cleared": True}, headers=OPS)
    assert cleared.status_code == 200 and cleared.json()["sensitive_cleared"] and cleared.json()["gates"] == []
    assert client.get(f"/v1/quality/reviewers/{reviewer}", headers=OPS).json()["sensitive_cleared"]
    nobody = client.get(f"/v1/quality/reviewers/{uuid.uuid4()}", headers=OPS).json()
    assert nobody["sensitive_cleared"] is False and nobody["updated_at"] is None
    assert client.post("/v1/quality/reviews/claim", headers=rv).status_code == 201
    reasons = client.get("/v1/quality/reasons", headers={"X-Role": "client"}).json()
    assert reasons[0]["code"] == "guideline_miss" and len(reasons) == 6
    bad = client.put("/v1/quality/reasons/Bad Code", json={"label": "x", "applies_to": ["reject"]}, headers=OPS)
    assert bad.status_code == 422
    put = client.put(
        "/v1/quality/reasons/glossary_missing",
        json={"label": "Glossary missing", "billable": True, "applies_to": ["reject"], "sort": 50, "active": False},
        headers=OPS,
    )
    assert put.status_code == 200 and put.json()["active"] is False
    assert len(client.get("/v1/quality/reasons", params={"all": "true"}, headers=OPS).json()) == 7
    with factory() as s:
        task = s.scalars(select(ReviewTask)).first()
        s.add(
            RubricFlag(
                task_id=task.id,
                batch_id=task.batch_id,
                reviewer_id=uuid.uuid4(),
                note="?",
                created_at=datetime.now(UTC) - timedelta(days=3),
            )
        )
        s.commit()
        from yantra_quality.models import Reason

        s.query(Reason).filter(Reason.code == "glossary_missing").delete()
        s.commit()
    flags = client.get("/v1/quality/flags", params={"overdue": "true"}, headers=OPS).json()
    assert len(flags) == 1 and flags[0]["overdue"] is True
    answered = client.post(
        f"/v1/quality/flags/{flags[0]['id']}/answer", json={"answer": "use the glossary"}, headers=OPS
    )
    assert answered.json()["overdue"] is False
    stats = client.get("/v1/quality/stats", headers=OPS).json()
    assert stats["flags_open"] == 0 and stats["flags_overdue"] == 0


def test_the_review_media_link(client, factory, store):
    reviewer = str(uuid.uuid4())
    rv = {"X-Role": "reviewer", "X-Worker-Id": reviewer}
    with factory() as s:
        e = submitted_envelope(uuid.uuid4(), uuid.uuid4())
        e.data["payload"] = {"audio": "s3://yantra/projects/p/units/u/a.wav"}
        quality_service.on_unit_submitted(s, e)
        s.commit()
    t = client.post("/v1/quality/reviews/claim", headers=rv).json()
    link = client.get(f"/v1/quality/tasks/{t['id']}/payload-url", headers=rv)
    assert link.status_code == 200 and link.json()["url"] == "fake://yantra/projects/p/units/u/a.wav?method=GET"
    assert (
        client.get(
            f"/v1/quality/tasks/{t['id']}/payload-url", headers={**rv, "X-Worker-Id": str(uuid.uuid4())}
        ).status_code
        == 404
    )
    with factory() as s:
        s.get(ReviewTask, uuid.UUID(t["id"])).payload = {"text": "no media"}
        s.commit()
    none = client.get(f"/v1/quality/tasks/{t['id']}/payload-url", headers=rv)
    assert none.status_code == 404 and none.json()["code"] == "no_payload_object"


# ---------- names, the bench, feedback, batch edits, the next delivery, attention ----------


def test_people_bench_feedback_batches_and_the_next_delivery(client, factory):
    w = eligible(client)
    client_user, colleague = str(uuid.uuid4()), str(uuid.uuid4())
    with factory() as s:
        for i, n, k in (
            (w, "Asha", "worker"),
            (client_user, "Cleo", "client"),
            (colleague, "Col", "client"),
            (OPS_ID, "Ops One", "staff"),
        ):
            on_person_seen(s, env("talent.person.seen.v1", {"id": i, "name": n, "kind": k}))
        on_hold_set(
            s,
            env(
                "payout.hold.set.v1",
                {
                    "worker_id": w,
                    "reason": "integrity",
                    "until": (datetime.now(UTC) + timedelta(days=2)).isoformat(),
                    "source": "anomaly",
                },
            ),
        )
        s.commit()
    rows = client.get("/v1/workers", headers=OPS).json()["items"]
    me = next(r for r in rows if r["id"] == w)
    assert me["name"] == "Asha" and me["onboarded"] and me["held"] and me["hold_until"] is not None
    assert client.get(f"/v1/workers/{w}", headers=OPS).json()["name"] == "Asha"
    summary = client.get("/v1/workers/summary", headers=OPS).json()
    assert summary["eligible"] == 1 and summary["held"] == 1 and summary["total"] == 1
    staff = client.get(
        "/v1/people", params={"ids": f"{w},{client_user},{uuid.uuid4()}"}, headers={"X-Role": "finance"}
    ).json()
    assert staff == {w: {"name": "Asha", "kind": "worker"}, client_user: {"name": "Cleo", "kind": "client"}}
    org = client.post("/v1/client-orgs", json={"name": "Acme"}, headers=OPS).json()["id"]
    for m in (client_user, colleague):
        client.put(f"/v1/client-orgs/{org}/members/{m}", headers=OPS)
    cl = {"X-Role": "client", "X-Worker-Id": client_user}
    scoped = client.get("/v1/people", params={"ids": f"{w},{colleague}"}, headers=cl).json()
    assert scoped == {colleague: {"name": "Col", "kind": "client"}}
    assert (
        client.get("/v1/people", params={"ids": w}, headers={"X-Role": "worker", "X-Worker-Id": w}).status_code == 403
    )
    assert client.get("/v1/people", params={"ids": "nope"}, headers=OPS).status_code == 422
    many = ",".join(str(uuid.uuid4()) for _ in range(201))
    assert client.get("/v1/people", params={"ids": many}, headers=OPS).status_code == 422
    p = project(client, schema=SCHEMA_JSON, retention_days=30)
    client.patch(f"/v1/projects/{p}", json={"client_org_id": org}, headers=OPS)
    due = (datetime.now(UTC) + timedelta(days=4)).isoformat()
    b = batch(client, p, due_at=due)
    patched = client.patch(f"/v1/batches/{b}", json={"title": "Week 46"}, headers=OPS)
    assert patched.status_code == 200 and patched.json()["title"] == "Week 46" and patched.json()["due_at"] is not None
    assert client.patch(f"/v1/batches/{b}", json={"nope": 1}, headers=OPS).status_code == 422
    overview = client.get("/v1/client/overview", headers=cl).json()
    assert overview["next_delivery"]["title"] == "Week 46" and overview["next_delivery"]["project_name"] == "p"
    note = client.post(f"/v1/client/projects/{p}/feedback", json={"body": "Glossary changed"}, headers=cl).json()
    assert note["author_kind"] == "client" and note["author_name"] == "Cleo"
    reply = client.post(f"/v1/projects/{p}/feedback", json={"body": "Updated the rubric"}, headers=OPS).json()
    assert reply["author_kind"] == "staff" and reply["author_name"] == "Ops One"
    thread = client.get(f"/v1/client/projects/{p}", headers=cl).json()["feedback"]
    assert [f["author_kind"] for f in thread] == ["client", "staff"]
    detail = client.get(f"/v1/projects/{p}", headers=OPS).json()
    assert detail["retention_days"] == 30 and detail["feedback"][1]["author_name"] == "Ops One"
    assert detail["batches"][0]["due_at"] is not None
    closed = client.patch(f"/v1/projects/{p}", json={"status": "closed", "retention_days": 60}, headers=OPS).json()
    assert closed["closed_at"] is not None and closed["retention_days"] == 60
    assert client.get(f"/v1/client/projects/{p}", headers=cl).json()["batches"][0]["due_at"] is not None


def test_attention_composes_every_module(client, factory):
    with factory() as s:
        open_task(s, uuid.uuid4(), uuid.uuid4())
    r = client.get("/v1/attention", headers=OPS)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["review_backlog"] == 1 and body["expired_claims"] == 0 and "tickets_open" in body
    assert "applications_screening" in body
    assert {"market", "talent", "assess", "quality", "notify"} <= set(body["dead_letters"])
    assert (
        client.get("/v1/attention", headers={"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4())}).status_code == 403
    )
