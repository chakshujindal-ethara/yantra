import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from yantra_common.db import unit_of_work
from yantra_common.errors import Conflict, Forbidden, NotFound
from yantra_market import service
from yantra_market.models import OUTBOX, Claim, WorkUnit
from yantra_market.service import claim_unit, import_units, publish_batch, release_expired_claims, submit
from yantra_market.testing import eligible_worker, good_lines, make_batch


def published(session, batch, n, lines=None):
    import_units(session, batch.id, lines or good_lines(n), dry_run=False)
    publish_batch(session, batch.id)
    session.commit()


def events(session):
    return session.execute(
        select(OUTBOX.c.type, OUTBOX.c.subject, OUTBOX.c.payload).order_by(OUTBOX.c.occurred_at)
    ).all()


def test_claim_takes_one_available_unit_with_a_ttl_and_records_the_event(session, batch):
    published(session, batch, 2)
    w = eligible_worker(session)
    before = datetime.now(UTC)
    c = claim_unit(session, batch.id, w, idempotency_key="k1")
    session.commit()
    unit = session.get(WorkUnit, c.unit_id)
    assert unit.status == "claimed" and unit.current_claim_id == c.id
    assert timedelta(minutes=239) < c.expires_at - before < timedelta(minutes=241)
    last = events(session)[-1]
    assert (last.type, last.subject) == ("work.unit.claimed.v1", f"unit/{unit.id}")
    assert last.payload == {
        "unit_id": str(unit.id),
        "claim_id": str(c.id),
        "worker_id": str(w),
        "expires_at": c.expires_at.isoformat(),
        "batch_id": str(batch.id),
        "project_id": str(batch.project_id),
    }


def test_retried_claim_returns_the_first_claim(session, batch):
    published(session, batch, 3)
    w = eligible_worker(session)
    first = claim_unit(session, batch.id, w, idempotency_key="same")
    session.commit()
    again = claim_unit(session, batch.id, w, idempotency_key="same")
    assert again.id == first.id
    assert len(session.scalars(select(Claim)).all()) == 1


def test_a_key_is_the_workers_own_and_bound_to_its_batch(session, project, batch):
    published(session, batch, 3)
    a, b = eligible_worker(session), eligible_worker(session)
    first = claim_unit(session, batch.id, a, idempotency_key="shared-key")
    session.commit()
    second = claim_unit(session, batch.id, b, idempotency_key="shared-key")
    session.commit()
    assert second.id != first.id and second.worker_id == b and second.unit_id != first.unit_id
    other = make_batch(session, project, title="Batch 2")
    published(session, other, 1)
    with pytest.raises(Conflict) as e:
        claim_unit(session, other.id, a, idempotency_key="shared-key")
    assert e.value.code == "key_reused"


def test_one_live_claim_per_worker(session, batch):
    published(session, batch, 3)
    w = eligible_worker(session)
    claim_unit(session, batch.id, w, idempotency_key="a")
    session.commit()
    with pytest.raises(Conflict) as e:
        claim_unit(session, batch.id, w, idempotency_key="b")
    assert e.value.code == "one_live_claim"


def test_ineligible_or_ungated_worker_cannot_claim(session, batch):
    published(session, batch, 1)
    with pytest.raises(Forbidden):
        claim_unit(session, batch.id, uuid.uuid4(), idempotency_key="x")
    session.rollback()
    w = eligible_worker(session, gates=["something-else"])
    with pytest.raises(Forbidden):
        claim_unit(session, batch.id, w, idempotency_key="y")


def test_no_unit_left_is_not_found(session, batch):
    published(session, batch, 1)
    claim_unit(session, batch.id, eligible_worker(session), idempotency_key="a")
    session.commit()
    with pytest.raises(NotFound):
        claim_unit(session, batch.id, eligible_worker(session), idempotency_key="b")


