"""The work process's own invariants for the metrics probe: two live claims on one unit (a broken claim lock; must
always be 0) and the age of the oldest review task nobody has picked up."""

from datetime import datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from yantra_common.metrics import REVIEW_BACKLOG_AGE, UNITS_DOUBLE_CLAIMED
from yantra_market.models import Claim
from yantra_quality.models import ReviewTask

WAITING = ("pending", "audit_pending")


def observe_claims(session: Session, now: datetime) -> None:
    doubled = select(Claim.unit_id).where(Claim.status == "active").group_by(Claim.unit_id).having(func.count() > 1)
    UNITS_DOUBLE_CLAIMED.set(int(session.scalar(select(func.count()).select_from(doubled.subquery())) or 0))


def observe_backlog(session: Session, now: datetime) -> None:
    oldest = session.scalar(select(func.min(ReviewTask.created_at)).where(ReviewTask.status.in_(WAITING)))
    REVIEW_BACKLOG_AGE.set(0 if oldest is None else max(0.0, (now - oldest).total_seconds()))


OBSERVERS = [observe_claims, observe_backlog]
