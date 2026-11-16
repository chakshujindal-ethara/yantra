"""Stuck work, stored media, the deliverable, retention, names, holds and the client's next delivery."""

import json
import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest
from sqlalchemy import select

from yantra_common.errors import Conflict, Forbidden, NotFound
from yantra_common.events import Envelope
from yantra_common.testing import FakeStorage
from yantra_market import service
from yantra_market.consumers import on_hold_set, on_person_seen, on_verdict_accepted, on_verdict_rejected
from yantra_market.models import OUTBOX, Claim, ClientProject, DeliveryManifest, Submission, WorkBatch, WorkUnit
from yantra_market.rules import media_ref, validate_lines
from yantra_market.service import (
    build_manifest,
    claim_unit,
    import_units,
    publish_batch,
    submit,
)
from yantra_market.testing import (
    SCHEMA_JSON,
    eligible_worker,
    good_lines,
    make_batch,
    make_org,
    make_project,
    verdict_event,
)


def published(session, batch, n, lines=None):
    import_units(session, batch.id, lines or good_lines(n), dry_run=False)
    publish_batch(session, batch.id)
    session.commit()


def last_event(session):
    return session.execute(select(OUTBOX.c.type, OUTBOX.c.payload).order_by(OUTBOX.c.occurred_at.desc())).first()


def env(type_: str, data: dict) -> Envelope:
    return Envelope(uuid.uuid4(), type_, "x", datetime.now(UTC), data)


# ---------- media refs on import ----------


def test_media_ref_rules():
    assert media_ref({"text": "hi", "audio": "s3://yantra/projects/p/u/a.wav"}, "projects/p/", "yantra") == (
        "projects/p/u/a.wav",
        None,
    )
    assert media_ref({"audio": "projects/q/a.wav"}, "projects/p/", "yantra") == (
        None,
        "payload: audio: ref outside the project",
    )
    uri, problem = media_ref({"audio": "s3://other/projects/p/a.wav"}, "projects/p/", "yantra")
    assert uri is None and problem == "payload: audio: ref names another bucket"
    assert media_ref({"text": "plain"}, "projects/p/", None) == (None, None)


def test_import_keeps_the_media_key_and_refuses_a_ref_outside_the_project(session, batch):
    schema = {"type": "object", "properties": {"audio": {"type": "string"}}}
    prefix = f"projects/{batch.project_id}/"
    lines = [
        {"external_ref": "a", "payload": {"audio": f"s3://yantra/{prefix}u1/a.wav"}},
        {"external_ref": "b", "payload": {"audio": "s3://yantra/projects/elsewhere/b.wav"}},
    ]
    report, accepted = validate_lines(schema, lines, set(), prefix, "yantra")
    assert [e.reason for e in report.errors] == ["payload: audio: ref outside the project"]
    assert accepted[0].payload_uri == f"{prefix}u1/a.wav"
    project = session.get(ClientProject, batch.project_id)
    project.payload_schema = schema
    session.commit()
    import_units(session, batch.id, lines[:1], dry_run=False, bucket="yantra")
    session.commit()
    unit = session.scalars(select(WorkUnit)).one()
    assert unit.payload_uri == f"{prefix}u1/a.wav"


# ---------- the worker gives a claim back ----------


def test_worker_releases_their_claim_and_the_unit_is_available_again(session, batch):
    published(session, batch, 1)
    w = eligible_worker(session)
    c = claim_unit(session, batch.id, w, "k")
    session.commit()
    with pytest.raises(Forbidden):
        service.release_claim(session, c.id, uuid.uuid4())
    released = service.release_claim(session, c.id, w)
    session.commit()
    unit = session.get(WorkUnit, c.unit_id)
    assert released.status == "released" and released.released_by == w and released.released_at is not None
    assert unit.status == "available" and unit.current_claim_id is None
    assert last_event(session).type == "work.claim.released.v1"
    with pytest.raises(Conflict) as e:
        service.release_claim(session, c.id, w)
    assert e.value.code == "claim_not_live"
    with pytest.raises(NotFound):
        service.release_claim(session, uuid.uuid4(), w)


