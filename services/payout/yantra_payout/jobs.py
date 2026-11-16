"""The payout jobs the money events process schedules: send queued lines, ask the rail about lines and penny drops
still in flight, close the week's window (Saturday 00:05 IST, after the Friday 23:59:59 edge, five minutes for clock
skew and late commits) and reconcile every recent window nightly. Each is one bounded pass."""

import logging
from datetime import UTC, datetime, timedelta

from sqlalchemy.orm import Session, sessionmaker

from yantra_common.db import unit_of_work
from yantra_common.errors import Conflict
from yantra_common.scheduler import At, Job
from yantra_payout import accounts, paying, service
from yantra_payout.config import PayoutSettings
from yantra_payout.models import JOB_LEASE
from yantra_payout.rails import Rail

log = logging.getLogger("yantra.payout.jobs")
WINDOW_CLOSE = At(hour=0, minute=5, weekday=5)  # Saturday 00:05 IST
RECONCILE = At(hour=2, minute=0)


def close_due_windows(factory: sessionmaker[Session], settings: PayoutSettings, now: datetime | None = None) -> int:
    """Close last week's window in every paid currency. A window someone already closed by hand is fine."""
    now = now or datetime.now(UTC)
    closed = 0
    for currency in settings.payout_currencies:
        try:
            with unit_of_work(factory) as session:
                service.close_window(session, currency, now=now, max_per_worker=settings.payout_max_per_worker)
            closed += 1
        except Conflict:
            log.info("window already closed currency=%s", currency)
    return closed


def payout_jobs(factory: sessionmaker[Session], rail: Rail, settings: PayoutSettings) -> list[Job]:
    poll_after = timedelta(seconds=settings.payout_poll_after_seconds)
    return [
        Job("payout_dispatch", lambda: paying.dispatch_queued(factory, rail), JOB_LEASE, every=timedelta(seconds=15)),
        Job(
            "payout_rail_poll",
            lambda: paying.poll_processing(factory, rail, older_than=poll_after),
            JOB_LEASE,
            every=timedelta(seconds=60),
        ),
        Job(
            "payout_account_validation_poll",
            lambda: accounts.poll_verifying(factory, rail),
            JOB_LEASE,
            every=timedelta(seconds=60),
        ),
        Job(
            "payout_window_close",
            lambda: close_due_windows(factory, settings),
            JOB_LEASE,
            at=WINDOW_CLOSE,
            lease_seconds=300,
        ),
        Job("payout_reconcile", lambda: paying.reconcile_recent(factory), JOB_LEASE, at=RECONCILE, lease_seconds=600),
    ]
