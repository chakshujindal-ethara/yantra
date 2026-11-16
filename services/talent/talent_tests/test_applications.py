"""The application flow: apply (form validated, slots, one live application), the paper step through
`assess.certified.v1`, ops decide, the worker answers the offer, withdraw, expiry."""

import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest
from sqlalchemy import select

from yantra_common.errors import Conflict, Invalid, NotFound
from yantra_common.events import Envelope
from yantra_talent.consumers import on_assess_certified
from yantra_talent.models import OUTBOX, Application, WorkerGate
from yantra_talent.service import (
    answer_offer,
    apply,
    check_answers,
    decide,
    expire_due_offers,
    holds_gate,
    initial_state,
    listing_applications,
    my_applications,
    withdraw,
)
from yantra_talent.testing import grant_gate, make_listing

NOW = datetime.now(UTC)
ANSWERS = {"experience": "3 years", "shift": "day"}
OPS = uuid.uuid4()


def outbox(session) -> list[dict]:
    return [dict(r._mapping) for r in session.execute(select(OUTBOX).order_by(OUTBOX.c.occurred_at))]


def certified(session, worker, gate="transcription", paper_id=None):
    env = Envelope(
        id=uuid.uuid4(),
        type="assess.certified.v1",
        subject=str(worker),
        occurred_at=NOW,
        data={"worker_id": str(worker), "gate": gate, "paper_id": str(paper_id or uuid.uuid4()), "score": "0.9"},
    )
    on_assess_certified(session, env)
    session.commit()


def test_check_answers_names_the_key_that_fails():
    questions = [
        {"key": "exp", "prompt": "p", "kind": "text", "required": True},
        {"key": "shift", "prompt": "p", "kind": "choice", "options": ["day", "night"], "required": False},
    ]
    check_answers(questions, {"exp": "3"})
    check_answers(questions, {"exp": "3", "shift": "night"})
    with pytest.raises(Invalid) as e:
        check_answers(questions, {"exp": "  "})
    assert e.value.context["key"] == "exp" and "required" in e.value.message
    with pytest.raises(Invalid) as e:
        check_answers(questions, {})
    assert e.value.context["key"] == "exp"
    with pytest.raises(Invalid) as e:
        check_answers(questions, {"exp": "3", "shift": "noon"})
    assert e.value.context["key"] == "shift" and "options" in e.value.message
    with pytest.raises(Invalid) as e:
        check_answers(questions, {"exp": "3", "stray": 1})
    assert e.value.context["key"] == "stray"


def test_initial_state_depends_on_the_listing_steps_and_the_gate():
    with_paper = ["form", "paper", "availability"]
    assert initial_state(["form"], False) == ("screening", [{"kind": "form", "status": "done"}])
    assert initial_state(["form"], True) == ("screening", [{"kind": "form", "status": "done"}])
    assert initial_state(with_paper, False)[0] == "assessment"
    assert [s["status"] for s in initial_state(with_paper, False)[1]] == ["done", "pending", "done"]
    assert initial_state(["form", "paper"], False) == (
        "assessment",
        [{"kind": "form", "status": "done"}, {"kind": "paper", "status": "pending"}],
    )
    assert initial_state(with_paper, True) == (
        "screening",
        [
            {"kind": "form", "status": "done"},
            {"kind": "paper", "status": "done"},
            {"kind": "availability", "status": "done"},
        ],
    )


def test_apply_refuses_drafts_closed_full_and_duplicates(session, worker):
    draft = make_listing(session, status="draft")
    with pytest.raises(NotFound):
        apply(session, draft.id, worker, ANSWERS, NOW)
    with pytest.raises(NotFound):
        apply(session, uuid.uuid4(), worker, ANSWERS, NOW)
    closed = make_listing(session, closes_at=NOW - timedelta(seconds=1))
    with pytest.raises(Conflict) as e:
        apply(session, closed.id, worker, ANSWERS, NOW)
    assert e.value.code == "listing_closed"
    full = make_listing(session, slots_total=1, slots_filled=1)
    with pytest.raises(Conflict) as e:
        apply(session, full.id, worker, ANSWERS, NOW)
    assert e.value.code == "listing_full"
    listing = make_listing(session)
    with pytest.raises(Invalid) as e:
        apply(session, listing.id, worker, {}, NOW)
    assert e.value.context["key"] == "experience"
    first = apply(session, listing.id, worker, ANSWERS, NOW)
    session.commit()
    with pytest.raises(Conflict) as e:
        apply(session, listing.id, worker, ANSWERS, NOW)
    assert e.value.code == "already_applied" and e.value.context["application_id"] == str(first.id)
    withdraw(session, first.id, worker)
    session.commit()
    again = apply(session, listing.id, worker, ANSWERS, NOW)  # an ended application frees the slot for a new one
    session.commit()
    assert again.id != first.id and again.status == "screening" and again.answers == ANSWERS