# ---------- stuck work ----------


def test_expired_claims_are_listed_and_released_one_by_one_signed(session, batch):
    published(session, batch, 2)
    w1, w2, admin = eligible_worker(session), eligible_worker(session), uuid.uuid4()
    c1 = claim_unit(session, batch.id, w1, "k1")
    c2 = claim_unit(session, batch.id, w2, "k2")
    session.commit()
    later = c1.expires_at + timedelta(minutes=5)
    rows = service.expired_claims(session, later)
    assert [r[0].id for r in rows] == sorted([c1.id, c2.id], key=lambda i: session.get(Claim, i).expires_at)
    assert rows[0][3].id == batch.project_id
    with pytest.raises(Conflict) as e:
        service.release_expired_claim(session, c1.id, admin, now=c1.expires_at - timedelta(minutes=1))
    assert e.value.code == "claim_not_expired"
    done = service.release_expired_claim(session, c1.id, admin, now=later)
    session.commit()
    assert done.status == "expired" and done.released_by == admin
    assert last_event(session).type == "work.claim.expired.v1"
    with pytest.raises(NotFound):
        service.release_expired_claim(session, uuid.uuid4(), admin, now=later)
    released, more = service.release_expired_claims(session, now=later, released_by=admin)
    session.commit()
    assert released == [c2.id] and not more
    history = service.released_claims(session, later - timedelta(days=1))
    assert {c.id for c, _ in history} == {c1.id, c2.id}
    assert all(c.released_by == admin for c, _ in history)
    assert service.expired_claims(session, later) == []


def test_the_expiry_job_releases_unsigned(session, batch):
    published(session, batch, 1)
    w = eligible_worker(session)
    c = claim_unit(session, batch.id, w, "k")
    session.commit()
    service.release_expired_claims(session, now=c.expires_at + timedelta(seconds=1))
    session.commit()
    session.refresh(c)
    assert c.status == "expired" and c.released_by is None and c.released_at is not None


# ---------- stored media ----------


def test_payload_uploads_presign_puts_for_a_draft_batch_only(session, batch):
    store = FakeStorage()
    out = service.payload_uploads(session, store, batch.id, [("a.wav", "audio/wav", 100), ("b.png", "image/png", 5)])
    assert [u["name"] for u in out] == ["a.wav", "b.png"]
    assert all(u["key"].startswith(f"projects/{batch.project_id}/units/") for u in out)
    assert out[0]["ref"] == f"s3://yantra/{out[0]['key']}" and out[0]["max_bytes"] == 100
    assert out[0]["headers"] == {"content-type": "audio/wav"}
    published(session, batch, 1)
    with pytest.raises(Conflict) as e:
        service.payload_uploads(session, store, batch.id, [("a.wav", "audio/wav", 1)])
    assert e.value.code == "batch_not_draft"


def test_payload_object_is_for_ops_or_the_live_claim_holder(session, batch):
    published(session, batch, 1)
    unit = session.scalars(select(WorkUnit)).one()
    unit.payload_uri = f"projects/{batch.project_id}/units/x/a.wav"
    session.commit()
    w, stranger = eligible_worker(session), uuid.uuid4()
    with pytest.raises(NotFound):
        service.payload_object(session, unit.id, w, staff=False)
    c = claim_unit(session, batch.id, w, "k")
    session.commit()
    assert service.payload_object(session, unit.id, w, staff=False) == unit.payload_uri
    with pytest.raises(NotFound):
        service.payload_object(session, unit.id, stranger, staff=False)
    with pytest.raises(NotFound):
        service.payload_object(session, unit.id, w, staff=False, now=c.expires_at + timedelta(seconds=1))
    assert service.payload_object(session, unit.id, stranger, staff=True) == unit.payload_uri
    unit.payload_uri = None
    session.commit()
    with pytest.raises(NotFound) as e:
        service.payload_object(session, unit.id, stranger, staff=True)
    assert e.value.code == "no_payload_object"
    with pytest.raises(NotFound):
        service.payload_object(session, uuid.uuid4(), stranger, staff=True)