def test_assigned_mode_serves_only_the_assigned_worker(session, batch):
    batch.mode = "assigned"
    session.commit()
    w1, w2 = eligible_worker(session), eligible_worker(session)
    lines = good_lines(2)
    lines[0]["assigned_worker_id"] = str(w1)
    published(session, batch, 2, lines)
    with pytest.raises(NotFound):
        claim_unit(session, batch.id, w2, idempotency_key="w2")
    session.rollback()
    c = claim_unit(session, batch.id, w1, idempotency_key="w1")
    assert session.get(WorkUnit, c.unit_id).external_ref == "u0"


def test_claim_storm_never_double_claims(factory, session, batch):
    published(session, batch, 40)
    workers = [eligible_worker(session) for _ in range(60)]

    def go(w: uuid.UUID) -> str:
        try:
            with unit_of_work(factory) as s:
                claim_unit(s, batch.id, w, idempotency_key=f"storm-{w}")
            return "ok"
        except NotFound:
            return "empty"

    with ThreadPoolExecutor(max_workers=30) as pool:
        results = list(pool.map(go, workers))
    assert results.count("ok") == 40 and results.count("empty") == 20
    claims = session.scalars(select(Claim)).all()
    assert len(claims) == 40 and len({c.unit_id for c in claims}) == 40
    assert session.scalar(select(WorkUnit).where(WorkUnit.status == "available").limit(1)) is None


def test_the_same_worker_sending_one_key_twice_at_once_gets_one_claim(factory, session, batch):
    published(session, batch, 2)
    w = eligible_worker(session)

    def go(_: int) -> uuid.UUID:
        with unit_of_work(factory) as s:
            return claim_unit(s, batch.id, w, idempotency_key="burst").id

    with ThreadPoolExecutor(max_workers=2) as pool:
        ids = set(pool.map(go, range(2)))
    assert len(ids) == 1 and len(session.scalars(select(Claim)).all()) == 1


def test_a_key_that_races_between_lookup_and_insert_returns_the_first_claim(session, batch, monkeypatch):
    """Both requests miss the lookup; one insert wins the unique index; the other returns the winner's claim."""
    published(session, batch, 2)
    w = eligible_worker(session)
    first = claim_unit(session, batch.id, w, idempotency_key="race")
    session.commit()
    real_lookup = service._existing_claim
    calls = {"n": 0}

    def lookup_misses_once(s, worker_id, key):
        calls["n"] += 1
        return None if calls["n"] == 1 else real_lookup(s, worker_id, key)

    monkeypatch.setattr(service, "_existing_claim", lookup_misses_once)
    again = claim_unit(session, batch.id, w, idempotency_key="race")
    assert again.id == first.id and calls["n"] == 2
    assert len(session.scalars(select(Claim)).all()) == 1


def test_an_unexpected_integrity_error_is_logged_and_not_swallowed(session, batch, monkeypatch, caplog):
    published(session, batch, 1)
    w = eligible_worker(session)
    original = Session.flush

    def broken_flush(self, *args, **kwargs):
        if not any(isinstance(o, Claim) for o in self.new):
            return original(self, *args, **kwargs)
        monkeypatch.setattr(Session, "flush", original)
        raise IntegrityError("INSERT ...", {}, Exception("some other constraint"))

    monkeypatch.setattr(Session, "flush", broken_flush)
    with pytest.raises(IntegrityError), caplog.at_level("WARNING", logger="yantra.market"):
        claim_unit(session, batch.id, w, idempotency_key="boom-key")
    assert "claim insert refused" in caplog.text and str(w) in caplog.text


def test_expired_claims_return_units_to_the_pool_in_bounded_batches(session, batch):
    published(session, batch, 3)
    workers = [eligible_worker(session) for _ in range(3)]
    claims = [claim_unit(session, batch.id, w, idempotency_key=f"k{w}") for w in workers]
    session.commit()
    assert release_expired_claims(session) == ([], False)  # nothing has expired yet
    late = claims[0].expires_at + timedelta(seconds=1)
    released, more = release_expired_claims(session, now=late, limit=2)
    session.commit()
    assert len(released) == 2 and more is True
    released2, more2 = release_expired_claims(session, now=late, limit=2)
    session.commit()
    assert len(released2) == 1 and more2 is False
    for c in claims:
        session.refresh(c)
        unit = session.get(WorkUnit, c.unit_id)
        assert c.status == "expired" and unit.status == "available" and unit.current_claim_id is None
    last = events(session)[-1]
    assert last.type == "work.claim.expired.v1" and last.payload["claim_id"] == str(claims[2].id)


