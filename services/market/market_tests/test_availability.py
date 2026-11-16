"""Availability is the worker's own statement, never eligibility: a row exists without a profile, a pause hides
every pool and blocks a claim until it lapses; an answer schema on the project gates the submission."""

import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from yantra_common.db import unit_of_work
from yantra_common.errors import Forbidden, Invalid
from yantra_market.models import Submission, WorkerAvailability
from yantra_market.service import (
    MAX_PAUSE,
    claim_unit,
    import_units,
    is_paused,
    open_batches,
    publish_batch,
    submit,
    upsert_availability,
)
from yantra_market.testing import eligible_worker, good_lines, make_batch, make_project

ANSWER_SCHEMA = {"type": "object", "required": ["transcript"], "properties": {"transcript": {"type": "string"}}}


def published(session, batch, n):
    import_units(session, batch.id, good_lines(n), dry_run=False)
    publish_batch(session, batch.id)
    session.commit()


def test_availability_is_upserted_without_a_profile_and_is_paused_only_while_paused_until_is_ahead(session):
    worker = uuid.uuid4()
    now = datetime.now(UTC)
    assert is_paused(session, worker, now) is False
    row = upsert_availability(session, worker, weekly_hours=20, paused_until=None)
    session.commit()
    assert (row.worker_id, row.weekly_hours, row.paused_until) == (worker, 20, None) and row.updated_at is not None
    assert is_paused(session, worker, now) is False
    later = upsert_availability(session, worker, weekly_hours=5, paused_until=now + timedelta(days=2))
    session.commit()
    assert later.weekly_hours == 5 and is_paused(session, worker, now) is True
    assert is_paused(session, worker, now + timedelta(days=3)) is False  # the pause has lapsed
    assert len(session.scalars(select(WorkerAvailability)).all()) == 1
    assert later.updated_at >= row.updated_at


def test_two_first_time_check_ins_at_once_both_land_on_one_row(factory, session):
    """The second caller's write waits on the first's uncommitted row, then updates it: never an IntegrityError."""
    worker = uuid.uuid4()
    upsert_availability(session, worker, weekly_hours=10, paused_until=None)  # flushed, not committed

    def second() -> int:
        with unit_of_work(factory) as s:
            return upsert_availability(s, worker, weekly_hours=20, paused_until=None).weekly_hours

    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(second)
        time.sleep(0.3)  # the second writer is now blocked on the first's row
        session.commit()
        assert future.result(timeout=10) == 20
    session.expire_all()
    assert session.get(WorkerAvailability, worker).weekly_hours == 20


def test_a_lapsed_pause_is_stored_as_none_and_a_pause_past_90_days_is_refused(session):
    worker = uuid.uuid4()
    now = datetime.now(UTC)
    row = upsert_availability(session, worker, weekly_hours=10, paused_until=now - timedelta(seconds=1))
    assert row.paused_until is None and row.weekly_hours == 10
    with pytest.raises(Invalid) as e:
        upsert_availability(session, worker, weekly_hours=10, paused_until=now + MAX_PAUSE + timedelta(minutes=1))
    assert str(e.value) == "paused_until: more than 90 days ahead"
    session.rollback()
    edge = now + MAX_PAUSE - timedelta(minutes=1)
    assert upsert_availability(session, worker, weekly_hours=10, paused_until=edge).paused_until == edge


def test_a_paused_worker_sees_no_pool_and_cannot_claim(session, batch):
    published(session, batch, 2)
    worker = eligible_worker(session)
    assert len(open_batches(session, worker)) == 1
    upsert_availability(session, worker, weekly_hours=10, paused_until=datetime.now(UTC) + timedelta(hours=1))
    session.commit()
    assert open_batches(session, worker) == []
    with pytest.raises(Forbidden) as e:
        claim_unit(session, batch.id, worker, idempotency_key="paused-key")
    assert e.value.code == "availability_paused"
    session.rollback()
    upsert_availability(session, worker, weekly_hours=10, paused_until=datetime.now(UTC) - timedelta(seconds=1))
    session.commit()
    assert len(open_batches(session, worker)) == 1
    assert claim_unit(session, batch.id, worker, idempotency_key="paused-key").worker_id == worker


def test_an_answer_is_checked_against_the_projects_answer_schema_before_anything_is_written(session):
    project = make_project(session, answer_schema=ANSWER_SCHEMA)
    batch = make_batch(session, project)
    published(session, batch, 1)
    worker = eligible_worker(session)
    claim = claim_unit(session, batch.id, worker, idempotency_key="k")
    session.commit()
    with pytest.raises(Invalid) as e:
        submit(session, claim.id, worker, {"transcript": 7})
    assert str(e.value) == "answer: transcript: 7 is not of type 'string'"
    # before any rollback: nothing pending in the session, nothing flushed (a write-then-raise would show here)
    assert not session.new and not session.dirty and claim.status == "active"
    assert session.scalar(select(Submission)) is None
    session.rollback()
    with pytest.raises(Invalid) as e:
        submit(session, claim.id, worker, {})
    assert str(e.value) == "answer: 'transcript' is a required property"
    session.rollback()
    ok = submit(session, claim.id, worker, {"transcript": "fine"})
    session.commit()
    assert ok.answer == {"transcript": "fine"}


def test_a_project_without_an_answer_schema_accepts_any_answer_object(session, batch):
    published(session, batch, 1)
    worker = eligible_worker(session)
    claim = claim_unit(session, batch.id, worker, idempotency_key="k")
    session.commit()
    assert submit(session, claim.id, worker, {"anything": [1, 2]}).answer == {"anything": [1, 2]}
