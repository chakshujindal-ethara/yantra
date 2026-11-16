"""The event side of the work deployable, one process beside the HTTP one:
- relays: the market, talent, assess and quality outboxes to NATS (notify emits nothing, so it has no outbox);
- consumers: the five modules' handlers;
- jobs, on the leased scheduler: claim, review, offer and sitting expiry, email delivery, daily housekeeping and
  the dead-letter alert, each off the relay round so a slow one (an SMTP server that does not answer) never
  stalls the relays;
- `/health` and `/ready` on `YANTRA_EVENTS_PORT` (8085).
    YANTRA_DATABASE_URL=... YANTRA_NATS_URL=nats://localhost:4222 uv run python -m yantra_work.events"""

import asyncio
import functools
import logging
from datetime import UTC, datetime, timedelta

from sqlalchemy.orm import Session, sessionmaker

from yantra_analytics import marts as analytics_marts
from yantra_analytics import service as analytics_service
from yantra_analytics.config import analytics_settings
from yantra_analytics.consumers import ingest as analytics_ingest
from yantra_analytics.models import CONSUMED as ANALYTICS_CONSUMED
from yantra_analytics.models import DEAD as ANALYTICS_DEAD
from yantra_analytics.models import JOB_LEASE as ANALYTICS_LEASE
from yantra_analytics.rebuild import RebuildWatcher
from yantra_analytics.service import durable_name
from yantra_assess import service as assess_service
from yantra_assess.config import AssessSettings
from yantra_assess.engine import Engine, select_engine
from yantra_assess.models import CONSUMED as ASSESS_CONSUMED
from yantra_assess.models import DEAD as ASSESS_DEAD
from yantra_assess.models import JOB_LEASE as ASSESS_LEASE
from yantra_assess.models import OUTBOX as ASSESS_OUTBOX
from yantra_common.config import settings
from yantra_common.consumer import Consumer, Relay, serve
from yantra_common.deadletters import alert_job
from yantra_common.events import Bus
from yantra_common.prune import prune_job
from yantra_common.relay import relay_once
from yantra_common.scheduler import At, Job, in_session
from yantra_common.storage import Storage, storage_from_env
from yantra_market import consumers as market_consumers
from yantra_market import service as market_service
from yantra_market.models import CONSUMED as MARKET_CONSUMED
from yantra_market.models import DEAD as MARKET_DEAD
from yantra_market.models import JOB_LEASE as MARKET_LEASE
from yantra_market.models import OUTBOX as MARKET_OUTBOX
from yantra_notify import service as notify_service
from yantra_notify.mailer import SmtpMailer
from yantra_notify.models import CONSUMED as NOTIFY_CONSUMED
from yantra_notify.models import DEAD as NOTIFY_DEAD
from yantra_notify.models import JOB_LEASE as NOTIFY_LEASE
from yantra_notify.service import Mailer
from yantra_quality import service as quality_service
from yantra_quality.config import quality_settings
from yantra_quality.models import CONSUMED as QUALITY_CONSUMED
from yantra_quality.models import DEAD as QUALITY_DEAD
from yantra_quality.models import JOB_LEASE as QUALITY_LEASE
from yantra_quality.models import OUTBOX as QUALITY_OUTBOX
from yantra_talent import consumers as talent_consumers
from yantra_talent import service as talent_service
from yantra_talent.models import CONSUMED as TALENT_CONSUMED
from yantra_talent.models import DEAD as TALENT_DEAD
from yantra_talent.models import JOB_LEASE as TALENT_LEASE
from yantra_talent.models import OUTBOX as TALENT_OUTBOX
from yantra_tracker import consumers as tracker_consumers
from yantra_tracker import service as tracker_service
from yantra_tracker.config import tracker_settings
from yantra_tracker.models import CONSUMED as TRACKER_CONSUMED
from yantra_tracker.models import DEAD as TRACKER_DEAD
from yantra_tracker.models import JOB_LEASE as TRACKER_LEASE
from yantra_tracker.models import OUTBOX as TRACKER_OUTBOX

