"""People (names recorded once, a profile name never overwritten by a token), versioned policies, documents in
storage, the erasure lifecycle and the attention counts."""

import hashlib
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import func, select

from yantra_common.errors import Conflict, Invalid, NotFound
from yantra_common.testing import FakeStorage
from yantra_talent import service
from yantra_talent.models import OUTBOX, PERSON, Application, Erasure, Onboarding, WorkerDocument
from yantra_talent.policies_seed import POLICIES
from yantra_talent.schemas import DocumentIn, DocumentPresignIn, IdentityIn, PolicyIn, PolicySection, ProfileIn
from yantra_talent.testing import make_listing

NOW = datetime.now(UTC)
PROFILE = ProfileIn(legal_name="Asha Rani", phone="9876543210", city="Pune")


def sent(session, kind):
    rows = session.execute(select(OUTBOX).where(OUTBOX.c.type == kind).order_by(OUTBOX.c.occurred_at))
    return [r.payload for r in rows]


@pytest.fixture(autouse=True)
def fresh_cache():
    service._seen.clear()
    yield
    service._seen.clear()


# ---------- people ----------


def test_a_caller_is_recorded_once_and_announced_only_on_a_change(session, worker):
    assert service.see(session, worker, None, "worker") is False  # no name, nothing recorded
    assert service.see(session, worker, "Worker One", "worker") is True
    assert service.see(session, worker, "Worker One", "worker") is False  # unchanged: a no-op, now cached
    assert worker in service._seen
    assert service.see(session, worker, "Worker One", "worker") is False  # from the cache, no statement
    assert service.see(session, worker, "Worker Uno", "worker") is True
    session.commit()
    assert [p["name"] for p in sent(session, "talent.person.seen.v1")] == ["Worker One", "Worker Uno"]
    assert service.person(session, worker).model_dump() == {"id": worker, "name": "Worker Uno", "kind": "worker"}
    with pytest.raises(NotFound):
        service.person(session, uuid.uuid4())


def test_the_legal_name_wins_over_any_later_token_name(session, worker):
    service.see(session, worker, "w1", "worker")
    service.set_profile(session, worker, PROFILE, NOW)
    service.set_profile(session, worker, PROFILE, NOW)  # same name again: no second announcement
    assert service.see(session, worker, "w1", "worker") is False
    session.commit()
    assert service.person(session, worker).name == "Asha Rani"
    assert [p["name"] for p in sent(session, "talent.person.seen.v1")] == ["w1", "Asha Rani"]


def test_the_seen_cache_is_bounded(session, monkeypatch):
    monkeypatch.setattr(service, "SEEN_CACHE_MAX", 2)
    for _ in range(3):
        person = uuid.uuid4()
        service.see(session, person, "n", "staff")
        service.see(session, person, "n", "staff")
    assert len(service._seen) == 1


def test_ops_see_applicant_names(session, worker):
    listing = make_listing(session)
    service.set_profile(session, worker, PROFILE, NOW)
    service.apply(session, listing.id, worker, {"experience": "2"}, NOW)
    service.apply(session, listing.id, uuid.uuid4(), {"experience": "2"}, NOW)
    session.commit()
    names = {a.worker_id: a.worker_name for a in service.listing_applications(session, listing.id, None, NOW)}
    assert names[worker] == "Asha Rani" and sorted(names.values(), key=str)[0] in ("Asha Rani", None)
    assert list(names.values()).count(None) == 1


# ---------- policies ----------


def test_the_seed_is_every_policy_at_its_first_version(session):
    rows = service.current_policies(session)
    assert sorted(p.slug for p in rows) == sorted(p["slug"] for p in POLICIES)
    agreement = service.policy_out(service.current_policy(session, "contractor-agreement"))
    assert (agreement.version, agreement.revision) == ("2026-11", 1) and agreement.sections[0].paragraphs


