"""What talent consumes: `assess.certified.v1` (the gate lands in the `worker_gate` read model and every application
waiting on that paper moves to screening), `assess.failed.v1` (the outcome is kept on those applications) and
`payout.account.verified.v1` (the onboarding bank step)."""

import logging

from sqlalchemy.orm import Session

from yantra_common.events import Envelope
from yantra_contracts.events.v1 import AssessCertified, AssessFailed, PayoutAccountVerified
from yantra_talent import service

log = logging.getLogger("yantra.talent")


def on_assess_certified(session: Session, env: Envelope) -> None:
    e = AssessCertified.model_validate(env.data)
    service.upsert_gate(session, e.worker_id, e.gate, "assess", env.occurred_at)
    moved = service.certify_applications(session, e.worker_id, e.gate, e.score, env.occurred_at)
    log.info("certified worker_id=%s gate=%s applications_moved=%d", e.worker_id, e.gate, moved)


def on_assess_failed(session: Session, env: Envelope) -> None:
    e = AssessFailed.model_validate(env.data)
    marked = service.record_paper_failure(session, e.worker_id, e.gate, e.score, e.attempts_left, env.occurred_at)
    log.info(
        "paper failed worker_id=%s gate=%s attempts_left=%d applications=%d",
        e.worker_id,
        e.gate,
        e.attempts_left,
        marked,
    )


def on_account_verified(session: Session, env: Envelope) -> None:
    e = PayoutAccountVerified.model_validate(env.data)
    service.on_account_verified(session, e.worker_id, e.account_name_hash, env.occurred_at)