def test_a_paper_listing_waits_for_the_certification(session, worker):
    paper = uuid.uuid4()
    listing = make_listing(session, paper_id=paper, cert_gate="transcription")
    other_gate = make_listing(session, paper_id=uuid.uuid4(), cert_gate="labelling")
    app = apply(session, listing.id, worker, ANSWERS, NOW)
    waiting = apply(session, other_gate.id, worker, ANSWERS, NOW)
    session.commit()
    assert app.status == "assessment" and [s["status"] for s in app.steps] == ["done", "pending", "done"]
    certified(session, worker, "transcription", paper)
    certified(session, uuid.uuid4(), "transcription")  # someone else's pass moves nothing of ours
    session.refresh(app)
    session.refresh(waiting)
    assert app.status == "screening" and [s["status"] for s in app.steps] == ["done", "done", "done"]
    assert waiting.status == "assessment"
    assert holds_gate(session, worker, "transcription") and not holds_gate(session, worker, None)
    gate = session.get(WorkerGate, (worker, "transcription"))
    assert gate.source == "assess" and gate.at == NOW
    certified(session, worker, "transcription", paper)  # a second pass is a harmless upsert
    assert len(session.scalars(select(WorkerGate)).all()) == 2
    prequalified = apply(session, make_listing(session, paper_id=paper).id, worker, ANSWERS, NOW)
    assert prequalified.status == "screening" and [s["status"] for s in prequalified.steps] == ["done", "done", "done"]


def test_decide_only_from_screening_and_announces_the_decision(session, listing, worker):
    app = apply(session, listing.id, worker, ANSWERS, NOW)
    session.commit()
    offered = decide(session, app.id, OPS, "offer", "welcome", 10, NOW)
    session.commit()
    assert offered.status == "offered" and offered.offer_expires_at == NOW + timedelta(days=10)
    assert offered.decided_by == OPS and offered.note == "welcome"
    with pytest.raises(Conflict) as e:
        decide(session, app.id, OPS, "reject", None, 7, NOW)
    assert e.value.code == "not_screening"
    with pytest.raises(NotFound):
        decide(session, uuid.uuid4(), OPS, "reject", None, 7, NOW)
    other = apply(session, listing.id, uuid.uuid4(), ANSWERS, NOW)
    rejected = decide(session, other.id, OPS, "reject", "no", 7, NOW)
    session.commit()
    assert rejected.status == "rejected" and rejected.offer_expires_at is None
    events = [e for e in outbox(session) if e["type"] == "talent.application.decided.v1"]
    assert len(events) == 2
    assert events[0]["payload"] == {
        "application_id": str(app.id),
        "listing_id": str(listing.id),
        "listing_title": listing.title,
        "worker_id": str(worker),
        "decision": "offer",
        "offer_expires_at": (NOW + timedelta(days=10)).isoformat(),
    }
    assert events[1]["payload"]["decision"] == "reject" and events[1]["payload"]["offer_expires_at"] is None


def offered(session, listing, worker, days=7):
    app = apply(session, listing.id, worker, ANSWERS, NOW)
    decide(session, app.id, OPS, "offer", None, days, NOW)
    session.commit()
    return app


