"""The notify operations. An event becomes one inbox row in the consumer's transaction (unique on the event id,
so a replay is a no-op). Email goes out afterwards from the row, by a separate pass, so a slow mail server never
holds an event back. A send that keeps failing stops after MAX_EMAIL_ATTEMPTS and the row says so.

Email goes only to a verified address: setting one makes it pending and the email pass mails it a six-digit code
(never stored: a keyed digest of a random nonce), which the worker types back within 15 minutes and five tries."""

import hmac
import json
import logging
import secrets
import smtplib
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol

from sqlalchemy import func, or_, select, update
from sqlalchemy.orm import Session

from yantra_common.errors import Conflict, Invalid, NotFound
from yantra_common.events import Envelope
from yantra_common.people import on_person_seen as person_handler
from yantra_common.pii import pii_hash
from yantra_contracts.events.v1 import (
    PayoutAccountRejected,
    PayoutAccountVerified,
    PayoutAdjustmentApproved,
    PayoutLineFailed,
    PayoutPaid,
    PayoutReconciliationDelta,
    QualityVerdictAccepted,
    QualityVerdictRejected,
    TalentApplicationDecided,
    WorkerErasureCompleted,
)
from yantra_notify.models import PERSON, Channel, Notification, Ticket

log = logging.getLogger("yantra.notify")
MAX_EMAIL_ATTEMPTS = 5
RETRY_AFTER = timedelta(seconds=30)  # doubles per attempt: 30 s, 1 min, 2 min, 4 min
PERMANENT = (smtplib.SMTPRecipientsRefused, smtplib.SMTPSenderRefused, smtplib.SMTPDataError)
VERIFY_FOR = timedelta(minutes=15)
VERIFY_ATTEMPTS = 5
CONTEXT_MAX_BYTES = 16 * 1024
CONTEXT_MAX_KEYS = 50
ERASED = "(erased)"
# the author of tickets the platform opens itself (a reconciliation that did not balance)
SYSTEM_AUTHOR = uuid.UUID("00000000-0000-4000-8000-00000000ffff")
ACCOUNT_REASONS = {
    "invalid_account": "the bank could not find that account number and IFSC",
    "name_mismatch": "the name on the account is not the name you gave",
    "rail_error": "the bank check could not be completed",
}


class Mailer(Protocol):
    def send(self, to: str, subject: str, body: str) -> None: ...


# ---------- channel and inbox ----------


def _clear_pending(channel: Channel) -> None:
    channel.pending_email = channel.verify_nonce = channel.verify_expires_at = None
    channel.verify_sent_at, channel.verify_error, channel.verify_attempts = None, None, 0


def set_channel(session: Session, worker_id: uuid.UUID, email: str | None, now: datetime | None = None) -> Channel:
    """`None` stops email at once. An address is pending until verified: a fresh code goes to it on the next email
    pass (asking again for the same address sends a new code). The verified address keeps receiving meanwhile;
    setting the verified address again changes nothing."""
    channel = session.get(Channel, worker_id, with_for_update=True)
    if channel is None:
        channel = Channel(worker_id=worker_id, verify_attempts=0)
        session.add(channel)
    if email is None:
        channel.email, channel.email_verified_at = None, None
        _clear_pending(channel)
    elif email != channel.email:
        _clear_pending(channel)
        channel.pending_email, channel.verify_nonce = email, secrets.token_hex(16)
        channel.verify_expires_at = (now or datetime.now(UTC)) + VERIFY_FOR
    else:
        _clear_pending(channel)
    session.flush()
    return channel


def verification_code(worker_id: uuid.UUID, email: str, nonce: str) -> str:
    """Six digits derived under `YANTRA_PII_KEY` from the nonce: what is mailed and what is checked, never stored."""
    digest = pii_hash(f"notify-email-verify:{worker_id}:{email}:{nonce}")
    return f"{int(digest[:12], 16) % 1_000_000:06d}"


def verify_channel(session: Session, worker_id: uuid.UUID, code: str, now: datetime | None = None) -> Channel:
    """The code mailed to the pending address makes it the verified one. A wrong code counts a try, kept even
    though the request fails (committed here: the request's unit of work rolls back on the 422)."""
    now = now or datetime.now(UTC)
    channel = session.get(Channel, worker_id, with_for_update=True)
    if channel is None or channel.pending_email is None or channel.verify_nonce is None:
        raise Conflict("no address is waiting for a code", worker_id=str(worker_id)).with_code("nothing_to_verify")
    if channel.verify_expires_at is None or channel.verify_expires_at <= now:
        raise Conflict("the code has expired; ask for a new one").with_code("code_expired")
    if channel.verify_attempts >= VERIFY_ATTEMPTS:
        raise Conflict("too many wrong codes; ask for a new one").with_code("too_many_attempts")
    expected = verification_code(worker_id, channel.pending_email, channel.verify_nonce)
    if not hmac.compare_digest(expected, code.strip()):
        channel.verify_attempts += 1
        left = VERIFY_ATTEMPTS - channel.verify_attempts
        session.commit()
        raise Invalid("that code is not the one we sent", attempts_left=left).with_code("wrong_code")
    channel.email, channel.email_verified_at = channel.pending_email, now
    _clear_pending(channel)
    session.flush()
    log.info("email verified worker_id=%s", worker_id)
    return channel


