"""The production factory: settings from the environment, logging configured, the app serving; the events
process's consumers, relays and schedule."""

import os
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from yantra_assess.models import Sitting
from yantra_common.config import settings
from yantra_common.scheduler import At
from yantra_common.testing import ADMIN_URL
from yantra_work.app import default_app


def test_default_app_reads_the_database_url_from_the_environment(monkeypatch):
    monkeypatch.setenv(
        "YANTRA_DATABASE_URL",
        ADMIN_URL.rsplit("/", 1)[0] + "/yantra_work_test" + os.environ.get("YANTRA_TEST_DB_SUFFIX", ""),
    )
    settings.cache_clear()
    try:
        client = TestClient(default_app())
        assert client.get("/health").json() == {"status": "ok"}
        assert client.get("/ready").json()["status"] == "ok"
    finally:
        settings.cache_clear()


def test_the_events_runner_relays_every_outbox_and_mails_only_when_smtp_is_configured(monkeypatch):
    from yantra_notify.mailer import SmtpMailer
    from yantra_work import events
    from yantra_work.events import build, jobs_with_settings

    consumers, relays = build(None, None)
    durables = {c.durable for c in consumers}
    assert len(durables) == len(consumers) and len(relays) == 6  # one durable per consumer, never shared
    # five outboxes (market, talent, assess, quality, tracker) and the analytics rebuild drill
    assert {
        "talent-assess-failed-v1",
        "talent-payout-account-verified-v1",
        "notify-payout-account-verified-v1",
        "notify-payout-account-rejected-v1",
        "notify-payout-line-failed-v1",
        "notify-payout-reconciliation-delta-v1",
        "notify-worker-erasure-completed-v1",
        "notify-talent-person-seen-v1",
        "tracker-work-unit-claimed-v1",
        "tracker-work-claim-released-v1",
        "tracker-worker-consent-withdrawn-v1",
        "tracker-worker-consent-given-v1",
        "tracker-worker-erasure-completed-v1",
        "analytics-all-g0",
    } <= durables
    monkeypatch.setenv(
        "YANTRA_DATABASE_URL",
        ADMIN_URL.rsplit("/", 1)[0] + "/yantra_work_test" + os.environ.get("YANTRA_TEST_DB_SUFFIX", ""),
    )
    monkeypatch.delenv("YANTRA_SMTP_HOST", raising=False)
    settings.cache_clear()
    try:
        schedule = {j.name: j for j in jobs_with_settings(None)}
        assert "notify_email" not in schedule
        assert schedule["market_claim_expiry"].every == timedelta(seconds=30)
        assert schedule["quality_review_expiry"].every == timedelta(seconds=30)
        assert schedule["talent_offer_expiry"].every == timedelta(seconds=60)
        assert schedule["assess_engine_sync"].every == timedelta(seconds=15)
        assert "assess_sitting_expiry" not in schedule
        assert schedule["work_dead_letter_alert"].every == timedelta(minutes=5)
        assert schedule["market_retention_purge"].at == At(3, 30)
        assert schedule["talent_erasure"].every == timedelta(hours=1)
        assert schedule["tracker_stale_sessions"].every == timedelta(seconds=60)
        assert schedule["tracker_anomaly_scan"].every == timedelta(minutes=5)
        assert schedule["tracker_retention_purge"].every == timedelta(hours=1)
        assert schedule["analytics_mart_refresh"].every == timedelta(minutes=5)
        assert schedule["analytics_retention"].at == At(3, 15)
        for module in ("market", "talent", "assess", "quality", "notify", "tracker", "analytics"):
            assert schedule[f"{module}_prune"].at == At(3, 0)
        monkeypatch.setenv("YANTRA_SMTP_HOST", "localhost")
        settings.cache_clear()
        email = {j.name: j for j in jobs_with_settings(None)}["notify_email"]
        assert email.every == timedelta(seconds=3)
        seen = []
        monkeypatch.setattr(events, "jobs", lambda factory, mailer=None, store=None, **_: seen.append(mailer) or [])
        jobs_with_settings(None)
        assert isinstance(seen[0], SmtpMailer)
    finally:
        settings.cache_clear()


def test_the_expiry_jobs_release_what_lapsed(factory):
    from yantra_assess.engine.fake import FakeEngine
    from yantra_assess.testing import launched, make_paper
    from yantra_market.models import Claim
    from yantra_market.service import claim_unit, import_units, publish_batch
    from yantra_market.testing import eligible_worker, good_lines, make_batch, make_project
    from yantra_work import events

    fake = FakeEngine()
    schedule = {j.name: j for j in events.jobs(factory, assess_engine=fake)}
    with factory() as s:
        paper = make_paper(s, fake)
        sitting = launched(s, fake, paper)
        fake.begin(sitting.engine_attempt_id)
        project = make_project(s)
        batch = make_batch(s, project)
        import_units(s, batch.id, good_lines(2), dry_run=False)
        publish_batch(s, batch.id)
        s.commit()
        claim = claim_unit(s, batch.id, eligible_worker(s), idempotency_key="lapse-0001")
        claim.expires_at = datetime.now(UTC) - timedelta(minutes=1)
        s.commit()
    assert schedule["assess_engine_sync"].run() == 1 and schedule["assess_engine_sync"].run() == 0
    assert schedule["market_claim_expiry"].run() == 1 and schedule["market_claim_expiry"].run() == 0
    assert schedule["quality_review_expiry"].run() == 0 and schedule["talent_offer_expiry"].run() == 0
    assert schedule["analytics_retention"].run() == 0 and schedule["tracker_retention_purge"].run() == 0
    with factory() as s:
        assert s.get(Sitting, sitting.id).status == "in_progress"
        assert s.get(Claim, claim.id).status != "active"


def test_more_than_one_pass_of_lapsed_claims_is_released_in_one_run(monkeypatch):
    from yantra_work import events

    passes = iter([([uuid.uuid4()] * 500, True), ([uuid.uuid4()] * 3, False)])
    monkeypatch.setattr(events.market_service, "release_expired_claims", lambda s, limit: next(passes))
    assert events.release_expired_claims(None) == 503


def test_the_events_process_refuses_the_rig_audit_key_in_a_deployed_environment(monkeypatch):
    from yantra_quality.config import AuditKeyRefused, quality_settings
    from yantra_work.events import jobs_with_settings

    monkeypatch.setenv("YANTRA_ENV", "prod")
    quality_settings.cache_clear()
    try:
        with pytest.raises(AuditKeyRefused):
            jobs_with_settings(None)
    finally:
        quality_settings.cache_clear()
