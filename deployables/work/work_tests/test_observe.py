"""The work probe's invariants: two live claims on one unit (impossible while the index stands, so the test drops
it inside a rolled-back transaction) and the age of the oldest review nobody picked up."""

import uuid
from datetime import UTC, datetime, timedelta

from prometheus_client import REGISTRY
from sqlalchemy import text

from yantra_market.models import Claim, WorkUnit
from yantra_market.testing import make_batch, make_project
from yantra_quality.models import ReviewTask
from yantra_work.observe import OBSERVERS, observe_backlog, observe_claims

NOW = datetime(2026, 11, 4, 12, 0, tzinfo=UTC)


def gauge(name: str) -> float:
    return REGISTRY.get_sample_value(name) or 0.0


def test_two_live_claims_on_one_unit_show_on_the_gauge(factory):
    with factory() as s:
        batch = make_batch(s, make_project(s))
        unit = WorkUnit(batch_id=batch.id, external_ref="u1", payload={}, status="claimed")
        s.add(unit)
        s.commit()
        for _ in range(2):
            s.add(Claim(unit_id=unit.id, worker_id=uuid.uuid4(), idempotency_key="k", expires_at=NOW))
            if _ == 0:
                s.flush()
                observe_claims(s, NOW)
                assert gauge("yantra_units_with_two_live_claims") == 0
                s.execute(text("DROP INDEX market.ix_claim_one_live_per_unit"))
        s.flush()
        observe_claims(s, NOW)
        assert gauge("yantra_units_with_two_live_claims") == 1
        s.rollback()  # the index comes back with the rollback


def test_the_oldest_waiting_review_sets_the_backlog_age(factory):
    with factory() as s:
        observe_backlog(s, NOW)
        assert gauge("yantra_review_backlog_oldest_age_seconds") == 0
        for status, age in (("pending", 3600), ("audit_pending", 600), ("canonical", 99999)):
            s.add(
                ReviewTask(
                    unit_id=uuid.uuid4(),
                    batch_id=uuid.uuid4(),
                    submission_id=uuid.uuid4(),
                    worker_id=uuid.uuid4(),
                    rubric_version="v1",
                    status=status,
                    payload={},
                    answer={},
                    created_at=NOW - timedelta(seconds=age),
                )
            )
        s.commit()
        observe_backlog(s, NOW)
        assert gauge("yantra_review_backlog_oldest_age_seconds") == 3600
    assert OBSERVERS == [observe_claims, observe_backlog]