log = logging.getLogger("yantra.work")
OUTBOXES = [MARKET_OUTBOX, TALENT_OUTBOX, ASSESS_OUTBOX, QUALITY_OUTBOX, TRACKER_OUTBOX]
DEAD_TABLES = [MARKET_DEAD, TALENT_DEAD, ASSESS_DEAD, QUALITY_DEAD, NOTIFY_DEAD, TRACKER_DEAD, ANALYTICS_DEAD]
CLAIM_EXPIRY_PASSES = 10


def consumers(factory: sessionmaker[Session], nak_delay: float = 5.0) -> list[Consumer]:
    """Every consumer of the five modules. Needs no bus, so the HTTP side can build the replay table from it."""
    market = (factory, MARKET_CONSUMED, MARKET_DEAD, nak_delay)
    talent = (factory, TALENT_CONSUMED, TALENT_DEAD, nak_delay)
    quality = (factory, QUALITY_CONSUMED, QUALITY_DEAD, nak_delay)
    notify = (factory, NOTIFY_CONSUMED, NOTIFY_DEAD, nak_delay)
    tracker = (factory, TRACKER_CONSUMED, TRACKER_DEAD, nak_delay)
    return [
        Consumer("quality", "work.unit.submitted.v1", quality_service.on_unit_submitted, *quality),
        Consumer("market", "quality.verdict.accepted.v1", market_consumers.on_verdict_accepted, *market),
        Consumer("market", "quality.verdict.rejected.v1", market_consumers.on_verdict_rejected, *market),
        Consumer("market", "assess.certified.v1", market_consumers.on_assess_certified, *market),
        Consumer("market", "talent.offer.accepted.v1", market_consumers.on_offer_accepted, *market),
        Consumer("market", "worker.eligible.v1", market_consumers.on_worker_eligible, *market),
        Consumer("market", "talent.person.seen.v1", market_consumers.on_person_seen, *market),
        Consumer("market", "payout.hold.set.v1", market_consumers.on_hold_set, *market),
        Consumer("market", "worker.consent.withdrawn.v1", market_consumers.on_consent_withdrawn, *market),
        Consumer("market", "worker.consent.given.v1", market_consumers.on_consent_given, *market),
        Consumer("quality", "assess.certified.v1", quality_service.on_assess_certified, *quality),
        Consumer("quality", "talent.offer.accepted.v1", quality_service.on_offer_accepted, *quality),
        Consumer("quality", "work.batch.purged.v1", quality_service.on_batch_purged, *quality),
        Consumer("quality", "worker.gates.set.v1", quality_service.on_gates_set, *quality),
        Consumer("talent", "assess.certified.v1", talent_consumers.on_assess_certified, *talent),
        Consumer("talent", "assess.failed.v1", talent_consumers.on_assess_failed, *talent),
        Consumer("talent", "payout.account.verified.v1", talent_consumers.on_account_verified, *talent),
        Consumer("notify", "quality.verdict.accepted.v1", notify_service.on_verdict_accepted, *notify),
        Consumer("notify", "quality.verdict.rejected.v1", notify_service.on_verdict_rejected, *notify),
        Consumer("notify", "payout.paid.v1", notify_service.on_payout_paid, *notify),
        Consumer("notify", "talent.application.decided.v1", notify_service.on_application_decided, *notify),
        Consumer("notify", "payout.adjustment.approved.v1", notify_service.on_adjustment_approved, *notify),
        Consumer("notify", "payout.account.verified.v1", notify_service.on_account_verified, *notify),
        Consumer("notify", "payout.account.rejected.v1", notify_service.on_account_rejected, *notify),
        Consumer("notify", "payout.line.failed.v1", notify_service.on_line_failed, *notify),
        Consumer("notify", "payout.reconciliation.delta.v1", notify_service.on_reconciliation_delta, *notify),
        Consumer("notify", "worker.erasure.completed.v1", notify_service.on_erasure_completed, *notify),
        Consumer("notify", "talent.person.seen.v1", notify_service.on_person_seen, *notify),
        Consumer("tracker", "work.unit.claimed.v1", tracker_consumers.on_unit_claimed, *tracker),
        Consumer("tracker", "work.claim.expired.v1", tracker_consumers.on_claim_expired, *tracker),
        Consumer("tracker", "work.claim.released.v1", tracker_consumers.on_claim_released, *tracker),
        Consumer("tracker", "work.unit.submitted.v1", tracker_consumers.on_unit_submitted, *tracker),
        Consumer("tracker", "worker.consent.withdrawn.v1", tracker_consumers.on_consent_withdrawn, *tracker),
        Consumer("tracker", "worker.consent.given.v1", tracker_consumers.on_consent_given, *tracker),
        Consumer("tracker", "worker.erasure.completed.v1", tracker_consumers.on_erasure_completed, *tracker),
        # analytics reads every subject; a rebuild moves it to a fresh durable (RebuildWatcher)
        Consumer(
            "analytics",
            ">",
            analytics_ingest,
            factory,
            ANALYTICS_CONSUMED,
            ANALYTICS_DEAD,
            nak_delay,
            durable=durable_name(0),
        ),
    ]


