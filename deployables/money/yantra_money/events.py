"""The event side of the money deployable: relay the payout outbox, consume rates, verdicts, erasures, consent
withdrawn (payouts held) and given (lifted) and upheld tracker anomalies, run the payout jobs on the leased
scheduler (send queued lines, poll the rail and the penny drops, close the week, reconcile nightly), answer
`/health` and `/ready` on `YANTRA_EVENTS_PORT` (8086 in the rig).
YANTRA_DATABASE_URL=... YANTRA_NATS_URL=nats://localhost:4222 uv run python -m yantra_money.events"""

import asyncio
import functools

from sqlalchemy.orm import Session, sessionmaker

from yantra_common.consumer import Consumer, Relay, serve
from yantra_common.deadletters import alert_job
from yantra_common.events import Bus
from yantra_common.prune import prune_job
from yantra_common.relay import relay_once
from yantra_common.scheduler import Job
from yantra_payout import accounts, service
from yantra_payout.config import PayoutSettings, payout_settings
from yantra_payout.jobs import payout_jobs
from yantra_payout.models import CONSUMED, DEAD, JOB_LEASE, OUTBOX
from yantra_payout.rails import Rail, select_rail


def consumers(
    factory: sessionmaker[Session], nak_delay: float = 5.0, config: PayoutSettings | None = None
) -> list[Consumer]:
    tail = (factory, CONSUMED, DEAD, nak_delay)
    hold_days = (config or payout_settings()).payout_integrity_hold_days
    return [
        Consumer("payout", "work.unit.published.v1", service.on_unit_published, *tail),
        Consumer("payout", "quality.verdict.accepted.v1", service.on_verdict_accepted, *tail),
        Consumer("payout", "quality.verdict.rejected.v1", service.on_verdict_rejected, *tail),
        Consumer("payout", "worker.erasure.completed.v1", accounts.on_erasure_completed, *tail),
        Consumer("payout", "worker.consent.withdrawn.v1", service.on_consent_withdrawn, *tail),
        Consumer("payout", "worker.consent.given.v1", service.on_consent_given, *tail),
        Consumer(
            "payout",
            "tracking.anomaly.upheld.v1",
            functools.partial(service.on_anomaly_upheld, hold_days=hold_days),
            *tail,
        ),
    ]


def build(factory: sessionmaker[Session], bus: Bus, nak_delay: float = 5.0) -> tuple[list[Consumer], list[Relay]]:
    return consumers(factory, nak_delay), [functools.partial(relay_once, factory, OUTBOX, bus)]


def jobs(factory: sessionmaker[Session], rail: Rail | None = None, config: PayoutSettings | None = None) -> list[Job]:
    config = config or payout_settings()
    return [
        prune_job(factory, "payout_prune", JOB_LEASE, OUTBOX, CONSUMED),
        alert_job(factory, "payout_dead_letter_alert", JOB_LEASE, [DEAD]),
        *payout_jobs(factory, rail or select_rail(config), config),
    ]


if __name__ == "__main__":  # pragma: no cover
    from yantra_money.observe import OBSERVERS

    asyncio.run(serve(build, jobs, [OUTBOX], [DEAD], "money-events", OBSERVERS))
