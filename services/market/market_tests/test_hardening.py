"""Hand-set gates replace the hand-set set, nobody sets their own, retention never deletes media another batch
uses and never rebuilds a purged deliverable, one bad batch never stalls the purge, ops unassign a stuck rework unit,
consent withdrawal stops claims, and the small contract codes."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from pydantic import ValidationError
from sqlalchemy import select

from yantra_common.errors import Conflict, Forbidden, NotFound
from yantra_common.events import Envelope
from yantra_common.storage import StorageUnavailable
from yantra_common.testing import FakeStorage
from yantra_market import service
from yantra_market.consumers import on_assess_certified, on_consent_given, on_consent_withdrawn, on_verdict_rejected
from yantra_market.models import OUTBOX, DeliveryManifest, WorkBatch, WorkerProfile, WorkUnit
from yantra_market.schemas import UploadFileIn
from yantra_market.service import build_manifest, claim_unit, import_units, publish_batch, submit
from yantra_market.testing import eligible_worker, good_lines, make_batch, verdict_event


def env(type_: str, data: dict, at: datetime | None = None) -> Envelope:
    return Envelope(uuid.uuid4(), type_, f"worker/{data.get('worker_id')}", at or datetime.now(UTC), data)


def published(session, batch, n, lines=None):
    import_units(session, batch.id, lines or good_lines(n), dry_run=False)
    publish_batch(session, batch.id)
    session.commit()


def gate_events(session):
    rows = session.execute(
        select(OUTBOX.c.payload).where(OUTBOX.c.type == "worker.gates.set.v1").order_by(OUTBOX.c.occurred_at)
    )
    return [p for (p,) in rows]


# ---------- 3, 4: hand-set gates ----------


def test_a_hand_set_replaces_the_hand_set_gates_and_keeps_earned_ones_in_order(session):
    w = uuid.uuid4()
    on_assess_certified(
        session, env("assess.certified.v1", {"worker_id": str(w), "gate": "earned", "paper_id": str(w), "score": "1"})
    )
    session.commit()
    service.set_worker_by_hand(session, w, "eligible", 7, ["a", "b", "earned"], caller=None)
    session.commit()
    assert session.get(WorkerProfile, w).cert_gates == ["a", "b", "earned"]
    profile = service.set_worker_by_hand(session, w, "active", 7, ["b"], caller=uuid.uuid4())
    session.commit()
    assert (profile.cert_gates, profile.ops_gates, profile.status) == (["b", "earned"], ["b"], "active")
    service.set_worker_by_hand(session, w, "active", None, None, caller=None)  # no gates sent: gates stay
    session.commit()
    assert session.get(WorkerProfile, w).cert_gates == ["b", "earned"]
    assert [(e["gates"], e["seq"]) for e in gate_events(session)] == [(["a", "b", "earned"], 1), (["b"], 2)]
    fresh = service.set_worker_by_hand(session, uuid.uuid4(), "eligible", None, None, caller=None)
    assert fresh.cert_gates == [] and fresh.status == "eligible"


def test_nobody_sets_their_own_worker_record(session):
    me = uuid.uuid4()
    with pytest.raises(Forbidden) as e:
        service.set_worker_by_hand(session, me, "eligible", None, ["a"], caller=me)
    assert e.value.code == "self_action"


# ---------- 7, 8, 9: retention ----------


def delivered(session, batch, n=1):
    published(session, batch, n)
    for i in range(n):
        w = eligible_worker(session)
        c = claim_unit(session, batch.id, w, f"k{batch.id}{i}")
        submit(session, c.id, w, {"transcript": f"t{i}"})
        session.commit()
    for u in session.scalars(select(WorkUnit).where(WorkUnit.batch_id == batch.id)):
        u.status = "accepted"
    session.commit()
    m = build_manifest(session, batch.id)
    session.commit()
    return m


def test_the_purge_keeps_media_another_live_batch_still_uses(session, project):
    shared = f"projects/{project.id}/units/x/shared.wav"
    own = f"projects/{project.id}/units/y/own.wav"
    old, live = make_batch(session, project, title="old"), make_batch(session, project, title="live")
    m = delivered(session, old)
    delivered(session, live)
    old_unit = session.scalars(select(WorkUnit).where(WorkUnit.batch_id == old.id)).one()
    live_unit = session.scalars(select(WorkUnit).where(WorkUnit.batch_id == live.id)).one()
    old_unit.payload_uri, live_unit.payload_uri = shared, shared
    session.commit()
    store = FakeStorage()
    later = m.created_at + timedelta(days=181)
    live_m = session.scalars(select(DeliveryManifest).where(DeliveryManifest.batch_id == live.id)).one()
    live_m.created_at = later  # the live batch was delivered later: not due
    session.commit()
    assert service.purge_due_batches(session, store, now=later) == 1
    assert shared not in store.deleted
    old_unit2 = make_batch(session, project, title="third")
    m3 = delivered(session, old_unit2)
    u3 = session.scalars(select(WorkUnit).where(WorkUnit.batch_id == old_unit2.id)).one()
    u3.payload_uri = own
    session.commit()
    assert service.purge_due_batches(session, store, now=m3.created_at + timedelta(days=181)) == 1
    assert own in store.deleted and shared not in store.deleted


def test_without_storage_a_batch_whose_media_are_all_shared_still_purges(session, project):
    key = f"projects/{project.id}/units/x/shared.wav"
    a, b = make_batch(session, project, title="a"), make_batch(session, project, title="b")
    m = delivered(session, a)
    delivered(session, b)
    for u in session.scalars(select(WorkUnit)):
        u.payload_uri = key
    session.scalars(select(DeliveryManifest).where(DeliveryManifest.batch_id == b.id)).one().created_at = (
        m.created_at + timedelta(days=365)
    )
    session.commit()
    assert service.purge_due_batches(session, None, now=m.created_at + timedelta(days=181)) == 1


def test_a_purged_batch_never_gets_an_empty_deliverable(session, batch):
    m = delivered(session, batch)
    service.purge_due_batches(session, None, now=m.created_at + timedelta(days=181))
    session.commit()
    with pytest.raises(service.BatchPurged) as e:
        service.deliverable(session, FakeStorage(), m.id)
    assert (e.value.status, e.value.code) == (410, "batch_purged")


class FlakyStore(FakeStorage):
    def __init__(self, bad: set[str]) -> None:
        super().__init__()
        self.bad = bad

    def delete(self, keys):
        if self.bad & set(keys):
            raise StorageUnavailable("object storage refused the delete", bucket=self.bucket)
        return super().delete(keys)


def test_one_failing_batch_never_stalls_the_others_and_each_commits_alone(session, project, caplog):
    batches = [make_batch(session, project, title=f"b{i}") for i in range(3)]
    manifests = [delivered(session, b) for b in batches]
    for i, b in enumerate(batches):
        u = session.scalars(select(WorkUnit).where(WorkUnit.batch_id == b.id)).one()
        u.payload_uri = f"projects/{project.id}/units/{i}/a.wav"
    session.commit()
    store = FlakyStore({f"projects/{project.id}/units/0/a.wav"})
    now = max(m.created_at for m in manifests) + timedelta(days=181)
    with caplog.at_level("ERROR"):
        assert service.purge_due_batches(session, store, now=now) == 2
    assert f"batch_id={batches[0].id}" in caplog.text and "a.wav" not in caplog.text
    session.rollback()  # nothing pending: each purged batch was committed on its own
    purged = {b.id for b in session.scalars(select(WorkBatch).where(WorkBatch.purged_at.is_not(None)))}
    assert purged == {batches[1].id, batches[2].id}
    store.bad.clear()
    assert service.purge_due_batches(session, store, now=now) == 1  # the next run picks the failed one up


def test_the_purge_runs_past_the_old_daily_cap(session, project):
    old = datetime.now(UTC) - timedelta(days=400)
    for i in range(25):
        make_batch(session, project, title=f"c{i}", status="cancelled").created_at = old
    project.retention_days = 30
    session.commit()
    assert service.purge_due_batches(session, None) == 25


def test_a_batch_purged_by_another_runner_meanwhile_is_skipped(session, project, monkeypatch):
    b = make_batch(session, project, title="c", status="cancelled")
    b.created_at = datetime.now(UTC) - timedelta(days=400)
    project.retention_days = 30
    session.commit()
    real = service._lock_unpurged

    def raced(s, batch_id):
        s.execute(WorkBatch.__table__.update().where(WorkBatch.id == batch_id).values(purged_at=datetime.now(UTC)))
        return real(s, batch_id)

    monkeypatch.setattr(service, "_lock_unpurged", raced)
    assert service.purge_due_batches(session, None) == 0


# ---------- 10: a stuck rework unit ----------


def rework_unit(session, batch):
    published(session, batch, 1)
    author = eligible_worker(session)
    c = claim_unit(session, batch.id, author, "k")
    submit(session, c.id, author, {"transcript": "t"})
    session.commit()
    unit = session.scalars(select(WorkUnit)).one()
    on_verdict_rejected(session, verdict_event(unit.id, batch.id, author, "needs_edits", "incomplete"))
    session.commit()
    return unit, author


def test_ops_unassign_a_rework_unit_back_to_the_pool_signed(session, batch):
    unit, author = rework_unit(session, batch)
    assert unit.assigned_worker_id == author and unit.assigned_at is not None
    ops = uuid.uuid4()
    back = service.unassign_unit(session, unit.id, ops)
    session.commit()
    assert (back.assigned_worker_id, back.unassigned_by, back.status) == (None, ops, "available")
    assert back.unassigned_at is not None and back.assigned_at is None
    other = eligible_worker(session)
    assert claim_unit(session, batch.id, other, "k2").unit_id == unit.id  # anyone may take it now
    session.commit()
    with pytest.raises(Conflict) as e:
        service.unassign_unit(session, unit.id, ops)
    assert e.value.code == "unit_not_assigned"
    with pytest.raises(NotFound):
        service.unassign_unit(session, uuid.uuid4(), ops)


def test_an_assigned_batch_unit_is_handed_to_someone_else_not_to_nobody(session, project):
    batch = make_batch(session, project, mode="assigned")
    author, other = eligible_worker(session), eligible_worker(session)
    published(session, batch, 1, [{**good_lines(1)[0], "assigned_worker_id": str(author)}])
    unit = session.scalars(select(WorkUnit)).one()
    assert unit.assigned_at is not None
    with pytest.raises(Conflict) as e:
        service.unassign_unit(session, unit.id, uuid.uuid4())
    assert e.value.code == "assignment_required"
    session.rollback()
    moved = service.unassign_unit(session, unit.id, uuid.uuid4(), assign_to=other)
    session.commit()
    assert moved.assigned_worker_id == other and moved.assigned_at is not None
    assert claim_unit(session, batch.id, other, "k").unit_id == unit.id


def test_stuck_assigned_units_are_listed_and_counted_for_attention(session, batch):
    unit, author = rework_unit(session, batch)
    now = unit.assigned_at + timedelta(days=4)
    rows = service.stuck_assigned_units(session, days=3, now=now)
    assert [(u.id, b.id) for u, b, _ in rows] == [(unit.id, batch.id)]
    assert service.stuck_assigned_units(session, days=5, now=now) == []
    assert service.attention(session, now=now)["stuck_assigned_units"] == 1


# ---------- 11: submit on a claim that is not live ----------


def test_submitting_on_a_released_claim_is_claim_not_live(session, batch):
    published(session, batch, 1)
    w = eligible_worker(session)
    c = claim_unit(session, batch.id, w, "k")
    service.release_claim(session, c.id, w)
    session.commit()
    with pytest.raises(Conflict) as e:
        submit(session, c.id, w, {"transcript": "late"})
    assert e.value.code == "claim_not_live"


# ---------- 12: consent ----------


def test_a_withdrawn_consent_refuses_claims_until_consent_is_given_again(session, batch):
    published(session, batch, 1)
    w = eligible_worker(session)
    t0 = datetime.now(UTC)
    on_consent_withdrawn(session, env("worker.consent.withdrawn.v1", {"worker_id": str(w)}, t0))
    session.commit()
    with pytest.raises(Forbidden) as e:
        claim_unit(session, batch.id, w, "k")
    assert e.value.code == "consent_withdrawn"
    session.rollback()
    on_consent_given(session, env("worker.consent.given.v1", {"worker_id": str(w)}, t0 - timedelta(minutes=1)))
    session.commit()  # an older "given" arriving late changes nothing
    with pytest.raises(Forbidden):
        claim_unit(session, batch.id, w, "k")
    session.rollback()
    on_consent_given(session, env("worker.consent.given.v1", {"worker_id": str(w)}, t0 + timedelta(minutes=1)))
    session.commit()
    assert claim_unit(session, batch.id, w, "k").status == "active"


def test_consent_events_for_a_worker_market_has_not_met_are_kept(session):
    w = uuid.uuid4()
    on_consent_withdrawn(session, env("worker.consent.withdrawn.v1", {"worker_id": str(w)}))
    session.commit()
    profile = session.get(WorkerProfile, w)
    assert profile.status == "unknown" and profile.consent_withdrawn_at is not None


# ---------- 13, 15: uploads ----------


def test_svg_is_refused_and_other_images_pass():
    with pytest.raises(ValidationError):
        UploadFileIn(name="a.svg", content_type="image/svg+xml", size_bytes=10)
    assert UploadFileIn(name="a.png", content_type="image/png", size_bytes=10).content_type == "image/png"


def test_the_presigned_put_is_signed_for_the_declared_size(session, batch):
    store = FakeStorage()
    out = service.payload_uploads(session, store, batch.id, [("a.wav", "audio/wav", 1234)])
    assert store.put_sizes[out[0]["key"]] == 1234