def relays(factory: sessionmaker[Session], bus: Bus) -> list[Relay]:
    return [functools.partial(relay_once, factory, outbox, bus) for outbox in OUTBOXES]


def analytics_consumer(consumers: list[Consumer]) -> Consumer:
    [consumer] = [c for c in consumers if c.module == "analytics"]
    return consumer


def build(factory: sessionmaker[Session], bus: Bus, nak_delay: float = 5.0) -> tuple[list[Consumer], list[Relay]]:
    """The consumers, the outbox relays, and the analytics rebuild drill (a relay that owns the subscription)."""
    cs = consumers(factory, nak_delay)
    return cs, [*relays(factory, bus), RebuildWatcher(factory, bus, analytics_consumer(cs))]


def release_expired_claims(session: Session) -> int:
    """Up to ten bounded passes: a worker whose claim lapsed can claim again within the job's interval."""
    released = 0
    for _ in range(CLAIM_EXPIRY_PASSES):
        ids, more = market_service.release_expired_claims(session, limit=500)
        released += len(ids)
        if not more:
            break
    return released


def tracker_jobs(factory: sessionmaker[Session], store: Storage | None = None) -> list[Job]:
    """Stale sessions end after a quiet spell; the detectors run every five minutes; samples and screenshot
    references past their retention go hourly (their objects too, with storage), and so do the stored objects of
    erased workers."""
    cfg = tracker_settings()
    now = tracker_service.now_utc
    return [
        Job(
            "tracker_stale_sessions",
            in_session(factory, lambda s: tracker_service.end_stale_sessions(s, now(), cfg.stale_minutes)),
            TRACKER_LEASE,
            every=timedelta(seconds=60),
        ),
        Job(
            "tracker_anomaly_scan",
            in_session(factory, lambda s: tracker_service.scan_anomalies(s, now())),
            TRACKER_LEASE,
            every=timedelta(minutes=5),
        ),
        Job(
            "tracker_retention_purge",
            in_session(
                factory,
                lambda s: tracker_service.purge_expired(s, now(), cfg.retention_days, store)
                + tracker_service.purge_erased(s, now(), store),
            ),
            TRACKER_LEASE,
            every=timedelta(hours=1),
        ),
        prune_job(factory, "tracker_prune", TRACKER_LEASE, TRACKER_OUTBOX, TRACKER_CONSUMED),
    ]


