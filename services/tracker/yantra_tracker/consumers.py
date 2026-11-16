"""What the tracker consumes: market's claim events, into the `live_claim` read model (a released claim ends like an
expired one), and talent's consent and erasure events (no collection while consent is withdrawn; an erased worker's
samples, screenshots and device ids go). Every handler is idempotent, so a redelivery changes nothing."""

import uuid
from datetime import datetime

from sqlalchemy.orm import Session

from yantra_common.events import Envelope
from yantra_contracts.events.v1 import (
    WorkerConsentGiven,
    WorkerConsentWithdrawn,
    WorkerErasureCompleted,
    WorkUnitClaimed,
    WorkUnitSubmitted,
)
from yantra_tracker import service


def on_unit_claimed(session: Session, env: Envelope) -> None:
    e = WorkUnitClaimed.model_validate(env.data)
    service.claim_started(
        session,
        e.claim_id,
        e.unit_id,
        e.worker_id,
        e.batch_id,
        e.project_id,
        env.occurred_at,
        datetime.fromisoformat(e.expires_at),
    )


def _ended(session: Session, env: Envelope, kind: str) -> None:
    """Expired and released claims carry the same three ids; read them without a model per event."""
    d = env.data
    service.claim_ended(
        session, uuid.UUID(d["claim_id"]), uuid.UUID(d["unit_id"]), uuid.UUID(d["worker_id"]), env.occurred_at, kind
    )


def on_claim_expired(session: Session, env: Envelope) -> None:
    _ended(session, env, "expired")


def on_claim_released(session: Session, env: Envelope) -> None:
    _ended(session, env, "released")


def on_unit_submitted(session: Session, env: Envelope) -> None:
    e = WorkUnitSubmitted.model_validate(env.data)
    service.claim_ended(session, e.claim_id, e.unit_id, e.worker_id, env.occurred_at, "submitted")


def on_consent_withdrawn(session: Session, env: Envelope) -> None:
    e = WorkerConsentWithdrawn.model_validate(env.data)
    service.consent_withdrawn(session, e.worker_id, env.occurred_at)


def on_consent_given(session: Session, env: Envelope) -> None:
    e = WorkerConsentGiven.model_validate(env.data)
    service.consent_given(session, e.worker_id)


def on_erasure_completed(session: Session, env: Envelope) -> None:
    e = WorkerErasureCompleted.model_validate(env.data)
    service.erase_worker(session, e.worker_id, env.occurred_at)