def send_verifications(session: Session, mailer: "Mailer", limit: int = 50, now: datetime | None = None) -> int:
    """Mail each pending address its code once, while the code is valid. A failed send is recorded on the channel
    (`verify_error`) and not retried: the worker asks for a new code."""
    now = now or datetime.now(UTC)
    channels = session.scalars(
        select(Channel)
        .where(
            Channel.pending_email.is_not(None),
            Channel.verify_nonce.is_not(None),
            Channel.verify_sent_at.is_(None),
            Channel.verify_error.is_(None),
            Channel.verify_expires_at > now,
        )
        .limit(limit)
        .with_for_update(skip_locked=True)
    ).all()
    sent = 0
    for c in channels:
        assert c.pending_email is not None and c.verify_nonce is not None  # the query's own condition
        code = verification_code(c.worker_id, c.pending_email, c.verify_nonce)
        try:
            mailer.send(
                c.pending_email,
                "Your Yantra email code",
                f"Your code is {code}. Type it in the app within 15 minutes to get your notifications by email. "
                "If you did not ask for this, ignore this email.",
            )
        except Exception as e:  # any failure: recorded on the row, the loop goes on
            c.verify_error = f"{type(e).__name__}"[:200]
            log.error("verification email failed worker_id=%s error=%s", c.worker_id, type(e).__name__)
            continue
        c.verify_sent_at = now
        sent += 1
    session.flush()
    return sent


def get_channel(session: Session, worker_id: uuid.UUID) -> Channel:
    channel = session.get(Channel, worker_id)
    if channel is None:
        raise NotFound("no channel set", worker_id=str(worker_id))
    return channel


def inbox(session: Session, worker_id: uuid.UUID, limit: int = 200) -> list[Notification]:
    q = select(Notification).where(Notification.worker_id == worker_id).order_by(Notification.created_at.desc())
    return list(session.scalars(q.limit(limit)))


def unread_count(session: Session, worker_id: uuid.UUID) -> int:
    """What the app's badge polls: one count on a partial index."""
    q = select(func.count()).select_from(Notification)
    return int(session.scalar(q.where(Notification.worker_id == worker_id, Notification.read_at.is_(None))) or 0)


def mark_read(session: Session, worker_id: uuid.UUID, notification_id: uuid.UUID) -> Notification:
    n = session.get(Notification, notification_id)
    if n is None or n.worker_id != worker_id:
        raise NotFound("notification not found", notification_id=str(notification_id))
    if n.read_at is None:
        n.read_at = datetime.now(UTC)
        session.flush()
    return n


# ---------- consumers ----------


def _notify(session: Session, env: Envelope, worker_id: uuid.UUID, kind: str, subject: str, body: str) -> None:
    session.add(Notification(worker_id=worker_id, event_id=env.id, kind=kind, subject=subject, body=body))
    session.flush()


def on_verdict_accepted(session: Session, env: Envelope) -> None:
    e = QualityVerdictAccepted.model_validate(env.data)
    _notify(
        session,
        env,
        e.worker_id,
        "verdict_accepted",
        "Your work was accepted",
        f"Unit {e.unit_id} passed review. The pay for it is in your statement.",
    )


def on_verdict_rejected(session: Session, env: Envelope) -> None:
    e = QualityVerdictRejected.model_validate(env.data)
    what = "needs edits" if e.verdict == "needs_edits" else "was rejected"
    body = f"Unit {e.unit_id} {what}. Reason: {e.reason_code}."
    if e.billable:
        body += " This was caused on the client's side; your time on it is billable rework."
    _notify(session, env, e.worker_id, f"verdict_{e.verdict}", f"Your work {what}", body)


def on_payout_paid(session: Session, env: Envelope) -> None:
    e = PayoutPaid.model_validate(env.data)
    _notify(
        session,
        env,
        e.worker_id,
        "payout_paid",
        f"Payout of {e.currency} {e.amount:.2f} sent",
        f"Your pay window was paid. Rail reference {e.rail_reference}.",
    )


