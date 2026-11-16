import smtplib
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from yantra_common.consumer import handle_in_transaction
from yantra_common.errors import Conflict, NotFound
from yantra_common.events import Envelope
from yantra_notify.models import CONSUMED, Notification
from yantra_notify.service import (
    MAX_EMAIL_ATTEMPTS,
    create_ticket,
    deliver_pending,
    inbox,
    list_tickets,
    mark_read,
    my_tickets,
    on_adjustment_approved,
    on_application_decided,
    on_payout_paid,
    on_verdict_accepted,
    on_verdict_rejected,
    set_channel,
    set_ticket_status,
)
from yantra_notify.testing import FakeMailer, verified_channel


def envelope(type_: str, data: dict) -> Envelope:
    return Envelope(id=uuid.uuid4(), type=type_, subject="t", occurred_at=datetime.now(UTC), data=data)


def verdict(worker: uuid.UUID, **extra) -> dict:
    return {
        "unit_id": str(uuid.uuid4()),
        "batch_id": str(uuid.uuid4()),
        "submission_id": str(uuid.uuid4()),
        "worker_id": str(worker),
        "reviewer_id": str(uuid.uuid4()),
        "auditor_id": None,
        "rubric_version": "v1",
        **extra,
    }


def test_each_event_becomes_one_inbox_row_for_its_worker(session):
    worker, other = uuid.uuid4(), uuid.uuid4()
    on_verdict_accepted(session, envelope("quality.verdict.accepted.v1", verdict(worker)))
    rejected = verdict(worker, verdict="needs_edits", reason_code="client_glossary_change", billable=True)
    on_verdict_rejected(session, envelope("quality.verdict.rejected.v1", rejected))
    paid = {"window_id": str(uuid.uuid4()), "worker_id": str(worker), "amount": "123.5", "currency": "INR"}
    on_payout_paid(session, envelope("payout.paid.v1", {**paid, "rail_reference": "RZP-1"}))
    on_verdict_accepted(session, envelope("quality.verdict.accepted.v1", verdict(other)))
    session.commit()
    rows = inbox(session, worker)
    assert [n.kind for n in rows] == ["payout_paid", "verdict_needs_edits", "verdict_accepted"]
    assert rows[0].subject == "Payout of INR 123.50 sent" and "RZP-1" in rows[0].body
    assert "billable rework" in rows[1].body and rows[1].subject == "Your work needs edits"
    assert len(inbox(session, other)) == 1 and all(n.read_at is None for n in rows)


def test_a_replayed_event_is_a_no_op_and_reading_is_the_workers_own(factory, session):
    worker = uuid.uuid4()
    env = envelope("quality.verdict.accepted.v1", verdict(worker))
    assert handle_in_transaction(factory, CONSUMED, on_verdict_accepted, env) is True
    assert handle_in_transaction(factory, CONSUMED, on_verdict_accepted, env) is False
    [n] = inbox(session, worker)
    assert mark_read(session, worker, n.id).read_at is not None
    assert mark_read(session, worker, n.id).read_at == session.get(Notification, n.id).read_at
    with pytest.raises(NotFound):
        mark_read(session, uuid.uuid4(), n.id)
    with pytest.raises(NotFound):
        mark_read(session, worker, uuid.uuid4())