def test_accept_fills_a_slot_opens_the_gate_without_a_paper_and_emits(session, worker):
    listing = make_listing(session, slots_total=1, cert_gate="transcription", paper_id=None)
    app = offered(session, listing, worker)
    rival = offered(session, listing, uuid.uuid4())
    accepted = answer_offer(session, app.id, worker, True, NOW)
    session.commit()
    session.refresh(listing)
    assert accepted.status == "accepted" and listing.slots_filled == 1
    assert session.get(WorkerGate, (worker, "transcription")).source == "offer"
    with pytest.raises(Conflict) as e:
        answer_offer(session, rival.id, rival.worker_id, True, NOW)
    assert e.value.code == "listing_full"
    session.rollback()
    with pytest.raises(Conflict) as e:
        answer_offer(session, app.id, worker, True, NOW)
    assert e.value.code == "not_offered"
    with pytest.raises(NotFound):
        answer_offer(session, app.id, uuid.uuid4(), True, NOW)  # not theirs
    with pytest.raises(Conflict) as e:
        apply(session, listing.id, uuid.uuid4(), ANSWERS, NOW)
    assert e.value.code == "listing_full"
    accepted_events = [e for e in outbox(session) if e["type"] == "talent.offer.accepted.v1"]
    assert len(accepted_events) == 1 and accepted_events[0]["payload"] == {
        "application_id": str(app.id),
        "listing_id": str(listing.id),
        "worker_id": str(worker),
        "gate": "transcription",
    }


def test_accept_on_a_paper_listing_grants_no_gate_and_decline_ends_it(session, worker):
    listing = make_listing(session, paper_id=uuid.uuid4(), cert_gate="transcription")
    grant_gate(session, worker, "transcription")
    app = offered(session, listing, worker)
    answer_offer(session, app.id, worker, True, NOW)
    session.commit()
    assert [e["payload"]["gate"] for e in outbox(session) if e["type"] == "talent.offer.accepted.v1"] == [None]
    assert session.get(WorkerGate, (worker, "transcription")).source == "assess"  # untouched
    decliner = uuid.uuid4()
    grant_gate(session, decliner, "transcription")
    declined = answer_offer(session, offered(session, listing, decliner).id, decliner, False, NOW)
    session.commit()
    session.refresh(listing)
    assert declined.status == "declined" and listing.slots_filled == 1


def test_an_offer_past_its_expiry_is_marked_expired_and_refused(factory, session, worker):
    listing = make_listing(session)
    app = offered(session, listing, worker, days=1)
    with pytest.raises(Conflict) as e:
        answer_offer(session, app.id, worker, True, NOW + timedelta(days=1))
    assert e.value.code == "offer_expired"
    session.rollback()
    with factory() as other:
        assert other.get(Application, app.id).status == "expired"  # the expiry survived the 409
    with pytest.raises(Conflict) as e:
        answer_offer(session, app.id, worker, False, NOW + timedelta(days=2))
    assert e.value.code == "offer_expired"
    assert apply(session, listing.id, worker, ANSWERS, NOW).status == "screening"  # may apply again


def test_reads_expire_due_offers_and_carry_the_listing_title(session, worker):
    listing = make_listing(session, title="Hindi")
    due = offered(session, listing, worker, days=1)
    fresh = offered(session, make_listing(session, title="Tamil"), worker, days=5)
    later = NOW + timedelta(days=2)
    mine = my_applications(session, worker, later)
    assert [(a.id, a.status, a.listing_title) for a in mine] == [
        (fresh.id, "offered", "Tamil"),
        (due.id, "expired", "Hindi"),
    ]
    assert mine[0].steps[0].model_dump() == {"kind": "form", "status": "done"} and mine[0].worker_id == worker
    assert expire_due_offers(session, later) == 0
    assert [a.status for a in listing_applications(session, listing.id, None, NOW)] == ["expired"]
    assert listing_applications(session, listing.id, "offered", NOW) == []
    with pytest.raises(NotFound):
        listing_applications(session, uuid.uuid4(), None, NOW)
    assert my_applications(session, uuid.uuid4(), NOW) == []


def test_withdraw_from_assessment_screening_or_offered_only(session, worker):
    screening = apply(session, make_listing(session).id, worker, ANSWERS, NOW)
    assessment = apply(session, make_listing(session, paper_id=uuid.uuid4()).id, worker, ANSWERS, NOW)
    offer = offered(session, make_listing(session), worker)
    for app in (screening, assessment, offer):
        assert withdraw(session, app.id, worker).status == "withdrawn"
    session.commit()
    with pytest.raises(Conflict) as e:
        withdraw(session, screening.id, worker)
    assert e.value.code == "not_withdrawable"
    with pytest.raises(NotFound):
        withdraw(session, screening.id, uuid.uuid4())
    assert Decimal(str(make_listing(session).pay_min)) == Decimal("20")
