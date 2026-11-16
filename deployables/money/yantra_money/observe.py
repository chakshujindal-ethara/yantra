"""The money process's invariants for the metrics probe: pay-window lines by status in windows not yet paid (the
failed-payout ratio), when the last window closed (a missed weekly close), and the absolute reconciliation delta of
each window's latest run (must always be 0)."""

from datetime import datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from yantra_common.metrics import RECONCILIATION_DELTA, WINDOW_LAST_CLOSED, WINDOW_LINES
from yantra_payout.models import LINE_STATUSES, PayWindow, ReconciliationRun, WindowLine


def observe_windows(session: Session, now: datetime) -> None:
    counts: dict[str, int] = {
        status: int(count)
        for status, count in session.execute(
            select(WindowLine.status, func.count())
            .join(PayWindow, PayWindow.id == WindowLine.window_id)
            .where(PayWindow.status != "paid")
            .group_by(WindowLine.status)
        ).tuples()
    }
    for status in LINE_STATUSES:
        WINDOW_LINES.labels(status).set(int(counts.get(status, 0)))
    last = session.scalar(select(func.max(PayWindow.closed_at)))
    WINDOW_LAST_CLOSED.set(0 if last is None else last.timestamp())


def observe_reconciliation(session: Session, now: datetime) -> None:
    latest = (
        select(ReconciliationRun.delta_lines, ReconciliationRun.delta_rail)
        .distinct(ReconciliationRun.window_id)
        .order_by(ReconciliationRun.window_id, ReconciliationRun.ran_at.desc())
        .subquery()
    )
    total = session.scalar(
        select(func.coalesce(func.sum(func.abs(latest.c.delta_lines) + func.abs(latest.c.delta_rail)), 0))
    )
    RECONCILIATION_DELTA.set(float(total or 0))


OBSERVERS = [observe_windows, observe_reconciliation]