def delivered(session, batch, n=2):
    published(session, batch, n)
    for i in range(n):
        w = eligible_worker(session)
        c = claim_unit(session, batch.id, w, f"k{i}")
        submit(session, c.id, w, {"transcript": f"t{i}"})
        session.commit()
    units = session.scalars(select(WorkUnit).order_by(WorkUnit.external_ref)).all()
    first = units[0]
    author = session.scalars(select(Submission.worker_id).where(Submission.unit_id == first.id)).one()
    on_verdict_rejected(session, verdict_event(first.id, batch.id, author, "needs_edits", "incomplete"))
    session.commit()
    w = first.assigned_worker_id
    c = claim_unit(session, batch.id, w, "again")
    submit(session, c.id, w, {"transcript": "fixed"})
    session.commit()
    for u in units:
        on_verdict_accepted(session, verdict_event(u.id, batch.id, uuid.uuid4()))
    session.commit()
    m = build_manifest(session, batch.id)
    session.commit()
    return m


def test_the_deliverable_is_written_once_and_reused(session, batch):
    m = delivered(session, batch)
    store = FakeStorage()
    first = service.deliverable(session, store, m.id)
    session.commit()
    key = f"projects/{batch.project_id}/deliveries/{m.id}/units.jsonl"
    assert first.deliverable_key == key and first.deliverable_lines == 2
    body = store.objects[key][0]
    lines = [json.loads(line) for line in body.decode().splitlines()]
    assert [line["external_ref"] for line in lines] == ["u0", "u1"]
    assert lines[0]["answer"] == {"transcript": "fixed"}
    assert lines[0]["rework"][0]["reason_code"] == "incomplete" and lines[1]["rework"] == []
    assert len(lines[0]["payload_sha256"]) == 64
    head = json.loads(store.objects[key.replace("units.jsonl", "manifest.json")][0])
    assert head["line_count"] == 2 and head["lines_sha256"] == first.deliverable_sha256
    store.objects.clear()
    again = service.deliverable(session, store, m.id)
    assert again.deliverable_key == key and store.objects == {}


# ---------- retention ----------


def test_retention_purges_payloads_answers_and_objects_after_the_window(session, batch):
    m = delivered(session, batch)
    store = FakeStorage()
    service.deliverable(session, store, m.id)
    unit = session.scalars(select(WorkUnit)).first()
    unit.payload_uri = f"projects/{batch.project_id}/units/x/a.wav"
    session.commit()
    assert service.purge_due_batches(session, store, now=m.created_at + timedelta(days=179)) == 0
    assert service.purge_due_batches(session, None, now=m.created_at + timedelta(days=181)) == 0
    assert service.purge_due_batches(session, store, now=m.created_at + timedelta(days=181)) == 1
    session.commit()
    assert all(u.payload == {} and u.payload_uri is None for u in session.scalars(select(WorkUnit)))
    assert all(s.answer == {} for s in session.scalars(select(Submission)))
    manifest = session.get(DeliveryManifest, m.id)
    assert manifest.units == [] and manifest.accepted_units == 2 and manifest.digest == m.digest
    assert session.get(WorkBatch, batch.id).purged_at is not None
    assert len(store.deleted) == 3
    kind, payload = last_event(session)
    assert kind == "work.batch.purged.v1" and payload["unit_count"] == 2
    assert service.purge_due_batches(session, store, now=m.created_at + timedelta(days=400)) == 0


def test_a_cancelled_batch_is_purged_from_its_creation_and_the_limit_holds(session, project):
    old = datetime.now(UTC) - timedelta(days=400)
    for i in range(3):
        b = make_batch(session, project, title=f"b{i}", status="cancelled")
        b.created_at = old
    project.retention_days = 30
    session.commit()
    assert service.purge_due_batches(session, None, limit=2) == 2
    session.commit()
    assert service.purge_due_batches(session, None) == 1


# ---------- names, holds, the bench ----------