def test_email_goes_only_to_workers_with_a_channel_and_retries_a_failing_relay_with_backoff(session):
    with_email, silent = uuid.uuid4(), uuid.uuid4()
    verified_channel(session, with_email, "w@example.test")
    assert verified_channel(session, with_email, "w2@example.test").email == "w2@example.test"
    on_verdict_accepted(session, envelope("quality.verdict.accepted.v1", verdict(with_email)))
    on_verdict_accepted(session, envelope("quality.verdict.accepted.v1", verdict(silent)))
    session.commit()
    mailer = FakeMailer()
    mailer.failing = True
    t0 = datetime.now(UTC)
    assert deliver_pending(session, mailer, now=t0) == 0
    assert deliver_pending(session, mailer, now=t0 + timedelta(seconds=5)) == 0  # inside the backoff: not retried
    [n] = inbox(session, with_email)
    assert n.email_attempts == 1 and n.next_attempt_at == t0 + timedelta(seconds=30)
    clock = t0 + timedelta(seconds=30)
    assert deliver_pending(session, mailer, now=clock) == 0
    assert n.email_attempts == 2 and n.next_attempt_at == clock + timedelta(seconds=60)  # doubled
    for attempt in range(3, MAX_EMAIL_ATTEMPTS):
        clock += timedelta(seconds=30 * 2 ** (attempt - 2))
        assert deliver_pending(session, mailer, now=clock) == 0
    mailer.failing = False
    clock += timedelta(hours=1)
    assert deliver_pending(session, mailer, now=clock) == 1 and deliver_pending(session, mailer, now=clock) == 0
    assert mailer.sent == [("w2@example.test", "Your work was accepted", mailer.sent[0][2])]
    [n] = inbox(session, with_email)
    assert n.emailed_at is not None and n.email_attempts == MAX_EMAIL_ATTEMPTS and n.email_error is None
    assert inbox(session, silent)[0].emailed_at is None


def test_a_relay_that_never_answers_gives_up_with_a_record(session, caplog):
    worker = uuid.uuid4()
    verified_channel(session, worker, "w@example.test")
    on_verdict_accepted(session, envelope("quality.verdict.accepted.v1", verdict(worker)))
    session.commit()
    mailer = FakeMailer()
    mailer.failing = True
    clock = datetime.now(UTC)
    for _ in range(MAX_EMAIL_ATTEMPTS + 1):
        deliver_pending(session, mailer, now=clock)
        clock += timedelta(hours=1)
    [n] = session.scalars(select(Notification)).all()
    assert n.email_attempts == MAX_EMAIL_ATTEMPTS and n.email_error.startswith("ConnectionRefusedError")
    assert "email given up" in caplog.text
    # a channel removed later: nothing more is attempted
    set_channel(session, worker, None)
    assert deliver_pending(session, mailer) == 0


def test_a_permanent_refusal_and_a_mailer_bug_stop_that_row_only(session, caplog):
    bad, buggy, fine = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    for w in (bad, buggy, fine):
        verified_channel(session, w, f"{w}@example.test")
        on_verdict_accepted(session, envelope("quality.verdict.accepted.v1", verdict(w)))
    session.commit()

    class Picky(FakeMailer):
        def send(self, to: str, subject: str, body: str) -> None:
            if to.startswith(str(bad)):
                raise smtplib.SMTPRecipientsRefused({to: (550, b"no such user")})
            if to.startswith(str(buggy)):
                raise ValueError("header injection")
            super().send(to, subject, body)

    mailer = Picky()
    assert deliver_pending(session, mailer) == 1 and deliver_pending(session, mailer) == 0
    rows = {n.worker_id: n for n in session.scalars(select(Notification))}
    assert rows[bad].email_error.startswith("SMTPRecipientsRefused") and rows[bad].email_attempts == 1
    assert rows[buggy].email_error.startswith("ValueError") and "email send crashed" in caplog.text
    assert rows[fine].emailed_at is not None and len(mailer.sent) == 1


def test_a_worker_without_a_channel_gets_no_email_even_with_a_working_relay(session):
    worker = uuid.uuid4()
    verified_channel(session, worker, "w@example.test")
    set_channel(session, worker, None)
    on_verdict_accepted(session, envelope("quality.verdict.accepted.v1", verdict(worker)))
    session.commit()
    mailer = FakeMailer()
    assert deliver_pending(session, mailer) == 0 and mailer.sent == []


def test_a_reject_is_worded_as_a_rejection_and_is_not_billable(session):
    worker = uuid.uuid4()
    rejected = verdict(worker, verdict="reject", reason_code="low_quality", billable=False)
    on_verdict_rejected(session, envelope("quality.verdict.rejected.v1", rejected))
    session.commit()
    [n] = inbox(session, worker)
    assert n.kind == "verdict_reject" and n.subject == "Your work was rejected" and "billable" not in n.body


