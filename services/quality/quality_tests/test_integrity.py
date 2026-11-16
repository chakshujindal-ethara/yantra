"""Who may review what, the reason taxonomy as data, flag answer times, release history and stuck reviews."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from yantra_common.errors import Conflict, Forbidden, Invalid, NotFound
from yantra_common.events import Envelope
from yantra_quality import service
from yantra_quality.models import OUTBOX, Reason, ReviewRelease, ReviewTask, RubricFlag
from yantra_quality.testing import open_task, submitted_envelope


def env(type_: str, data: dict) -> Envelope:
    return Envelope(uuid.uuid4(), type_, "x", datetime.now(UTC), data)


def gated_task(session, author, batch, gate=None, sensitive=False):
    e = submitted_envelope(author, batch)
    e.data.update(project_id=str(uuid.uuid4()), cert_gate=gate, sensitive=sensitive)
    service.on_unit_submitted(session, e)
    session.commit()
    return session.scalars(select(ReviewTask).where(ReviewTask.unit_id == uuid.UUID(e.data["unit_id"]))).one()


@pytest.fixture
def restore_reasons(session):
    before = [
        (r.code, r.label, r.detail, r.billable, list(r.applies_to), r.sort, r.active)
        for r in session.scalars(select(Reason))
    ]
    yield
    session.rollback()
    session.query(Reason).delete()
    for code, label, detail, billable, applies, sort, active in before:
        session.add(
            Reason(
                code=code, label=label, detail=detail, billable=billable, applies_to=applies, sort=sort, active=active
            )
        )
    session.commit()


def test_submitted_event_carries_the_gate_and_sensitivity(session):
    task = gated_task(session, uuid.uuid4(), uuid.uuid4(), gate="transcription", sensitive=True)
    assert task.cert_gate == "transcription" and task.sensitive and task.project_id is not None


def test_a_gated_task_needs_the_gate_and_gates_come_from_events(session):
    author, reviewer = uuid.uuid4(), uuid.uuid4()
    gated_task(session, author, uuid.uuid4(), gate="transcription")
    with pytest.raises(NotFound) as e:
        service.claim_review(session, reviewer)
    assert e.value.context == {"waiting_for_gate": 1, "waiting_for_clearance": 0}
    session.rollback()
    service.on_assess_certified(
        session,
        env(
            "assess.certified.v1",
            {"worker_id": str(reviewer), "gate": "transcription", "paper_id": str(uuid.uuid4()), "score": "1"},
        ),
    )
    service.on_assess_certified(  # idempotent
        session,
        env(
            "assess.certified.v1",
            {"worker_id": str(reviewer), "gate": "transcription", "paper_id": str(uuid.uuid4()), "score": "1"},
        ),
    )
    session.commit()
    assert service.reviewer_gates(session, reviewer) == ["transcription"]
    assert service.claim_review(session, reviewer).cert_gate == "transcription"


def test_an_offer_gate_counts_and_an_offer_without_a_gate_grants_nothing(session):
    w = uuid.uuid4()
    base = {"application_id": str(uuid.uuid4()), "listing_id": str(uuid.uuid4()), "worker_id": str(w)}
    service.on_offer_accepted(session, env("talent.offer.accepted.v1", {**base, "gate": None}))
    service.on_offer_accepted(session, env("talent.offer.accepted.v1", {**base, "gate": "captions"}))
    session.commit()
    assert service.reviewer_gates(session, w) == ["captions"]


def test_sensitive_work_waits_for_clearance_and_eligible_work_flows_first(session):
    author, reviewer, ops = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    gated_task(session, author, uuid.uuid4(), sensitive=True)
    with pytest.raises(NotFound) as e:
        service.claim_review(session, reviewer)
    assert e.value.context == {"waiting_for_gate": 0, "waiting_for_clearance": 1}
    session.rollback()
    plain = gated_task(session, author, uuid.uuid4())
    assert service.claim_review(session, reviewer).id == plain.id  # the open task is served, the sensitive one waits
    session.commit()
    row = service.set_reviewer(session, reviewer, True, ops)
    assert row.sensitive_cleared and row.set_by == ops
    session.commit()
    assert service.is_cleared(session, reviewer)
    other = uuid.uuid4()
    service.set_reviewer(session, other, True, ops)
    session.commit()
    assert service.claim_review(session, other).sensitive


def test_an_empty_queue_is_still_not_found(session):
    with pytest.raises(NotFound):
        service.claim_review(session, uuid.uuid4())
    with pytest.raises(Invalid):
        service.claim_review(session, uuid.uuid4(), kind="nope")


def test_a_verdict_after_the_claim_ran_out_is_refused_and_the_task_is_back(session):
    author, reviewer = uuid.uuid4(), uuid.uuid4()
    open_task(session, author, uuid.uuid4())
    task = service.claim_review(session, reviewer)
    task.claim_expires_at = datetime.now(UTC) - timedelta(seconds=1)
    session.commit()
    with pytest.raises(Conflict) as e:
        service.record_review(session, task.id, reviewer, "accept")
    assert e.value.code == "review_expired"
    session.rollback()
    session.refresh(task)
    assert task.status == "pending" and task.reviewer_id is None
    release = session.scalars(select(ReviewRelease)).one()
    assert (release.reason, release.holder_id, release.released_by) == ("expired", reviewer, None)


def test_the_holder_gives_a_task_back_and_nobody_else_can(session):
    author, reviewer = uuid.uuid4(), uuid.uuid4()
    open_task(session, author, uuid.uuid4())
    task = service.claim_review(session, reviewer)
    session.commit()
    with pytest.raises(Forbidden):
        service.release_review(session, task.id, uuid.uuid4())
    with pytest.raises(Forbidden):
        service.release_review(session, uuid.uuid4(), reviewer)
    back = service.release_review(session, task.id, reviewer)
    session.commit()
    assert back.status == "pending"
    assert session.scalars(select(ReviewRelease)).one().reason == "holder"


def test_stuck_reviews_are_listed_released_one_by_one_and_all_signed(session):
    admin = uuid.uuid4()
    for _ in range(2):
        open_task(session, uuid.uuid4(), uuid.uuid4())
    r1, r2 = uuid.uuid4(), uuid.uuid4()
    t1 = service.claim_review(session, r1)
    session.commit()
    t2 = service.claim_review(session, r2)
    session.commit()
    t2.status, t2.auditor_id, t2.reviewer_id = "audit_claimed", r2, uuid.uuid4()  # an auditor holds the second
    session.commit()
    later = datetime.now(UTC) + timedelta(hours=2)
    assert {t.id for t in service.expired_reviews(session, later)} == {t1.id, t2.id}
    with pytest.raises(Conflict) as e:
        service.release_expired_review(session, t1.id, admin, now=datetime.now(UTC))
    assert e.value.code == "review_not_expired"
    with pytest.raises(NotFound):
        service.release_expired_review(session, uuid.uuid4(), admin, now=later)
    assert service.release_expired_review(session, t1.id, admin, now=later).status == "pending"
    assert service.release_expired_reviews(session, now=later, released_by=admin) == 1
    session.commit()
    session.refresh(t2)
    assert t2.status == "audit_pending" and t2.auditor_id is None
    history = service.released_reviews(session, later - timedelta(days=1))
    assert {h.kind for h in history} == {"review", "audit"} and all(h.released_by == admin for h in history)


def test_reasons_come_from_the_table_and_drive_validation_and_billing(session, restore_reasons):
    codes = [r.code for r in service.reasons(session)]
    assert codes[0] == "guideline_miss" and len(codes) == 6
    assert service.billable_codes(session) == {"client_glossary_change", "client_ambiguous_instruction"}
    service.upsert_reason(
        session,
        "audio_unusable",
        {
            "label": "Audio unusable",
            "detail": "",
            "billable": True,
            "applies_to": ["reject"],
            "sort": 9,
            "active": True,
        },
    )
    service.upsert_reason(
        session,
        "low_quality",
        {
            "label": "Low quality",
            "detail": "",
            "billable": False,
            "applies_to": ["needs_edits"],
            "sort": 3,
            "active": False,
        },
    )
    session.commit()
    assert "low_quality" not in [r.code for r in service.reasons(session)]
    assert "low_quality" in [r.code for r in service.reasons(session, include_retired=True)]
    author, reviewer = uuid.uuid4(), uuid.uuid4()
    open_task(session, author, uuid.uuid4(), uuid.UUID(int=0))  # outside the audit sample under the rig key
    task = service.claim_review(session, reviewer)
    session.commit()
    assert not task.sampled_for_audit
    with pytest.raises(Invalid) as e:
        service.record_review(session, task.id, reviewer, "needs_edits", "audio_unusable")
    assert "audio_unusable" not in e.value.context["codes"]
    with pytest.raises(Invalid):
        service.record_review(session, task.id, reviewer, "reject", "low_quality")
    service.record_review(session, task.id, reviewer, "reject", "audio_unusable")
    session.commit()
    payload = session.execute(
        select(OUTBOX.c.payload).where(OUTBOX.c.type == "quality.verdict.rejected.v1")
    ).scalar_one()
    assert payload["billable"] is True and payload["reason_code"] == "audio_unusable"


def test_flags_overdue_after_two_days_and_stats_count_them(session):
    open_task(session, uuid.uuid4(), uuid.uuid4())
    task = session.scalars(select(ReviewTask)).one()
    old = RubricFlag(task_id=task.id, batch_id=task.batch_id, reviewer_id=uuid.uuid4(), note="?")
    new = RubricFlag(task_id=task.id, batch_id=task.batch_id, reviewer_id=uuid.uuid4(), note="?")
    session.add_all([old, new])
    session.commit()
    old.created_at = datetime.now(UTC) - timedelta(days=3)
    session.commit()
    assert [f.id for f in service.open_flags(session, overdue_only=True)] == [old.id]
    assert len(service.open_flags(session)) == 2
    s = service.stats(session)
    assert (s["flags_open"], s["flags_overdue"]) == (2, 1)
    assert service.stats(session, {uuid.uuid4()})["flags_open"] == 0
    a = service.attention(session)
    assert (
        a["review_backlog"] == 1 and a["flags_overdue"] == 1 and a["disputes_open"] == 0 and a["expired_reviews"] == 0
    )


def test_a_purged_batch_drops_quality_copies(session):
    batch = uuid.uuid4()
    open_task(session, uuid.uuid4(), batch)
    service.on_batch_purged(
        session, env("work.batch.purged.v1", {"batch_id": str(batch), "project_id": str(uuid.uuid4()), "unit_count": 1})
    )
    session.commit()
    task = session.scalars(select(ReviewTask)).one()
    assert task.payload is None and task.answer is None


def test_hand_set_gates_replace_earlier_hand_set_ones_and_keep_earned_ones(session):
    w = uuid.uuid4()
    service.on_assess_certified(
        session,
        env(
            "assess.certified.v1", {"worker_id": str(w), "gate": "earned", "paper_id": str(uuid.uuid4()), "score": "1"}
        ),
    )
    service.on_gates_set(session, env("worker.gates.set.v1", {"worker_id": str(w), "gates": ["a", "b", "earned"]}))
    session.commit()
    assert service.reviewer_gates(session, w) == ["a", "b", "earned"]
    service.on_gates_set(session, env("worker.gates.set.v1", {"worker_id": str(w), "gates": ["b"]}))
    session.commit()
    assert service.reviewer_gates(session, w) == ["b", "earned"]
    service.on_gates_set(session, env("worker.gates.set.v1", {"worker_id": str(w), "gates": []}))
    session.commit()
    assert service.reviewer_gates(session, w) == ["earned"]
