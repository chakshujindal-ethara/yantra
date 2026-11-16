"""The funnel: every application status change is announced, the paper outcome is kept for ops, the listing's steps
shape the application, and the hired-this-week count."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from yantra_common.events import Envelope
from yantra_talent.consumers import on_assess_certified, on_assess_failed
from yantra_talent.models import OUTBOX
from yantra_talent.schemas import ListingIn, listing_steps
from yantra_talent.service import (
    answer_offer,
    apply,
    decide,
    expire_due_offers,
    hired_this_week,
    listing_applications,
    withdraw,
)
from yantra_talent.testing import make_listing

NOW = datetime.now(UTC)
ANSWERS = {"experience": "3 years"}
OPS = uuid.uuid4()


def moves(session) -> list[tuple[str | None, str]]:
    rows = session.execute(
        select(OUTBOX).where(OUTBOX.c.type == "talent.application.moved.v1").order_by(OUTBOX.c.occurred_at)
    )
    return [(r.payload["from_status"], r.payload["to_status"]) for r in rows]


def assess(kind: str, worker: uuid.UUID, **data: object) -> Envelope:
    return Envelope(
        id=uuid.uuid4(),
        type=f"assess.{kind}.v1",
        subject=str(worker),
        occurred_at=NOW,
        data={"worker_id": str(worker), "gate": "transcription", "paper_id": str(uuid.uuid4()), **data},
    )


def test_listing_steps_keep_their_order_follow_the_paper_and_default_sensibly():
    assert listing_steps(None, False) == ["form"]
    assert listing_steps(None, True) == ["form", "paper", "availability"]
    assert listing_steps(["availability", "form"], False) == ["form", "availability"]
    assert listing_steps(["form", "paper"], False) == ["form"]  # no paper on the listing: no paper step
    assert listing_steps(["form"], True) == ["form", "paper"]  # a paper always shows its step
    body = ListingIn(
        title="t",
        domain="d",
        summary="s",
        pay_min=1,
        pay_max=2,
        currency="INR",
        commitment="task_based",
        slots_total=1,
        cert_gate="g",
        paper_id=uuid.uuid4(),
        steps=["form"],
    )
    assert body.steps == ["form", "paper"]


def test_every_status_change_is_announced(session, worker):
    listing = make_listing(session)
    app = apply(session, listing.id, worker, ANSWERS, NOW)
    decide(session, app.id, OPS, "offer", None, 1, NOW)
    answer_offer(session, app.id, worker, True, NOW)
    other = apply(session, make_listing(session).id, worker, ANSWERS, NOW)
    decide(session, other.id, OPS, "reject", None, 7, NOW)
    third = apply(session, make_listing(session).id, worker, ANSWERS, NOW)
    withdraw(session, third.id, worker)
    fourth = apply(session, make_listing(session).id, worker, ANSWERS, NOW)
    decide(session, fourth.id, OPS, "offer", None, 1, NOW)
    answer_offer(session, fourth.id, worker, False, NOW)
    fifth = apply(session, make_listing(session).id, worker, ANSWERS, NOW)
    decide(session, fifth.id, OPS, "offer", None, 1, NOW)
    session.commit()
    assert expire_due_offers(session, NOW + timedelta(days=2)) == 1
    session.commit()
    assert moves(session) == [
        (None, "screening"), ("screening", "offered"), ("offered", "accepted"),
        (None, "screening"), ("screening", "rejected"),
        (None, "screening"), ("screening", "withdrawn"),
        (None, "screening"), ("screening", "offered"), ("offered", "declined"),
        (None, "screening"), ("screening", "offered"), ("offered", "expired"),
    ]  # fmt: skip
    payload = session.execute(select(OUTBOX.c.payload).where(OUTBOX.c.type == "talent.application.moved.v1")).first()
    assert payload is not None and set(payload[0]) == {
        "application_id",
        "listing_id",
        "worker_id",
        "from_status",
        "to_status",
    }


def test_an_offer_expired_on_answer_is_announced_before_the_409(factory, session, worker):
    app = apply(session, make_listing(session).id, worker, ANSWERS, NOW)
    decide(session, app.id, OPS, "offer", None, 1, NOW)
    session.commit()
    with pytest.raises(Exception, match="expired"):
        answer_offer(session, app.id, worker, True, NOW + timedelta(days=2))
    session.rollback()
    with factory() as other:
        assert moves(other)[-1] == ("offered", "expired")


def test_the_paper_outcome_is_kept_and_a_last_failure_marks_the_step(session, worker):
    listing = make_listing(session, paper_id=uuid.uuid4(), cert_gate="transcription")
    app = apply(session, listing.id, worker, ANSWERS, NOW)
    session.commit()
    on_assess_failed(session, assess("failed", worker, score="0.25", attempts_left=1))
    session.commit()
    session.refresh(app)
    assert app.status == "assessment" and app.paper_result["status"] == "failed"
    assert app.steps[1] == {"kind": "paper", "status": "pending"}
    on_assess_failed(session, assess("failed", worker, score="0.5", attempts_left=0))
    session.commit()
    session.refresh(app)
    assert app.steps[1] == {"kind": "paper", "status": "failed"} and app.paper_result["attempts_left"] == 0
    on_assess_certified(session, assess("certified", worker, score="0.9"))
    session.commit()
    rows = listing_applications(session, listing.id, None, NOW)
    assert rows[0].status == "screening" and rows[0].steps[1].status == "done" and rows[0].paper is not None
    assert (rows[0].paper.status, str(rows[0].paper.score)) == ("passed", "0.9") and rows[0].paper.attempts_left is None
    assert ("assessment", "screening") in moves(session)


def test_hired_this_week_counts_recent_acceptances_per_listing(session):
    listing, quiet = make_listing(session, slots_total=5), make_listing(session)
    for _ in range(2):
        w = uuid.uuid4()
        app = apply(session, listing.id, w, ANSWERS, NOW)
        decide(session, app.id, OPS, "offer", None, 3, NOW)
        answer_offer(session, app.id, w, True, NOW)
    session.commit()
    assert hired_this_week(session, [listing.id, quiet.id], NOW + timedelta(days=1)) == {listing.id: 2}
    assert hired_this_week(session, [listing.id], NOW + timedelta(days=8)) == {}
    assert hired_this_week(session, [], NOW) == {}
