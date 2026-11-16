"""The audit sample is keyed and hidden from reviewers, reviewers read only what they hold and may still review,
hand-set gates apply in order, nobody decides about themselves, and a late verdict always says `review_expired`."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from yantra_common.errors import Conflict, Forbidden, NotFound
from yantra_common.events import Envelope
from yantra_quality import service
from yantra_quality.config import AuditKeyRefused, QualitySettings, quality_settings, refuse_rig_audit_key
from yantra_quality.models import ReviewerGate, ReviewRelease, ReviewTask
from yantra_quality.router import OpsTaskOut, TaskDetailOut
from yantra_quality.testing import open_task, submitted_envelope, unit_sampled_for_audit

# under the rig's audit key: 0 is outside the sample (the old `int % 100 < 10` rule sampled it), 33 is inside
UNSAMPLED = uuid.UUID(int=0)
SAMPLED = uuid.UUID(int=33)


def env(type_: str, data: dict, at: datetime | None = None) -> Envelope:
    return Envelope(uuid.uuid4(), type_, "x", at or datetime.now(UTC), data)


def held_task(session, gate=None, sensitive=False, unit=UNSAMPLED):
    author, reviewer = uuid.uuid4(), uuid.uuid4()
    e = submitted_envelope(author, uuid.uuid4(), unit)
    e.data.update(project_id=str(uuid.uuid4()), cert_gate=gate, sensitive=sensitive)
    service.on_unit_submitted(session, e)
    if gate:
        service.upsert_reviewer_gate(session, reviewer, gate, "assess", datetime.now(UTC))
    if sensitive:
        service.set_reviewer(session, reviewer, True, uuid.uuid4())
    session.commit()
    task = service.claim_review(session, reviewer)
    session.commit()
    return task, author, reviewer


# ---------- 1: the audit sample ----------


def test_the_sample_is_an_hmac_of_the_unit_under_the_key_at_a_ten_percent_rate():
    assert service.sampled_for_audit(SAMPLED) and not service.sampled_for_audit(UNSAMPLED)
    rate = sum(service.sampled_for_audit(uuid.UUID(int=i)) for i in range(10_000))
    assert 900 <= rate <= 1100  # 973 under the rig key; stable because the key is fixed
    other = [service.sampled_for_audit(uuid.UUID(int=i), key="another-key") for i in range(200)]
    mine = [service.sampled_for_audit(uuid.UUID(int=i)) for i in range(200)]
    assert other != mine  # a different key samples different units
    assert service.sampled_for_audit(UNSAMPLED, percent=100) and not service.sampled_for_audit(SAMPLED, percent=0)
    assert unit_sampled_for_audit(True) == SAMPLED and unit_sampled_for_audit(False) == uuid.UUID(int=1)
    assert service.sampled_for_audit(unit_sampled_for_audit(True, key="another-key"), key="another-key")


def test_the_sample_is_decided_when_the_task_opens(session):
    open_task(session, uuid.uuid4(), uuid.uuid4(), SAMPLED)
    open_task(session, uuid.uuid4(), uuid.uuid4(), UNSAMPLED)
    sampled = {t.unit_id: t.sampled_for_audit for t in session.scalars(select(ReviewTask))}
    assert sampled == {SAMPLED: True, UNSAMPLED: False}


def test_the_reviewer_never_sees_the_sample_or_the_author_and_ops_see_both():
    assert {"sampled_for_audit", "worker_id"}.isdisjoint(TaskDetailOut.model_fields)
    assert {"sampled_for_audit", "worker_id"} <= set(OpsTaskOut.model_fields)


def test_a_deployed_environment_refuses_the_rig_audit_key(monkeypatch):
    refuse_rig_audit_key(QualitySettings())  # local: the rig key is fine
    with pytest.raises(AuditKeyRefused) as e:
        refuse_rig_audit_key(QualitySettings(env="prod"))
    assert "YANTRA_AUDIT_KEY" in str(e.value) and "local-dev" not in str(e.value)
    with pytest.raises(AuditKeyRefused):
        refuse_rig_audit_key(QualitySettings(env="staging", audit_key="short"))
    refuse_rig_audit_key(QualitySettings(env="prod", audit_key="x" * 32))
    quality_settings.cache_clear()
    monkeypatch.setenv("YANTRA_AUDIT_KEY", "k" * 40)
    try:
        assert quality_settings().audit_key == "k" * 40
    finally:
        quality_settings.cache_clear()


# ---------- 2: reviewers read only what they hold, and only while they may ----------


def test_the_reviewer_reads_the_task_only_while_holding_it(session):
    task, _, reviewer = held_task(session)
    assert service.get_task(session, task.id, reviewer).id == task.id
    service.record_review(session, task.id, reviewer, "accept")
    session.commit()
    with pytest.raises(NotFound):
        service.get_task(session, task.id, reviewer)  # the verdict is in: the copy is no longer theirs to read


def test_the_first_reviewer_loses_the_task_once_the_auditor_holds_it(session):
    task, _, reviewer = held_task(session, unit=SAMPLED)
    service.record_review(session, task.id, reviewer, "accept")
    session.commit()
    auditor = uuid.uuid4()
    service.claim_review(session, auditor, kind="audit")
    session.commit()
    assert service.get_task(session, task.id, auditor).id == task.id
    with pytest.raises(NotFound):
        service.get_task(session, task.id, reviewer)


def test_a_revoked_clearance_gives_the_held_task_back_on_the_next_read(session):
    task, _, reviewer = held_task(session, sensitive=True)
    service.set_reviewer(session, reviewer, False, uuid.uuid4())
    session.commit()
    with pytest.raises(Forbidden) as e:
        service.get_task(session, task.id, reviewer)
    assert e.value.code == "clearance_revoked"
    session.rollback()
    session.refresh(task)
    assert task.status == "pending" and task.reviewer_id is None
    release = session.scalars(select(ReviewRelease)).one()
    assert (release.reason, release.holder_id, release.released_by) == ("revoked", reviewer, None)


def test_a_lost_gate_refuses_the_active_task_and_the_verdict(session):
    task, _, reviewer = held_task(session, gate="hindi")
    assert service.active_review(session, reviewer).id == task.id
    session.query(ReviewerGate).delete()
    session.commit()
    with pytest.raises(Forbidden) as e:
        service.active_review(session, reviewer)
    assert e.value.code == "clearance_revoked"
    session.rollback()
    task2, _, reviewer2 = held_task(session, gate="tamil")
    session.query(ReviewerGate).delete()
    session.commit()
    with pytest.raises(Forbidden) as e:
        service.record_review(session, task2.id, reviewer2, "accept")
    assert e.value.code == "clearance_revoked"
    session.rollback()
    assert session.get(ReviewTask, task2.id).status == "pending"


def test_a_task_released_between_the_read_and_the_lock_is_simply_gone(factory):
    with factory() as s:
        task, _, reviewer = held_task(s, sensitive=True)
        stale = s.get(ReviewTask, task.id)  # this session still believes the reviewer holds it
        with factory() as other:
            service.set_reviewer(other, reviewer, False, uuid.uuid4())
            service.release_review(other, task.id, reviewer)
            other.commit()
        assert stale.status == "claimed"
        with pytest.raises(NotFound):
            service.get_task(s, task.id, reviewer)


# ---------- 3: hand-set gates in order ----------


def gates_set(worker: uuid.UUID, gates: list[str], seq: int | None) -> Envelope:
    data: dict = {"worker_id": str(worker), "gates": gates}
    if seq is not None:
        data["seq"] = seq
    return env("worker.gates.set.v1", data)


def test_an_older_gates_event_never_brings_back_a_revoked_gate(session):
    w = uuid.uuid4()
    service.on_gates_set(session, gates_set(w, ["a", "b"], 1))
    service.on_gates_set(session, gates_set(w, ["b"], 2))
    session.commit()
    service.on_gates_set(session, gates_set(w, ["a", "b"], 1))  # late redelivery of the first
    session.commit()
    assert service.reviewer_gates(session, w) == ["b"]
    service.on_gates_set(session, gates_set(w, ["c"], 3))
    service.on_gates_set(session, gates_set(w, ["a"], None))  # an event from before sequences: applied as sent
    session.commit()
    assert service.reviewer_gates(session, w) == ["a"]


# ---------- 4: no decisions about oneself ----------


def test_ops_never_resolve_a_dispute_on_their_own_work_or_verdict(session):
    task, author, reviewer = held_task(session)
    service.record_review(session, task.id, reviewer, "reject", "low_quality")
    session.commit()
    dispute = service.raise_dispute(session, task.id, author, "it was fine, please look again")
    session.commit()
    for me in (author, reviewer):
        with pytest.raises(Forbidden) as e:
            service.resolve_dispute(session, dispute.id, "upheld", "mine", resolved_by=me)
        assert e.value.code == "self_action"
    assert service.resolve_dispute(session, dispute.id, "dismissed", "fair", resolved_by=uuid.uuid4()).status == (
        "dismissed"
    )


def test_ops_never_clear_themselves(session):
    me = uuid.uuid4()
    with pytest.raises(Forbidden) as e:
        service.set_reviewer(session, me, True, me)
    assert e.value.code == "self_action"


# ---------- 5: a late verdict is always review_expired ----------


def test_a_verdict_after_the_expiry_job_released_the_claim_is_review_expired(session):
    task, _, reviewer = held_task(session)
    task.claim_expires_at = datetime.now(UTC) - timedelta(seconds=1)
    session.commit()
    assert service.release_expired_reviews(session) == 1  # the job got there before the verdict
    session.commit()
    with pytest.raises(Conflict) as e:
        service.record_review(session, task.id, reviewer, "accept")
    assert e.value.code == "review_expired"
    session.rollback()
    with pytest.raises(Forbidden):  # someone who never held it is still just refused
        service.record_review(session, task.id, uuid.uuid4(), "accept")
    session.rollback()
    service.release_review(session, service.claim_review(session, reviewer).id, reviewer)  # held again, given back
    session.commit()
    with pytest.raises(Forbidden) as f:  # their last claim ended by their own hand: not an expiry
        service.record_review(session, task.id, reviewer, "accept")
    assert f.value.code == "forbidden"
