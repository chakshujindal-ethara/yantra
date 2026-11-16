"""The payout events in the inbox, the reconciliation ticket, erasure, the unread count, names and attention."""

import uuid
from datetime import UTC, datetime
from decimal import Decimal

from yantra_common.events import Envelope
from yantra_common.people import names_of
from yantra_notify.models import PERSON, Channel, Notification
from yantra_notify.service import (
    SYSTEM_AUTHOR,
    attention,
    create_ticket,
    inbox,
    list_tickets,
    mark_read,
    on_account_rejected,
    on_account_verified,
    on_erasure_completed,
    on_line_failed,
    on_person_seen,
    on_reconciliation_delta,
    set_channel,
    set_ticket_status,
    unread_count,
)
from yantra_notify.testing import verified_channel


def envelope(type_: str, data: dict) -> Envelope:
    return Envelope(id=uuid.uuid4(), type=type_, subject="t", occurred_at=datetime.now(UTC), data=data)


def test_bank_events_tell_the_worker_in_plain_words(session):
    worker = uuid.uuid4()
    on_account_verified(
        session,
        envelope(
            "payout.account.verified.v1",
            {
                "worker_id": str(worker),
                "account_name_hash": "x" * 64,
                "account_last4": "6789",
                "ifsc": "HDFC0001234",
                "verification": "penny_drop",
            },
        ),
    )
    for reason in ("name_mismatch", "something_new"):
        on_account_rejected(
            session, envelope("payout.account.rejected.v1", {"worker_id": str(worker), "reason": reason})
        )
    session.commit()
    rows = inbox(session, worker)
    assert [n.kind for n in rows] == ["bank_rejected", "bank_rejected", "bank_verified"]
    assert "6789" in rows[2].body and "HDFC0001234" in rows[2].body
    assert "not the name you gave" in rows[1].body and "did not pass" in rows[0].body


def test_a_failed_or_returned_line_says_what_happened(session):
    worker = uuid.uuid4()
    base = {
        "window_id": str(uuid.uuid4()),
        "line_id": str(uuid.uuid4()),
        "worker_id": str(worker),
        "amount": "250.5",
        "currency": "INR",
    }
    on_line_failed(
        session, envelope("payout.line.failed.v1", {**base, "status": "failed", "reason": "insufficient_funds"})
    )
    on_line_failed(
        session, envelope("payout.line.failed.v1", {**base, "status": "returned", "reason": "account_closed"})
    )
    session.commit()
    returned, failed = inbox(session, worker)
    assert failed.kind == "payout_failed" and failed.subject == "Payout of INR 250.50 could not be delivered"
    assert returned.kind == "payout_returned" and "sent back by your bank" in returned.subject
    assert "account_closed" in returned.body


def test_a_reconciliation_delta_opens_a_payment_ticket_from_the_platform(session):
    window = uuid.uuid4()
    on_reconciliation_delta(
        session,
        envelope(
            "payout.reconciliation.delta.v1",
            {
                "run_id": str(uuid.uuid4()),
                "window_id": str(window),
                "currency": "INR",
                "earnings_total": "100",
                "lines_total": "99",
                "paid_total": "99",
                "rail_total": "99",
                "delta_lines": "1",
                "delta_rail": "0",
                "failed_lines": 0,
                "processing_lines": 0,
            },
        ),
    )
    session.commit()
    [ticket] = list_tickets(session)
    assert ticket.author_id == SYSTEM_AUTHOR and ticket.category == "payment" and ticket.screen == "finance"
    assert ticket.title == f"Reconciliation delta: window {str(window)[:8]}"
    assert Decimal(ticket.context["delta_lines"]) == 1 and "Nothing was adjusted" in ticket.body


def test_erasure_leaves_a_last_inbox_row_drops_the_email_and_blanks_the_tickets(session):
    worker, stranger, other = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    set_channel(session, worker, "new@example.com")
    verified_channel(session, worker, "w@example.com")
    mine = create_ticket(
        session, worker, "account", "my phone is 98765", "call me at 98765", "me/profile", {"note": "x"}
    )
    set_ticket_status(session, mine.id, "in_progress", "called back", moved_by=uuid.uuid4())
    theirs = create_ticket(session, other, "bug", "crash", "it crashed", "work", {"build": "1"})
    on_erasure_completed(session, envelope("worker.erasure.completed.v1", {"worker_id": str(worker)}))
    on_erasure_completed(session, envelope("worker.erasure.completed.v1", {"worker_id": str(stranger)}))
    session.commit()
    channel = session.get(Channel, worker)
    assert (channel.email, channel.pending_email, channel.verify_nonce) == (None, None, None)
    assert [n.kind for n in inbox(session, worker)] == ["erasure_done"]
    session.refresh(mine)
    session.refresh(theirs)
    assert (mine.title, mine.body, mine.screen, mine.context) == ("(erased)", "(erased)", None, {})
    assert (mine.category, mine.status, mine.note) == ("account", "in_progress", "called back")
    assert (theirs.title, theirs.context) == ("crash", {"build": "1"})


def test_the_unread_count_moves_as_rows_are_read(session):
    worker = uuid.uuid4()
    assert unread_count(session, worker) == 0
    for reason in ("rail_error", "invalid_account"):
        on_account_rejected(
            session, envelope("payout.account.rejected.v1", {"worker_id": str(worker), "reason": reason})
        )
    session.commit()
    assert unread_count(session, worker) == 2
    mark_read(session, worker, inbox(session, worker)[0].id)
    assert unread_count(session, worker) == 1 and session.query(Notification).count() == 2


def test_names_are_kept_from_talent_and_ops_attention_counts_the_board(session):
    author = uuid.uuid4()
    on_person_seen(
        session, envelope("talent.person.seen.v1", {"id": str(author), "name": "Asha Rani", "kind": "worker"})
    )
    a = create_ticket(session, author, "bug", "t", "b", None, None)
    b = create_ticket(session, author, "other", "t", "b", None, None)
    set_ticket_status(session, b.id, "in_progress", None, moved_by=uuid.uuid4())
    session.commit()
    assert names_of(session, PERSON, [author])[author].name == "Asha Rani"
    assert attention(session) == {"tickets_open": 1, "tickets_in_progress": 1} and a.status == "open"