def jobs(
    factory: sessionmaker[Session],
    mailer: Mailer | None = None,
    store: Storage | None = None,
    assess_engine: Engine | None = None,
    assess_config: AssessSettings | None = None,
) -> list[Job]:
    """The work deployable's schedule. Email delivery runs only when a mailer is configured; the retention purge
    deletes stored media only with storage (a batch with objects waits for it); the assess sync reads the
    assessment engine `YANTRA_ASSESS_*` names unless one is passed."""
    assess_config = assess_config or AssessSettings()
    engine = assess_engine or select_engine(assess_config)
    every = [
        Job(
            "market_claim_expiry",
            in_session(factory, release_expired_claims),
            MARKET_LEASE,
            every=timedelta(seconds=30),
        ),
        Job(
            "quality_review_expiry",
            in_session(factory, lambda s: quality_service.release_expired_reviews(s, limit=500)),
            QUALITY_LEASE,
            every=timedelta(seconds=30),
        ),
        Job(
            "talent_offer_expiry",
            in_session(factory, lambda s: talent_service.expire_due_offers(s, datetime.now(UTC))),
            TALENT_LEASE,
            every=timedelta(seconds=60),
        ),
        Job(
            "assess_engine_sync",
            in_session(factory, lambda s: assess_service.sync(s, engine)),
            ASSESS_LEASE,
            every=timedelta(seconds=assess_config.sync_seconds),
        ),
        prune_job(factory, "market_prune", MARKET_LEASE, MARKET_OUTBOX, MARKET_CONSUMED),
        Job(
            "market_retention_purge",
            in_session(factory, lambda s: market_service.purge_due_batches(s, store)),
            MARKET_LEASE,
            at=At(hour=3, minute=30),
            lease_seconds=600,
        ),
        prune_job(factory, "talent_prune", TALENT_LEASE, TALENT_OUTBOX, TALENT_CONSUMED),
        Job(
            "talent_erasure",
            in_session(factory, lambda s: talent_service.run_due_erasures(s, store)),
            TALENT_LEASE,
            every=timedelta(hours=1),
            lease_seconds=600,
        ),
        prune_job(factory, "assess_prune", ASSESS_LEASE, ASSESS_OUTBOX, ASSESS_CONSUMED),
        prune_job(factory, "quality_prune", QUALITY_LEASE, QUALITY_OUTBOX, QUALITY_CONSUMED),
        prune_job(factory, "notify_prune", NOTIFY_LEASE, None, NOTIFY_CONSUMED),
        alert_job(factory, "work_dead_letter_alert", MARKET_LEASE, DEAD_TABLES),
        *tracker_jobs(factory, store),
        Job(
            "analytics_mart_refresh",
            lambda: analytics_marts.refresh_marts(factory),
            ANALYTICS_LEASE,
            every=timedelta(minutes=5),
            lease_seconds=600,
        ),
        prune_job(factory, "analytics_prune", ANALYTICS_LEASE, None, ANALYTICS_CONSUMED),
        Job(
            "analytics_retention",
            in_session(
                factory,
                lambda s: analytics_service.prune_events(
                    s, analytics_service.now_utc(), analytics_settings().retention_days
                ),
            ),
            ANALYTICS_LEASE,
            at=At(hour=3, minute=15),
            lease_seconds=600,
        ),
    ]
    if mailer is not None:
        every.append(
            Job(
                "notify_email",
                in_session(
                    factory,
                    lambda s: notify_service.send_verifications(s, mailer) + notify_service.deliver_pending(s, mailer),
                ),
                NOTIFY_LEASE,
                every=timedelta(seconds=3),
            )
        )
    return every


def jobs_with_settings(factory: sessionmaker[Session]) -> list[Job]:
    """Production wiring: email leaves only when an SMTP host is configured. The audit key is checked first: this
    process samples submissions for audit, and a deployed environment refuses the rig's key at boot."""
    quality_settings()
    s = settings()
    if not s.smtp_host:
        log.warning("YANTRA_SMTP_HOST is not set: notifications stay in the inbox, no email leaves this process")
        return jobs(factory, store=storage_from_env())
    return jobs(factory, SmtpMailer(s.smtp_host, s.smtp_port, s.mail_from), store=storage_from_env())


if __name__ == "__main__":  # pragma: no cover
    from yantra_work.observe import OBSERVERS

    asyncio.run(serve(build, jobs_with_settings, OUTBOXES, DEAD_TABLES, "work-events", OBSERVERS))
