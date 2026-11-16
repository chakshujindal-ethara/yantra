"""Gates and eligibility from events, and the verdict log. Every handler is idempotent: a gate is a set, a
redelivered verdict writes one log row, eligibility never downgrades a worker."""

import uuid
from datetime import UTC, datetime

from sqlalchemy import select

from yantra_common.events import Envelope
from yantra_market.consumers import (
    on_assess_certified,
    on_offer_accepted,
    on_verdict_accepted,
    on_verdict_rejected,
    on_worker_eligible,
)
from yantra_market.models import VerdictLog, WorkerProfile, WorkUnit
from yantra_market.service import claim_unit, grant_gate, import_units, mark_eligible, publish_batch, submit
from yantra_market.testing import eligible_worker, good_lines, verdict_event


def certified(worker_id: uuid.UUID, gate: str) -> Envelope:
    data = {"worker_id": str(worker_id), "gate": gate, "paper_id": str(uuid.uuid4()), "score": "0.9"}
    return Envelope(uuid.uuid4(), "assess.certified.v1", f"worker/{worker_id}", datetime.now(UTC), data)


def offer(worker_id: uuid.UUID, gate: str | None) -> Envelope:
    data = {
        "application_id": str(uuid.uuid4()),
        "listing_id": str(uuid.uuid4()),
        "worker_id": str(worker_id),
        "gate": gate,
    }
    return Envelope(uuid.uuid4(), "talent.offer.accepted.v1", f"worker/{worker_id}", datetime.now(UTC), data)


def eligible(worker_id: uuid.UUID) -> Envelope:
    data = {"worker_id": str(worker_id), "legal_name_hash": "abc", "pan_last4": "123F"}
    return Envelope(uuid.uuid4(), "worker.eligible.v1", f"worker/{worker_id}", datetime.now(UTC), data)


def test_a_certification_creates_an_unknown_profile_holding_the_gate_and_is_idempotent(session):
    worker = uuid.uuid4()
    on_assess_certified(session, certified(worker, "transcription"))
    session.commit()
    profile = session.get(WorkerProfile, worker)
    assert profile.status == "unknown" and profile.cert_gates == ["transcription"]
    on_assess_certified(session, certified(worker, "transcription"))
    on_assess_certified(session, certified(worker, "captioning"))
    session.commit()
    session.refresh(profile)
    assert profile.cert_gates == ["transcription", "captioning"]
    existing = eligible_worker(session, gates=["x"])
    on_assess_certified(session, certified(existing, "y"))
    session.commit()
    kept = session.get(WorkerProfile, existing)
    assert kept.status == "eligible" and kept.cert_gates == ["x", "y"]


def test_an_accepted_offer_grants_the_listings_gate_only_when_it_carries_one(session):
    worker = uuid.uuid4()
    on_offer_accepted(session, offer(worker, None))
    session.commit()
    assert session.get(WorkerProfile, worker) is None  # a listing with a paper: the paper grants the gate
    on_offer_accepted(session, offer(worker, "captioning"))
    session.commit()
    profile = session.get(WorkerProfile, worker)
    assert profile.status == "unknown" and profile.cert_gates == ["captioning"]


def test_eligibility_lifts_unknown_only_and_never_downgrades(session):
    fresh = uuid.uuid4()
    on_worker_eligible(session, eligible(fresh))
    session.commit()
    assert session.get(WorkerProfile, fresh).status == "eligible"
    unknown = uuid.uuid4()
    grant_gate(session, unknown, "transcription")
    session.commit()
    on_worker_eligible(session, eligible(unknown))
    session.commit()
    lifted = session.get(WorkerProfile, unknown)
    assert lifted.status == "eligible" and lifted.cert_gates == ["transcription"]
    for status in ("active", "suspended", "offboarded"):
        w = uuid.uuid4()
        session.add(WorkerProfile(id=w, status=status, cert_gates=[]))
        session.commit()
        on_worker_eligible(session, eligible(w))
        session.commit()
        assert session.get(WorkerProfile, w).status == status
    assert mark_eligible(session, fresh).status == "eligible"  # again: nothing changes
    assert session.get(WorkerProfile, fresh).updated_at is not None


def test_every_verdict_is_logged_once_per_event_and_an_unknown_unit_logs_nothing(session, project, batch):
    import_units(session, batch.id, good_lines(2), dry_run=False)
    publish_batch(session, batch.id)
    author = eligible_worker(session)
    claim = claim_unit(session, batch.id, author, "log-0001")
    submit(session, claim.id, author, {"t": 1})
    session.commit()
    event = verdict_event(claim.unit_id, batch.id, author, "needs_edits", "client_glossary_change", billable=True)
    on_verdict_rejected(session, event)
    on_verdict_rejected(session, event)  # a redelivery: the unit is no longer submitted, the log stays one row
    session.commit()
    rows = session.scalars(select(VerdictLog)).all()
    assert len(rows) == 1
    row = rows[0]
    assert (row.event_id, row.unit_id, row.batch_id, row.project_id) == (event.id, claim.unit_id, batch.id, project.id)
    assert (row.worker_id, row.verdict, row.reason_code, row.billable) == (
        author,
        "needs_edits",
        "client_glossary_change",
        True,
    )
    assert row.at == event.occurred_at
    assert session.get(WorkUnit, claim.unit_id).assigned_worker_id == author
    again = claim_unit(session, batch.id, author, "log-0002")
    submit(session, again.id, author, {"t": 2})
    session.commit()
    accept = verdict_event(claim.unit_id, batch.id, author)
    on_verdict_accepted(session, accept)
    on_verdict_accepted(session, accept)
    session.commit()
    verdicts = session.scalars(select(VerdictLog.verdict).order_by(VerdictLog.at)).all()
    assert verdicts == ["needs_edits", "accept"]
    accepted = session.scalar(select(VerdictLog).where(VerdictLog.verdict == "accept"))
    assert accepted.reason_code is None and accepted.billable is False
    assert session.get(WorkUnit, claim.unit_id).status == "accepted"
    on_verdict_accepted(session, verdict_event(uuid.uuid4(), batch.id, author))
    on_verdict_rejected(session, verdict_event(uuid.uuid4(), batch.id, author, "reject"))
    session.commit()
    assert len(session.scalars(select(VerdictLog)).all()) == 2


def test_a_verdict_on_a_unit_that_is_not_submitted_is_logged_but_moves_nothing(session, batch):
    import_units(session, batch.id, good_lines(1), dry_run=False)
    publish_batch(session, batch.id)
    session.commit()
    unit = session.scalar(select(WorkUnit))
    on_verdict_accepted(session, verdict_event(unit.id, batch.id, uuid.uuid4()))
    session.commit()
    assert session.get(WorkUnit, unit.id).status == "available"
    assert session.scalar(select(VerdictLog)).verdict == "accept"