# ---------- the two new consumers ----------


def decided(worker: uuid.UUID, decision: str, expires: str | None = None) -> dict:
    return {
        "application_id": str(uuid.uuid4()),
        "listing_id": str(uuid.uuid4()),
        "listing_title": "Hindi transcription pool",
        "worker_id": str(worker),
        "decision": decision,
        "offer_expires_at": expires,
    }


def test_an_application_decision_becomes_an_offer_or_a_rejection_in_the_inbox(session):
    worker = uuid.uuid4()
    on_application_decided(
        session, envelope("talent.application.decided.v1", decided(worker, "offer", "2026-11-10T09:00:00+00:00"))
    )
    on_application_decided(session, envelope("talent.application.decided.v1", decided(worker, "reject")))
    on_application_decided(session, envelope("talent.application.decided.v1", decided(worker, "offer")))
    session.commit()
    no_expiry, rejected, offer = inbox(session, worker)
    assert offer.kind == "application_offer" and offer.subject == "Offer: Hindi transcription pool"
    assert "2026-11-10T09:00:00+00:00" in offer.body and "Hindi transcription pool" in offer.body
    assert rejected.kind == "application_rejected" and "Hindi transcription pool" in rejected.subject
    assert "not taken forward" in rejected.body
    assert no_expiry.kind == "application_offer" and "before it expires" in no_expiry.body


def test_an_approved_adjustment_tells_the_worker_what_was_added(factory, session):
    worker = uuid.uuid4()
    data = {
        "adjustment_id": str(uuid.uuid4()),
        "worker_id": str(worker),
        "amount": "150.5",
        "currency": "INR",
        "kind": "bonus",
    }
    env = envelope("payout.adjustment.approved.v1", data)
    assert handle_in_transaction(factory, CONSUMED, on_adjustment_approved, env) is True
    [n] = inbox(session, worker)
    assert n.kind == "adjustment_approved" and n.subject == "Bonus of INR 150.50 approved"
    assert "150.50" in n.body and "next pay window" in n.body and n.event_id == env.id
    assert handle_in_transaction(factory, CONSUMED, on_adjustment_approved, env) is False  # a replay is a no-op
    assert len(inbox(session, worker)) == 1
    on_adjustment_approved(session, envelope("payout.adjustment.approved.v1", {**data, "kind": "correction"}))
    session.commit()
    assert inbox(session, worker)[0].subject == "Correction of INR 150.50 approved"


# ---------- support tickets ----------


def test_a_ticket_is_the_authors_until_ops_move_it_and_the_same_status_twice_is_a_conflict(session):
    worker, other, ops = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    first = create_ticket(
        session, worker, "bug", "Claim button dead", "Nothing happens", "work/claim", {"build": "1.2"}
    )
    session.commit()
    second = create_ticket(session, other, "payment", "Missing payout", "Window 42", None, None)
    session.commit()
    assert first.status == "open" and first.screen == "work/claim" and first.context == {"build": "1.2"}
    assert second.screen is None and second.context == {} and second.note is None
    assert [t.id for t in my_tickets(session, worker)] == [first.id]
    assert [t.id for t in list_tickets(session)] == [second.id, first.id]
    moved = set_ticket_status(session, first.id, "in_progress", "looking", ops)
    session.commit()
    assert moved.status == "in_progress" and moved.note == "looking" and moved.updated_at >= moved.created_at
    with pytest.raises(Conflict) as e:
        set_ticket_status(session, first.id, "in_progress", None, ops)
    assert e.value.code == "same_status"
    session.rollback()
    with pytest.raises(NotFound):
        set_ticket_status(session, uuid.uuid4(), "resolved", None, ops)
    resolved = set_ticket_status(session, first.id, "resolved", None, ops)
    session.commit()
    assert resolved.status == "resolved" and resolved.note == "looking"  # a missing note keeps the last one
    assert [t.id for t in list_tickets(session, "open")] == [second.id]
    assert [t.id for t in list_tickets(session, "resolved")] == [first.id]
    assert list_tickets(session, "in_progress") == []