def on_application_decided(session: Session, env: Envelope) -> None:
    """An offer or a rejection from talent: one inbox row either way, the offer naming when it expires."""
    e = TalentApplicationDecided.model_validate(env.data)
    if e.decision == "offer":
        until = f"before {e.offer_expires_at}" if e.offer_expires_at else "before it expires"
        _notify(
            session,
            env,
            e.worker_id,
            "application_offer",
            f"Offer: {e.listing_title}",
            f"You have an offer for {e.listing_title}. Accept or decline it in the app {until}.",
        )
        return
    _notify(
        session,
        env,
        e.worker_id,
        "application_rejected",
        f"Update on your application: {e.listing_title}",
        f"Your application to {e.listing_title} was not taken forward this time. Other pools stay open to you.",
    )


def on_adjustment_approved(session: Session, env: Envelope) -> None:
    e = PayoutAdjustmentApproved.model_validate(env.data)
    _notify(
        session,
        env,
        e.worker_id,
        "adjustment_approved",
        f"{e.kind.capitalize()} of {e.currency} {e.amount:.2f} approved",
        f"A {e.kind} of {e.currency} {e.amount:.2f} was added to your statement. It goes out with the next pay window.",
    )


on_person_seen = person_handler(PERSON)


def on_account_verified(session: Session, env: Envelope) -> None:
    e = PayoutAccountVerified.model_validate(env.data)
    _notify(
        session,
        env,
        e.worker_id,
        "bank_verified",
        "Bank account verified",
        f"Your bank account ending {e.account_last4} ({e.ifsc}) is set up for payouts.",
    )


def on_account_rejected(session: Session, env: Envelope) -> None:
    e = PayoutAccountRejected.model_validate(env.data)
    why = ACCOUNT_REASONS.get(e.reason, "the bank check did not pass")
    _notify(
        session,
        env,
        e.worker_id,
        "bank_rejected",
        "Bank account not verified",
        f"We could not verify your bank account: {why}. Check the details and add the account again in the app.",
    )


def on_line_failed(session: Session, env: Envelope) -> None:
    e = PayoutLineFailed.model_validate(env.data)
    what = "was sent back by your bank" if e.status == "returned" else "could not be delivered"
    _notify(
        session,
        env,
        e.worker_id,
        f"payout_{e.status}",
        f"Payout of {e.currency} {e.amount:.2f} {what}",
        f"Your payout of {e.currency} {e.amount:.2f} {what} ({e.reason}). Check your bank account in the app; "
        "the amount is not lost and goes out again once it is fixed.",
    )


def on_reconciliation_delta(session: Session, env: Envelope) -> None:
    """A reconciliation that did not balance becomes a payment ticket on the board, opened by the platform."""
    e = PayoutReconciliationDelta.model_validate(env.data)
    create_ticket(
        session,
        SYSTEM_AUTHOR,
        "payment",
        f"Reconciliation delta: window {str(e.window_id)[:8]}",
        f"Window {e.window_id} ({e.currency}) did not reconcile: lines delta {e.delta_lines}, rail delta "
        f"{e.delta_rail}, {e.failed_lines} failed and {e.processing_lines} processing lines. Nothing was adjusted.",
        "finance",
        e.model_dump(mode="json"),
    )


def on_erasure_completed(session: Session, env: Envelope) -> None:
    """The worker's data was erased: one last inbox row, then the email address goes (so the row is never mailed),
    and the free text of every ticket they raised (title, body, screen, context) is blanked; the ticket's category,
    status and the operator's note stay for the board's history."""
    e = WorkerErasureCompleted.model_validate(env.data)
    _notify(
        session,
        env,
        e.worker_id,
        "erasure_done",
        "Your personal data was erased",
        "Your name, contact details and documents were erased. Payment and tax records the law requires are kept.",
    )
    channel = session.get(Channel, e.worker_id)
    if channel is not None:
        channel.email, channel.email_verified_at = None, None
        _clear_pending(channel)
    session.execute(
        update(Ticket)
        .where(Ticket.author_id == e.worker_id)
        .values(title=ERASED, body=ERASED, context={}, screen=None)
        .execution_options(synchronize_session=False)
    )
    session.flush()


def attention(session: Session) -> dict[str, int]:
    rows = session.execute(select(Ticket.status, func.count()).group_by(Ticket.status))
    counts = {status: int(n) for status, n in rows}
    return {"tickets_open": counts.get("open", 0), "tickets_in_progress": counts.get("in_progress", 0)}


# ---------- support tickets ----------


