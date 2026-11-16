import uuid
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from yantra_tracker import service
from yantra_tracker.models import OUTBOX
from yantra_tracker.schemas import SampleIn, SessionIn
from yantra_tracker.testing import device

SKEW = 300
CAP = 40


def start(
    session: Session, worker: uuid.UUID, now: datetime, claim_id: uuid.UUID | None = None, dev: str | None = None
):
    row = service.start_session(session, worker, SessionIn(claim_id=claim_id, device_hash=dev or device()), now)
    session.commit()
    return row


def samples(
    start_at: datetime, n: int, kind: str = "active", step: int = 30, label: str | None = None
) -> list[SampleIn]:
    return [SampleIn(at=start_at + timedelta(seconds=i * step), kind=kind, label=label) for i in range(n)]


def send(session: Session, sid: uuid.UUID, worker: uuid.UUID, batch: list[SampleIn], now: datetime, cap: int = CAP):
    out = service.add_samples(session, sid, worker, batch, now, SKEW, cap)
    session.commit()
    return out


def events(session: Session, type_: str | None = None) -> list[dict]:
    q = select(OUTBOX.c.type, OUTBOX.c.payload).order_by(OUTBOX.c.occurred_at)
    rows = session.execute(q).all()
    return [p for t, p in rows if type_ is None or t == type_]