def test_an_expired_claim_whose_unit_points_elsewhere_never_flips_the_unit(session, batch, caplog):
    published(session, batch, 1)
    w1 = eligible_worker(session)
    c1 = claim_unit(session, batch.id, w1, idempotency_key="k1")
    session.commit()
    other = uuid.uuid4()
    session.get(WorkUnit, c1.unit_id).current_claim_id = other  # drift: the unit no longer points at c1
    session.commit()
    with caplog.at_level("WARNING", logger="yantra.market"):
        release_expired_claims(session, now=c1.expires_at + timedelta(seconds=1))
    session.commit()
    unit = session.get(WorkUnit, c1.unit_id)
    assert unit.status == "claimed" and unit.current_claim_id == other
    assert "no longer current" in caplog.text


def test_a_unit_can_never_hold_two_live_claims(session, batch):
    published(session, batch, 1)
    w1, w2 = eligible_worker(session), eligible_worker(session)
    c1 = claim_unit(session, batch.id, w1, idempotency_key="k1")
    session.commit()
    session.add(Claim(unit_id=c1.unit_id, worker_id=w2, idempotency_key="x", status="active", expires_at=c1.expires_at))
    with pytest.raises(IntegrityError, match="ix_claim_one_live_per_unit"):
        session.commit()
    session.rollback()


def test_submit_closes_the_claim_and_is_idempotent(session, batch):
    published(session, batch, 1)
    w = eligible_worker(session)
    c = claim_unit(session, batch.id, w, idempotency_key="k")
    session.commit()
    s1 = submit(session, c.id, w, {"transcript": "..."})
    session.commit()
    s2 = submit(session, c.id, w, {"transcript": "changed"})
    assert s1.id == s2.id and s2.answer == {"transcript": "..."}
    session.refresh(c)
    assert c.status == "submitted" and session.get(WorkUnit, c.unit_id).status == "submitted"
    last = events(session)[-1]
    assert (last.type, last.subject) == ("work.unit.submitted.v1", f"unit/{c.unit_id}")
    assert last.payload == {
        "unit_id": str(c.unit_id),
        "batch_id": str(batch.id),
        "claim_id": str(c.id),
        "submission_id": str(s1.id),
        "worker_id": str(w),
        "rubric_version": "v1",
        "payload": {"text": "line 0", "language": "hi"},
        "answer": {"transcript": "..."},
        "project_id": str(batch.project_id),
        "cert_gate": "transcription",
        "sensitive": False,
    }


def test_submit_by_another_worker_past_ttl_or_after_release_is_refused(session, batch):
    published(session, batch, 1)
    w = eligible_worker(session)
    c = claim_unit(session, batch.id, w, idempotency_key="k")
    session.commit()
    with pytest.raises(Forbidden):
        submit(session, c.id, uuid.uuid4(), {"a": 1})
    session.rollback()
    with pytest.raises(Conflict) as e:
        submit(session, c.id, w, {"a": 1}, now=c.expires_at + timedelta(seconds=1))
    assert e.value.code == "claim_expired"
    session.rollback()
    assert session.get(WorkUnit, c.unit_id).status == "claimed"
    release_expired_claims(session, now=c.expires_at + timedelta(seconds=1))
    session.commit()
    with pytest.raises(Conflict) as e:
        submit(session, c.id, w, {"a": 1})
    assert e.value.context["status"] == "expired"
    with pytest.raises(NotFound):
        submit(session, uuid.uuid4(), w, {"a": 1})