def test_a_new_policy_version_never_edits_the_old_one(session):
    body = PolicyIn(title="Contractor agreement", summary="s", sections=[PolicySection(title="t", paragraphs=["p"])])
    v2 = service.put_policy(session, "contractor-agreement", body.model_copy(update={"label": "2027-01"}), uuid.uuid4())
    v3 = service.put_policy(session, "contractor-agreement", body, uuid.uuid4())
    session.commit()
    assert (v2.revision, v2.label, v3.revision, v3.label) == (2, "2027-01", 3, "3")
    assert service.policy_version(session, "contractor-agreement", 1).label == "2026-11"
    assert service.current_policy(session, "contractor-agreement").revision == 3
    with pytest.raises(Invalid) as e:  # a worker shown the old text cannot accept it now
        service.require_current(session, "contractor-agreement", "2026-11")
    assert e.value.code == "policy_outdated" and e.value.context["latest"] == "3"
    fresh = service.put_policy(session, "referrals", body, uuid.uuid4())
    assert fresh.revision == 1
    with pytest.raises(Invalid):
        service.put_policy(session, "Bad Slug", body, uuid.uuid4())
    with pytest.raises(NotFound):
        service.policy_version(session, "contractor-agreement", 99)
    with pytest.raises(NotFound):
        service.current_policy(session, "nope")


# ---------- documents ----------


def upload(storage: FakeStorage, worker: uuid.UUID, kind="identity_front", body=b"%PDF-1.7 hello") -> DocumentIn:
    signed = service.presign_document(
        storage, worker, DocumentPresignIn(kind=kind, content_type="application/pdf", size_bytes=len(body)), NOW
    )
    assert signed.key.startswith(f"workers/{worker}/documents/{kind}/") and signed.method == "PUT"
    assert signed.headers == {"content-type": "application/pdf"} and signed.max_bytes == len(body)
    assert storage.put_sizes[signed.key] == len(body)  # the declared size is signed: the store refuses another
    storage.put(signed.key, body, "application/pdf")
    return DocumentIn(key=signed.key, sha256=hashlib.sha256(body).hexdigest(), size_bytes=len(body))


def test_a_document_is_checked_in_storage_and_a_replacement_deletes_the_old_object(session, worker):
    storage = FakeStorage()
    first = upload(storage, worker)
    doc = service.register_document(session, storage, worker, "identity_front", first)
    session.commit()
    assert (doc.kind, doc.size_bytes, doc.content_type) == ("identity_front", 14, "application/pdf")
    second = upload(storage, worker, body=b"%PDF-1.7 again!")
    service.register_document(session, storage, worker, "identity_front", second)
    service.register_document(session, storage, worker, "identity_front", second)  # same key again: nothing deleted
    session.commit()
    assert storage.deleted == [first.key]
    assert [d.key for d in service.my_documents(session, worker)] == [second.key]
    url, expires = service.document_url(session, storage, worker, "identity_front", NOW)
    assert url.startswith("fake://") and expires > NOW
    with pytest.raises(NotFound):
        service.document_url(session, storage, worker, "address_proof", NOW)
    out = service.my_onboarding(session, worker)
    assert [d.kind for d in out.documents] == ["identity_front"] and out.erasure is None


def test_a_document_key_must_be_the_workers_own_be_there_and_be_the_size_declared(session, worker):
    storage = FakeStorage()
    theirs = upload(storage, uuid.uuid4())
    for key in (
        theirs.key,
        f"workers/{worker}/documents/address_proof/x",
        f"workers/{worker}/documents/identity_front/../x",
    ):
        with pytest.raises(Invalid) as e:
            service.register_document(
                session, storage, worker, "identity_front", theirs.model_copy(update={"key": key})
            )
        assert e.value.code == "key_not_yours"
    missing = DocumentIn(key=f"workers/{worker}/documents/identity_front/nothing", sha256="0" * 64, size_bytes=3)
    with pytest.raises(Invalid) as e:
        service.register_document(session, storage, worker, "identity_front", missing)
    assert e.value.code == "object_missing"
    mine = upload(storage, worker)
    with pytest.raises(Invalid) as e:
        service.register_document(
            session, storage, worker, "identity_front", mine.model_copy(update={"size_bytes": 99})
        )
    assert e.value.code == "size_mismatch" and mine.key in storage.deleted


# ---------- erasure ----------