def check_context(context: dict[str, Any]) -> None:
    """A ticket's context is a small bag of facts about the screen (build, platform, ids), not a file: at most 50
    top-level keys and 16 KB as JSON (422 `too_large`)."""
    size = len(json.dumps(context, separators=(",", ":"), default=str).encode())
    if len(context) > CONTEXT_MAX_KEYS or size > CONTEXT_MAX_BYTES:
        raise Invalid(
            f"context: at most {CONTEXT_MAX_KEYS} keys and {CONTEXT_MAX_BYTES} bytes", keys=len(context), bytes=size
        ).with_code("too_large")


def create_ticket(
    session: Session,
    author_id: uuid.UUID,
    category: str,
    title: str,
    body: str,
    screen: str | None,
    context: dict[str, Any] | None,
) -> Ticket:
    check_context(context or {})
    ticket = Ticket(
        author_id=author_id, category=category, title=title, body=body, screen=screen, context=context or {}
    )
    session.add(ticket)
    session.flush()
    session.refresh(ticket)
    return ticket


def my_tickets(session: Session, author_id: uuid.UUID, limit: int = 200) -> list[Ticket]:
    q = select(Ticket).where(Ticket.author_id == author_id).order_by(Ticket.created_at.desc(), Ticket.id.desc())
    return list(session.scalars(q.limit(limit)))


def list_tickets(session: Session, status: str | None = None, limit: int = 200) -> list[Ticket]:
    """The board for ops, newest first."""
    q = select(Ticket).order_by(Ticket.created_at.desc(), Ticket.id.desc()).limit(limit)
    if status is not None:
        q = q.where(Ticket.status == status)
    return list(session.scalars(q))


def set_ticket_status(
    session: Session, ticket_id: uuid.UUID, status: str, note: str | None, moved_by: uuid.UUID
) -> Ticket:
    """Ops move a ticket across the board, with an optional note that replaces the last one; the same column
    twice is a conflict so a stale board does not overwrite a newer note."""
    ticket = session.scalar(select(Ticket).where(Ticket.id == ticket_id).with_for_update())
    if ticket is None:
        raise NotFound("ticket not found", ticket_id=str(ticket_id))
    if ticket.status == status:
        raise Conflict("ticket is already in this status", ticket_id=str(ticket_id), status=status).with_code(
            "same_status"
        )
    log.info("ticket moved ticket_id=%s from=%s to=%s by=%s", ticket.id, ticket.status, status, moved_by)
    ticket.status = status
    if note is not None:
        ticket.note = note
    ticket.updated_at = func.now()  # the database's clock, like created_at
    session.flush()
    session.refresh(ticket)
    return ticket


# ---------- email delivery ----------


def deliver_pending(session: Session, mailer: Mailer, limit: int = 50, now: datetime | None = None) -> int:
    """Send the unsent notifications of workers who gave an email. One pass, bounded; returns how many went out.
    A transient failure is retried with a doubling delay until MAX_EMAIL_ATTEMPTS; a permanent refusal from the
    relay (bad address) and any unexpected error stop at once, recorded on the row so nothing fails quietly."""
    now = now or datetime.now(UTC)
    rows = session.execute(
        select(Notification, Channel.email)
        .join(Channel, Channel.worker_id == Notification.worker_id)
        .where(
            Notification.emailed_at.is_(None),
            Notification.email_error.is_(None),
            Channel.email.is_not(None),
            or_(Notification.next_attempt_at.is_(None), Notification.next_attempt_at <= now),
        )
        .order_by(Notification.created_at)
        .limit(limit)
        .with_for_update(of=Notification, skip_locked=True)
    ).all()
    sent = 0
    for n, email in rows:
        n.email_attempts += 1
        try:
            mailer.send(str(email), n.subject, n.body)
        except PERMANENT as e:
            n.email_error = f"{type(e).__name__}: refused by the relay"
            log.error("email refused notification_id=%s error=%s", n.id, type(e).__name__)
            continue
        except OSError as e:  # the relay is away: smtplib and socket errors
            if n.email_attempts >= MAX_EMAIL_ATTEMPTS:
                n.email_error = f"{type(e).__name__} after {n.email_attempts} attempts"
                log.error("email given up notification_id=%s error=%s", n.id, type(e).__name__)
            else:
                n.next_attempt_at = now + RETRY_AFTER * (2 ** (n.email_attempts - 1))
                log.warning(
                    "email failed notification_id=%s attempt=%d error=%s", n.id, n.email_attempts, e.__class__.__name__
                )
            continue
        except Exception as e:  # a bug in the mailer or a bad header: this row stops, the loop goes on
            n.email_error = f"{type(e).__name__}: {str(e)[:120]}"
            log.exception("email send crashed notification_id=%s", n.id)
            continue
        n.emailed_at = now
        sent += 1
    session.flush()
    return sent
