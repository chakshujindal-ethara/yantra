"""What market consumes. The canonical verdicts: an accept closes the unit; a `needs_edits` verdict hands the
unit back to its author (available again, assigned to them); a `reject` returns it to the pool for anyone. That
is the rework path the delivery gate relies on: a batch completes only when every unit is accepted. Every verdict
is also written to the verdict log, the read model the reason distributions and acceptance rates are built on.

The bench: `assess.certified` and `talent.offer.accepted` grant a gate (creating an `unknown` profile when none
exists), `worker.eligible` turns `unknown` into `eligible` and never touches any other status. Every handler is
idempotent: the runner dedups on the event id, the log dedups on it again, and a gate is a set."""

import logging
import uuid
from datetime import datetime

from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session

from yantra_common.events import Envelope
from yantra_common.people import on_person_seen as _on_person_seen
from yantra_contracts.events.v1 import (
    AssessCertified,
    PayoutHoldSet,
    QualityVerdictAccepted,
    QualityVerdictRejected,
    TalentOfferAccepted,
    WorkerConsentGiven,
    WorkerConsentWithdrawn,
    WorkerEligible,
)
from yantra_market.models import PERSON, VerdictLog, WorkBatch, WorkUnit
from yantra_market.service import grant_gate, mark_eligible, set_consent, set_hold

log = logging.getLogger("yantra.market")


def on_verdict_accepted(session: Session, env: Envelope) -> None:
    e = QualityVerdictAccepted.model_validate(env.data)
    unit = session.get(WorkUnit, e.unit_id)
    if unit is None:
        log.warning("verdict for unknown unit unit_id=%s", e.unit_id)
        return
    _log_verdict(session, env, unit, e.worker_id, "accept", None, False)
    if _submitted(unit):
        unit.status = "accepted"
        session.flush()


def on_verdict_rejected(session: Session, env: Envelope) -> None:
    e = QualityVerdictRejected.model_validate(env.data)
    unit = session.get(WorkUnit, e.unit_id)
    if unit is None:
        log.warning("verdict for unknown unit unit_id=%s", e.unit_id)
        return
    _log_verdict(session, env, unit, e.worker_id, e.verdict, e.reason_code, e.billable)
    if not _submitted(unit):
        return
    unit.status = "available"
    unit.current_claim_id = None
    unit.assigned_worker_id = e.worker_id if e.verdict == "needs_edits" else None
    unit.assigned_at = env.occurred_at if e.verdict == "needs_edits" else None
    session.flush()
    log.info("unit back for rework unit_id=%s verdict=%s", unit.id, e.verdict)


def on_assess_certified(session: Session, env: Envelope) -> None:
    e = AssessCertified.model_validate(env.data)
    grant_gate(session, e.worker_id, e.gate)


def on_offer_accepted(session: Session, env: Envelope) -> None:
    """A listing without a paper opens its gate on acceptance; one with a paper carries no gate here."""
    e = TalentOfferAccepted.model_validate(env.data)
    if e.gate:
        grant_gate(session, e.worker_id, e.gate)


def on_worker_eligible(session: Session, env: Envelope) -> None:
    e = WorkerEligible.model_validate(env.data)
    mark_eligible(session, e.worker_id)


# a display name for the bench and the feedback thread; a null name forgets it
on_person_seen = _on_person_seen(PERSON)


def on_hold_set(session: Session, env: Envelope) -> None:
    """A payout hold set or lifted, so the bench can show who is held. Payout stays the source of truth."""
    e = PayoutHoldSet.model_validate(env.data)
    until = datetime.fromisoformat(e.until) if e.until else None
    set_hold(session, e.worker_id, e.reason, until, env.occurred_at)


def on_consent_withdrawn(session: Session, env: Envelope) -> None:
    """The worker withdrew the data-processing consent: no new claims until they give it again."""
    e = WorkerConsentWithdrawn.model_validate(env.data)
    set_consent(session, e.worker_id, withdrawn=True, at=env.occurred_at)


def on_consent_given(session: Session, env: Envelope) -> None:
    e = WorkerConsentGiven.model_validate(env.data)
    set_consent(session, e.worker_id, withdrawn=False, at=env.occurred_at)


def _submitted(unit: WorkUnit) -> bool:
    """A verdict moves a unit only out of `submitted`; anything else (a replay after a rework) is logged and left."""
    if unit.status != "submitted":
        log.warning("verdict ignored: unit not in submitted unit_id=%s status=%s", unit.id, unit.status)
        return False
    return True


def _log_verdict(
    session: Session,
    env: Envelope,
    unit: WorkUnit,
    worker_id: uuid.UUID,
    verdict: str,
    reason_code: str | None,
    billable: bool,
) -> None:
    """One log row per event, whatever the unit's state: the log is the record of verdicts, not of units.
    INSERT ... ON CONFLICT DO NOTHING on the event id keeps a redelivery from writing twice."""
    batch = session.get(WorkBatch, unit.batch_id)
    assert batch is not None  # the unit's foreign key holds it
    session.execute(
        pg_insert(VerdictLog)
        .values(
            id=uuid.uuid4(),
            event_id=env.id,
            unit_id=unit.id,
            batch_id=batch.id,
            project_id=batch.project_id,
            worker_id=worker_id,
            verdict=verdict,
            reason_code=reason_code,
            billable=billable,
            at=env.occurred_at,
        )
        .on_conflict_do_nothing(index_elements=["event_id"])
    )