def test_erasure_waits_thirty_days_unless_approved_and_erases_what_it_may(session, worker):
    storage = FakeStorage()
    orphan = f"workers/{worker}/documents/identity_back/never-registered"
    storage.put(orphan, b"x", "image/png")  # presigned and uploaded, never registered
    someone_else = f"workers/{uuid.uuid4()}/documents/identity_front/x"
    storage.put(someone_else, b"x", "image/png")
    listing = make_listing(session)
    app = Application(
        listing_id=listing.id, worker_id=worker, status="accepted", answers={"experience": "my life story"}
    )
    session.add(app)
    service.set_profile(session, worker, PROFILE, NOW)
    service.set_identity(session, worker, IdentityIn(pan="ABCDE1234F", aadhaar_last4="1234"), NOW)
    service.register_document(session, storage, worker, "identity_front", upload(storage, worker))
    row = service.request_erasure(session, worker, NOW)
    session.commit()
    assert row.status == "requested" and row.due_at == NOW + timedelta(days=30)
    assert sent(session, "worker.erasure.requested.v1") == [
        {"worker_id": str(worker), "due_at": row.due_at.isoformat()}
    ]
    with pytest.raises(Conflict) as e:
        service.request_erasure(session, worker, NOW)
    assert e.value.code == "erasure_pending"
    assert service.run_due_erasures(session, storage, NOW) == 0  # not due yet
    assert service.attention(session, NOW) == {"applications_screening": 0, "erasures_pending": 1, "erasures_due": 0}
    approved = service.approve_erasure(session, worker, uuid.uuid4(), NOW)
    assert approved.status == "approved" and approved.due_at == NOW
    assert service.attention(session, NOW)["erasures_due"] == 1
    assert [e.worker_id for e in service.list_erasures(session, "approved")] == [worker]
    assert service.run_due_erasures(session, None, NOW) == 0  # documents and no storage: waits
    assert service.run_due_erasures(session, storage, NOW) == 1
    session.commit()
    onboarding = session.get(Onboarding, worker)
    assert (onboarding.legal_name, onboarding.phone, onboarding.city, onboarding.aadhaar_last4) == (None,) * 4
    assert onboarding.pan_last4 == "234F" and onboarding.pan_hash is not None  # kept: tax records
    assert session.scalar(select(func.count()).select_from(WorkerDocument)) == 0
    assert list(storage.objects) == [someone_else] and orphan in storage.deleted
    session.refresh(app)
    assert app.answers == {} and app.status == "accepted"
    assert session.execute(select(PERSON.c.name).where(PERSON.c.id == worker)).scalar_one() is None
    assert sent(session, "talent.person.seen.v1")[-1] == {"id": str(worker), "name": None, "kind": "worker"}
    assert sent(session, "worker.erasure.completed.v1") == [{"worker_id": str(worker)}]
    assert session.get(Erasure, worker).status == "done"
    with pytest.raises(Conflict) as e:
        service.request_erasure(session, worker, NOW)
    assert e.value.code == "erasure_done"
    with pytest.raises(Conflict):
        service.approve_erasure(session, worker, uuid.uuid4(), NOW)
    with pytest.raises(NotFound):
        service.approve_erasure(session, uuid.uuid4(), uuid.uuid4(), NOW)
    assert service.my_onboarding(session, worker).erasure.status == "done"


def test_a_worker_without_documents_is_erased_without_storage(session, worker):
    service.request_erasure(session, worker, NOW - timedelta(days=31))
    assert service.run_due_erasures(session, None) == 1
    assert service.list_erasures(session, None)[0].status == "done"


def test_an_erasure_with_nothing_stored_deletes_nothing(session, worker):
    storage = FakeStorage()
    service.request_erasure(session, worker, NOW - timedelta(days=31))
    assert service.run_due_erasures(session, storage) == 1
    assert storage.deleted == []


def test_the_erasure_job_leaves_the_api_cache_alone(session, worker):
    """The job runs in the events process; the API's `_seen` cache is another process's memory. A stale entry is
    harmless: `see` never overwrites the erased `profile` row."""
    service.see(session, worker, "Token Name", "worker")
    service.set_profile_name(session, worker, "Asha Rani")
    service.see(session, worker, "Token Name", "worker")  # a confirmed no-op: cached
    assert worker in service._seen
    service.request_erasure(session, worker, NOW - timedelta(days=31))
    assert service.run_due_erasures(session, None) == 1
    assert worker in service._seen
    assert service.see(session, worker, "Token Name", "worker") is False
    service._seen.clear()
    assert service.see(session, worker, "Token Name", "worker") is False
    assert session.execute(select(PERSON.c.name).where(PERSON.c.id == worker)).scalar_one() is None