def test_names_holds_and_the_bench_summary(session):
    w1, w2 = eligible_worker(session), eligible_worker(session)
    on_person_seen(session, env("talent.person.seen.v1", {"id": str(w1), "name": "Asha Rao", "kind": "worker"}))
    until = datetime.now(UTC) + timedelta(days=3)
    on_hold_set(
        session,
        env(
            "payout.hold.set.v1",
            {"worker_id": str(w2), "reason": "integrity", "until": until.isoformat(), "source": "manual"},
        ),
    )
    session.commit()
    assert service.names_of(session, [w1, w2, None]) == {w1: "Asha Rao"}
    assert service.names_of(session, []) == {}
    assert service.holds_of(session, [w1, w2], datetime.now(UTC)) == {w2: until}
    assert service.holds_of(session, [], datetime.now(UTC)) == {}
    summary = service.workers_summary(session)
    assert summary["eligible"] == 2 and summary["total"] == 2 and summary["held"] == 1 and summary["paused"] == 0
    on_hold_set(
        session, env("payout.hold.set.v1", {"worker_id": str(w2), "reason": None, "until": None, "source": "manual"})
    )
    session.commit()
    assert service.workers_summary(session)["held"] == 0


def test_people_are_scoped_for_a_client(session):
    client, colleague, stranger = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    org = make_org(session, members=[client, colleague])
    for i, n in ((client, "C"), (colleague, "Col"), (stranger, "S")):
        on_person_seen(session, env("talent.person.seen.v1", {"id": str(i), "name": n, "kind": "client"}))
    session.commit()
    everyone = service.people(session, [client, colleague, stranger], None, None)
    assert set(everyone) == {client, colleague, stranger}
    scoped = service.people(session, [client, colleague, stranger], frozenset({org.id}), client)
    assert set(scoped) == {client, colleague}
    assert service.people(session, [stranger], frozenset(), client) == {}


# ---------- the client's next delivery, batch edits, feedback, closing ----------


def test_next_delivery_is_the_earliest_open_dated_batch_in_scope(session, project):
    org = make_org(session)
    project.client_org_id = org.id
    soon, later = datetime.now(UTC) + timedelta(days=2), datetime.now(UTC) + timedelta(days=9)
    make_batch(session, project, title="later", due_at=later)
    make_batch(session, project, title="soon", due_at=soon)
    make_batch(session, project, title="done", due_at=soon - timedelta(days=1), status="completed")
    session.commit()
    found = service.next_delivery(session, frozenset({org.id}))
    assert found is not None and found[0].title == "soon" and found[2].total == 0
    assert service.next_delivery(session, frozenset()) is None
    assert service.next_delivery(session, None) is not None


def test_patch_batch_and_feedback_and_closing(session, project, batch):
    due = datetime.now(UTC) + timedelta(days=5)
    assert service.patch_batch(session, batch.id, {"title": "Renamed", "due_at": due}).due_at == due
    batch.status = "cancelled"
    session.commit()
    with pytest.raises(Conflict):
        service.patch_batch(session, batch.id, {"title": "x"})
    staff = uuid.uuid4()
    row = service.add_feedback(session, project, staff, "We fixed the glossary.", author_kind="staff")
    assert row.author_kind == "staff"
    closed = service.patch_project(session, project.id, {"status": "closed"})
    assert closed.closed_at is not None
    assert service.patch_project(session, project.id, {"status": "active"}).closed_at is None


def test_attention_counts(session, project):
    project.margin_floor = Decimal("0.5")
    make_batch(session, project, title="thin")  # 60 price, 28 pay, 6 review: margin 0.4333
    make_batch(session, project, title="fat", unit_pay=Decimal("10"), review_pay=Decimal("0"))
    session.commit()
    p2 = make_project(session, payload_schema=SCHEMA_JSON, margin_floor=None)
    published(session, make_batch(session, p2), 1)
    w = eligible_worker(session)
    c = claim_unit(session, session.scalars(select(WorkBatch).where(WorkBatch.project_id == p2.id)).one().id, w, "k")
    session.commit()
    assert service.attention(session, now=c.expires_at + timedelta(seconds=1)) == {
        "expired_claims": 1,
        "batches_under_floor": 1,
        "stuck_assigned_units": 0,
    }
