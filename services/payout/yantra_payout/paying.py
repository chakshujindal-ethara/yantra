"""Paying an approved window, line by line, on a rail.

    approved --pay--> paying: every payable line is queued; each attempt is `<line>:<attempt>`, the rail's
        reference and idempotency key at once (over the per-window cap only with finance's recorded override)
    dispatch job: queued -> processing (committed first) -> rail call -> reference recorded; a line whose worker
        is on a live hold, or that belongs to another rail, stays queued and says why (`rail_status`)
    poll job / webhook / bank return file: processing -> paid | failed | returned; paid -> returned when the bank
        sends a paid payout back (its earnings are owed again)
    finance: a failed or returned line is retried (a new attempt) or released (its earnings roll to the next close)
    the window is paid when no line is still payable, in flight, failed or returned

Settling is attempt-scoped and rank-ordered: news about another attempt's payout is ignored, a late `queued` or
`processing` never overwrites a settled line, and settling the same outcome twice is a no-op, so webhook order and
redelivery do not matter. Reconciliation compares earnings, lines, paid lines and what the rail reported, writes a
run, and never adjusts. Every CSV cell this module writes is defused against spreadsheet formulas."""

import csv
import hashlib
import hmac
import io
import json
import logging
import uuid
from collections.abc import Iterable
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Any

from sqlalchemy import func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from yantra_common.db import unit_of_work
from yantra_common.errors import Conflict, DomainError, Invalid, NotFound, Unauthorized
from yantra_common.outbox import emit
from yantra_contracts.events.v1 import PayoutLineFailed, PayoutPaid, PayoutReconciliationDelta
from yantra_payout.accounts import (
    awaiting_confirmation,
    complete_validation,
    erase_if_requested,
    number_of,
    verified_fund_account,
)
from yantra_payout.models import (
    OUTBOX,
    BankAccount,
    Earning,
    PayWindow,
    ReconciliationRun,
    WebhookEvent,
    WindowLine,
    WorkerAccount,
)
from yantra_payout.rails import PayoutRequest, PayoutResult, Rail, RailError, RailUnavailable, RailUnknownOutcome
from yantra_payout.rails.razorpayx import payout_of, validation_of
from yantra_payout.service import money, window_lock

log = logging.getLogger("yantra.payout.paying")
ZERO = Decimal("0")
SETTLED = ("paid", "failed", "returned", "released")
RANK = {"payable": 0, "queued": 1, "processing": 2, "paid": 3, "failed": 3, "returned": 3, "released": 3}
OPEN = ("payable", "queued", "processing", "failed", "returned")
POLL_AFTER = timedelta(minutes=2)
RECONCILE_DAYS = 90
MAX_ATTEMPTS = 999  # `<line uuid>:<attempt>` stays within RazorpayX's 40-character reference_id
# why a queued line is not going out: the worker is held, it belongs to another rail, its account is gone or changed
BLOCKED = ("held", "rail_mismatch", "account_missing", "account_changed")
FORMULA_START = ("=", "+", "-", "@", "\t", "\r")


def _window(session: Session, window_id: uuid.UUID, lock: bool = True) -> PayWindow:
    stmt = select(PayWindow).where(PayWindow.id == window_id)
    window = session.scalar(stmt.with_for_update() if lock else stmt)
    if window is None:
        raise NotFound("window not found", window_id=str(window_id))
    return window


def _line(session: Session, window_id: uuid.UUID, line_id: uuid.UUID) -> WindowLine:
    line = session.scalar(
        select(WindowLine).where(WindowLine.id == line_id, WindowLine.window_id == window_id).with_for_update()
    )
    if line is None:
        raise NotFound("line not found", window_id=str(window_id), line_id=str(line_id))
    return line


def reference_id(line: WindowLine) -> str:
    """The current attempt as the rail knows it: its `reference_id` and its idempotency key."""
    return f"{line.id}:{line.attempts}"


def _queue(line: WindowLine, rail: str) -> None:
    line.attempts += 1
    line.status, line.rail = "queued", rail
    line.idempotency_key = reference_id(line)
    line.rail_reference = line.rail_status = line.utr = line.failure_reason = line.paid_account_hash = None
    line.rail_amount = line.submitted_at = line.settled_at = None


def live_hold(session: Session, worker_id: uuid.UUID, now: datetime) -> str | None:
    """Why the worker's payouts are held now, if they are: a live hold (integrity, bank change, by hand), or
    withdrawn consent."""
    account = session.get(WorkerAccount, worker_id) or WorkerAccount(worker_id=worker_id, consent_withdrawn=False)
    if account.hold_until is not None and account.hold_until > now:
        return account.hold_reason or "integrity"
    return "consent_withdrawn" if account.consent_withdrawn else None


def _held_workers(now: datetime) -> Any:
    return select(WorkerAccount.worker_id).where(
        or_(WorkerAccount.hold_until > now, WorkerAccount.consent_withdrawn.is_(True))
    )


def csv_cell(value: object) -> str:
    """A CSV cell a spreadsheet will not run: text starting like a formula is quoted with a leading apostrophe."""
    text = str(value)
    return "'" + text if text.startswith(FORMULA_START) else text


def _csv_row(writer: Any, values: Iterable[object]) -> None:
    writer.writerow([csv_cell(v) for v in values])


# ---------- finance actions ----------


def pay_window(
    session: Session,
    window_id: uuid.UUID,
    rail: str,
    max_per_window: Decimal,
    now: datetime | None = None,
    override_by: uuid.UUID | None = None,
    override_reason: str | None = None,
) -> PayWindow:
    """Release an approved window to the rail: every payable line is queued. Nothing is sent in this request. A
    window over the per-window cap is refused (409 `window_over_cap`) unless finance overrides the cap with a
    reason; who, why and when are recorded on the window."""
    now = now or datetime.now(UTC)
    window = _window(session, window_id)
    if window.status != "approved":
        raise Conflict("window is not approved", window_id=str(window_id), status=window.status)
    lines = list(
        session.scalars(select(WindowLine).where(WindowLine.window_id == window_id, WindowLine.status == "payable"))
    )
    total = sum((line.gross for line in lines), ZERO)
    if total > max_per_window:
        if override_by is None:
            raise Conflict(
                "the window is over the per-window cap", total=str(total), cap=str(max_per_window)
            ).with_code("window_over_cap")
        reason = (override_reason or "").strip()
        if not reason:
            raise Invalid("overriding the per-window cap needs a reason")
        window.cap_override_by, window.cap_override_reason, window.cap_override_at = override_by, reason, now
        log.warning(
            "window paid over the cap window_id=%s total=%s cap=%s by=%s", window.id, total, max_per_window, override_by
        )
    for line in lines:
        _queue(line, rail)
    window.status, window.rail = "paying", rail
    window.rail_reference = f"{rail}:{window.id.hex[:8]}"
    session.flush()
    maybe_finish_window(session, window, now)
    return window


def retry_line(
    session: Session, window_id: uuid.UUID, line_id: uuid.UUID, rail: str, now: datetime | None = None
) -> WindowLine:
    """A failed or returned line goes back on the rail as a new attempt: on the rail it was paid on (the one
    running), with the worker off any hold and their account verified."""
    now = now or datetime.now(UTC)
    window = _window(session, window_id)
    line = _line(session, window_id, line_id)
    if line.status not in ("failed", "returned"):
        raise Conflict("only a failed or returned line can be retried", status=line.status).with_code("line_not_failed")
    if (line.rail or window.rail) != rail:
        raise Conflict("this line was paid on another rail", line_rail=line.rail, rail=rail).with_code("rail_mismatch")
    if line.attempts >= MAX_ATTEMPTS:
        raise Conflict("this line was tried too often; release it", attempts=line.attempts).with_code(
            "too_many_attempts"
        )
    held = live_hold(session, line.worker_id, now)
    if held is not None:
        raise Conflict("the worker's payouts are on hold", hold_reason=held).with_code("worker_held")
    if verified_fund_account(session, line.worker_id) is None:
        raise Conflict("the worker's bank account is not verified").with_code("account_unverified")
    _queue(line, rail)
    session.flush()
    return line


def release_line(session: Session, window_id: uuid.UUID, line_id: uuid.UUID, now: datetime | None = None) -> WindowLine:
    """A failed or returned line leaves the window: its earnings are payable again and roll into the next close.
    The window's totals move with it, so the Odoo bills still compare like with like."""
    now = now or datetime.now(UTC)
    window = _window(session, window_id)
    window_lock(session, window.currency)  # a close in this currency never sees these earnings half-moved
    line = _line(session, window_id, line_id)
    if line.status not in ("failed", "returned"):
        raise Conflict("only a failed or returned line can be released", status=line.status).with_code(
            "line_not_failed"
        )
    for earning in session.scalars(
        select(Earning).where(
            Earning.window_id == window_id, Earning.worker_id == line.worker_id, Earning.status == "windowed"
        )
    ):
        earning.status, earning.window_id = "payable", None
    line.status, line.settled_at = "released", now
    window.gross_total -= line.gross
    window.held_total += line.gross
    session.flush()
    maybe_finish_window(session, window, now)
    erase_if_requested(session, line.worker_id)
    return line


def maybe_finish_window(session: Session, window: PayWindow, now: datetime) -> None:
    if window.status != "paying":
        return
    still_open = session.scalar(
        select(func.count())
        .select_from(WindowLine)
        .where(WindowLine.window_id == window.id, WindowLine.status.in_(OPEN))
    )
    if not still_open:
        window.status, window.paid_at = "paid", now
        session.flush()


# ---------- settling a line ----------


def for_this_attempt(line: WindowLine, result: PayoutResult) -> bool:
    """Whether a rail outcome is about the payout the line's current attempt sent: the payout the line already
    references, or, before the rail named one, the current `<line>:<attempt>`. Anything else is news about an
    earlier attempt, which must never fail (or pay) the attempt being paid now."""
    if line.rail_reference is not None:
        return result.reference == line.rail_reference
    return result.reference_id == reference_id(line)


def _with_reference_id(result: PayoutResult, attempt: str) -> PayoutResult:
    """A rail answer to a request we sent is about that request's attempt, whether or not the rail echoed it."""
    return result if result.reference_id else replace(result, reference_id=attempt)


def settle_line(session: Session, line: WindowLine, result: PayoutResult, now: datetime | None = None) -> bool:
    """Apply a rail outcome to a locked line. Returns True when the line changed state."""
    now = now or datetime.now(UTC)
    if not for_this_attempt(line, result):
        log.info("payout outcome for another attempt ignored line_id=%s status=%s", line.id, result.status)
        return False
    if result.reference and line.rail_reference is None:
        line.rail_reference = result.reference
    line.rail_status = result.status
    if line.status == "paid" and result.status == "returned":
        _reverse(session, line, result, now)
        return True
    if line.status in SETTLED:
        if result.status == "paid" and line.status != "paid":
            # money reached the worker on a line finance may already have retried or released: look at it now
            log.error("payout reported paid on a %s line line_id=%s window_id=%s", line.status, line.id, line.window_id)
        return False
    if RANK[result.status] <= RANK[line.status]:
        return False
    window = session.get(PayWindow, line.window_id)
    assert window is not None
    line.status = result.status
    if result.status in ("queued", "processing"):
        session.flush()
        return True
    line.settled_at = now
    if result.status == "paid":
        line.utr, line.rail_amount = result.utr, line.gross if result.amount is None else result.amount
        for earning in session.scalars(
            select(Earning).where(
                Earning.window_id == line.window_id, Earning.worker_id == line.worker_id, Earning.status == "windowed"
            )
        ):
            earning.status = "paid"
        holder = session.get(WorkerAccount, line.worker_id)
        if holder is not None and holder.first_paid_at is None:
            holder.first_paid_at = now
        window.paid_total += line.gross
        emit(
            session,
            OUTBOX,
            f"window/{window.id}",
            PayoutPaid(
                window_id=window.id,
                worker_id=line.worker_id,
                amount=line.gross,
                currency=window.currency,
                rail_reference=line.rail_reference or window.rail_reference or "",
                line_id=line.id,
                utr=line.utr,
            ),
        )
    else:
        line.failure_reason = result.reason or result.status
        emit(
            session,
            OUTBOX,
            f"window/{window.id}",
            PayoutLineFailed(
                window_id=window.id,
                line_id=line.id,
                worker_id=line.worker_id,
                amount=line.gross,
                currency=window.currency,
                status="failed" if result.status == "failed" else "returned",
                reason=line.failure_reason,
            ),
        )
        log.warning(
            "payout line not delivered line_id=%s status=%s reason=%s", line.id, line.status, line.failure_reason
        )
    session.flush()
    maybe_finish_window(session, window, now)
    if line.status == "paid":
        erase_if_requested(session, line.worker_id)
    return True


def _reverse(session: Session, line: WindowLine, result: PayoutResult, now: datetime) -> None:
    """The bank sent back a payout it had reported paid: the line is returned, its earnings are owed again
    (windowed), the window's paid total drops by it, and finance sees it (a failed line on the attention list, a
    delta on the window's reconciliation, `payout.line.failed.v1`) to retry or release it."""
    window = session.get(PayWindow, line.window_id)
    assert window is not None
    line.status, line.settled_at, line.utr = "returned", now, None
    line.failure_reason = result.reason or "reversed"
    for earning in session.scalars(
        select(Earning).where(
            Earning.window_id == line.window_id, Earning.worker_id == line.worker_id, Earning.status == "paid"
        )
    ):
        earning.status = "windowed"
    window.paid_total -= line.gross
    emit(
        session,
        OUTBOX,
        f"window/{window.id}",
        PayoutLineFailed(
            window_id=window.id,
            line_id=line.id,
            worker_id=line.worker_id,
            amount=line.gross,
            currency=window.currency,
            status="returned",
            reason=line.failure_reason,
        ),
    )
    log.error("payout reversed after it was paid line_id=%s window_id=%s", line.id, line.window_id)
    session.flush()


def _locked_line(session: Session, line_id: uuid.UUID) -> WindowLine | None:
    return session.scalar(select(WindowLine).where(WindowLine.id == line_id).with_for_update())


# ---------- the jobs ----------


def _mark_blocked(session: Session, rail: str, now: datetime) -> None:
    """Queued lines this run will not send say why: the worker is on a live hold, or the line is on another rail."""
    queued = WindowLine.status == "queued"
    for reason, which in (
        ("rail_mismatch", WindowLine.rail != rail),
        ("held", (WindowLine.rail == rail) & WindowLine.worker_id.in_(_held_workers(now))),
    ):
        session.execute(
            update(WindowLine)
            .where(queued, which, WindowLine.rail_status.is_distinct_from(reason))
            .values(rail_status=reason)
            .execution_options(synchronize_session=False)
        )


def _request(line: WindowLine, window: PayWindow, account: BankAccount) -> PayoutRequest:
    assert account.rail_fund_account_id is not None
    return PayoutRequest(
        line_id=line.id,
        attempt=line.attempts,
        fund_account_id=account.rail_fund_account_id,
        amount=line.gross,
        currency=window.currency,
        narration=f"Yantra {window.ends_at.astimezone(UTC):%d %b %Y}",
    )


def dispatch_queued(factory: sessionmaker[Session], rail: Rail, now: datetime | None = None, limit: int = 20) -> int:
    """Send queued lines on this rail whose worker is not held. The line is marked processing and committed before
    the rail is called, and the call carries the persisted `<line>:<attempt>`, so a crash in between cannot pay
    twice (the poll job finds it). The account checked here is recorded on the line: the bank file pays it or
    nothing."""
    now = now or datetime.now(UTC)
    with unit_of_work(factory) as session:
        _mark_blocked(session, rail.name, now)
        lines = list(
            session.scalars(
                select(WindowLine)
                .where(
                    WindowLine.status == "queued",
                    WindowLine.rail == rail.name,
                    WindowLine.worker_id.not_in(_held_workers(now)),
                )
                .order_by(WindowLine.id)
                .limit(limit)
                .with_for_update(skip_locked=True)
            )
        )
        work: list[tuple[uuid.UUID, str, PayoutRequest | None]] = []
        for line in lines:
            window = session.get(PayWindow, line.window_id)
            assert window is not None
            account = verified_fund_account(session, line.worker_id)
            line.status, line.submitted_at, line.rail_status = "processing", now, None
            line.paid_account_hash = None if account is None else account.account_hash
            if account is None or account.rail_fund_account_id is None:
                work.append((line.id, reference_id(line), None))
                continue
            work.append((line.id, reference_id(line), _request(line, window, account)))
    sent = 0
    for line_id, attempt, request in work:
        result: PayoutResult | None
        if request is None:
            result = PayoutResult(reference="", status="failed", reason="account_unverified", reference_id=attempt)
        else:
            try:
                result = _with_reference_id(rail.create_payout(request), attempt)
                sent += 1
            except RailError as e:
                result = PayoutResult(reference="", status="failed", reason=e.code, reference_id=attempt)
            except RailUnknownOutcome:
                continue  # the poll job looks it up by reference
            except RailUnavailable:
                with unit_of_work(factory) as session:
                    back = _locked_line(session, line_id)
                    if back is not None and back.status == "processing":
                        back.status, back.submitted_at = "queued", None
                continue
        with unit_of_work(factory) as session:
            locked = _locked_line(session, line_id)
            if locked is not None:
                settle_line(session, locked, result, now)
    return sent


def poll_processing(
    factory: sessionmaker[Session],
    rail: Rail,
    now: datetime | None = None,
    limit: int = 50,
    older_than: timedelta = POLL_AFTER,
) -> int:
    """The backstop for webhooks that never came and for unknown outcomes: ask the rail about every line on it that
    has been processing for a while. A line with no reference is looked up by its `<line>:<attempt>`; if the rail
    has never seen it, it is sent again with the same idempotency key, unless the worker is now held."""
    now = now or datetime.now(UTC)
    with unit_of_work(factory) as session:
        rows = session.execute(
            select(WindowLine.id, WindowLine.rail_reference, WindowLine.attempts)
            .where(
                WindowLine.status == "processing",
                WindowLine.rail == rail.name,
                WindowLine.submitted_at <= now - older_than,
            )
            .order_by(WindowLine.submitted_at)
            .limit(limit)
        ).all()
    settled = 0
    for line_id, reference, attempts in rows:
        attempt = f"{line_id}:{attempts}"
        try:
            if reference:
                result: PayoutResult | None = rail.fetch_payout(reference)
            else:
                result = _find_or_resend(factory, rail, line_id, attempt, now)
        except (RailError, RailUnavailable, RailUnknownOutcome) as e:
            log.warning("payout lookup failed line_id=%s error=%s", line_id, type(e).__name__)
            continue
        if result is None:
            continue
        with unit_of_work(factory) as session:
            line = _locked_line(session, line_id)
            if line is not None and settle_line(session, line, result, now) and line.status in SETTLED:
                settled += 1
    return settled


def _find_or_resend(
    factory: sessionmaker[Session], rail: Rail, line_id: uuid.UUID, attempt: str, now: datetime
) -> PayoutResult | None:
    """The rail's payout of this attempt, or the attempt sent again. The rail never saw it, so a worker held since
    gets the line back in the queue (same attempt) instead of a payout. None: nothing to settle now."""
    found = rail.find_payout(attempt)
    if found is not None:
        return _with_reference_id(found, attempt)
    with unit_of_work(factory) as session:
        line = _locked_line(session, line_id)
        if line is None or line.status != "processing" or reference_id(line) != attempt:
            return None
        if live_hold(session, line.worker_id, now) is not None:
            line.status, line.submitted_at, line.rail_status = "queued", None, "held"
            return None
        window = session.get(PayWindow, line.window_id)
        assert window is not None
        account = verified_fund_account(session, line.worker_id)
        if account is None or account.rail_fund_account_id is None:
            return PayoutResult(reference="", status="failed", reason="account_unverified", reference_id=attempt)
        request = _request(line, window, account)
    return _with_reference_id(rail.create_payout(request), attempt)


# ---------- the bank file and its return file ----------


def _bank_file_skip(session: Session, line: WindowLine, account: BankAccount | None, now: datetime) -> str | None:
    if live_hold(session, line.worker_id, now) is not None:
        return "held"
    if account is None:
        return "account_missing"
    if account.status != "verified" or awaiting_confirmation(account) or account.account_hash != line.paid_account_hash:
        return "account_changed"
    return None


def bank_file(session: Session, window_id: uuid.UUID, now: datetime | None = None) -> tuple[str, list[dict[str, str]]]:
    """The NEFT/IMPS bulk file for the bank: one row per line in flight on the file rail, paid into the account
    checked when the line was dispatched, with its number unsealed for this file only. A line whose worker is now
    held, whose account is gone or was changed since goes back to the queue with that reason and is listed in
    `skipped`. Finance-only; the content is never logged."""
    now = now or datetime.now(UTC)
    window = _window(session, window_id, lock=False)
    if window.rail != "file":
        raise Conflict("this window is not paid by bank file", rail=window.rail).with_code("rail_mismatch")
    if window.status != "paying":
        raise Conflict("window is not paying", window_id=str(window_id), status=window.status)
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(["reference", "beneficiary_name", "account_number", "ifsc", "amount", "currency", "narration"])
    count = 0
    skipped: list[dict[str, str]] = []
    for line in session.scalars(
        select(WindowLine)
        .where(WindowLine.window_id == window_id, WindowLine.status == "processing")
        .order_by(WindowLine.worker_id)
        .with_for_update()
    ):
        account = session.get(BankAccount, line.worker_id)
        reason = _bank_file_skip(session, line, account, now)
        if reason is not None:
            line.status, line.submitted_at, line.rail_status = "queued", None, reason
            skipped.append({"line_id": str(line.id), "reason": reason})
            continue
        assert account is not None
        _csv_row(
            writer,
            [
                line.rail_reference,
                account.account_name,
                number_of(account),
                account.ifsc,
                f"{line.gross:.2f}",
                window.currency,
                f"Yantra {window.ends_at.astimezone(UTC):%d %b %Y}",
            ],
        )
        count += 1
    session.flush()
    log.info("bank file rendered window_id=%s lines=%s", window_id, count)
    if skipped:
        log.warning("bank file left lines out window_id=%s skipped=%s", window_id, len(skipped))
    return out.getvalue(), skipped


def reconcile_bank_file(
    session: Session, window_id: uuid.UUID, text: str, now: datetime | None = None
) -> dict[str, Any]:
    """The bank's return file, `reference,status,utr,reason` with status paid|failed|returned: each row settles
    its line. Unknown references and bad statuses are reported back, never fatal."""
    now = now or datetime.now(UTC)
    window = _window(session, window_id, lock=False)
    if window.rail != "file":
        raise Conflict("this window is not paid by bank file", rail=window.rail).with_code("rail_mismatch")
    reader = csv.DictReader(io.StringIO(text))
    if reader.fieldnames is None or not {"reference", "status"} <= set(reader.fieldnames):
        raise Invalid("the return file needs the columns reference,status,utr,reason")
    applied, skipped = 0, []
    for number, row in enumerate(reader, start=2):
        status = (row.get("status") or "").strip()
        reference = (row.get("reference") or "").strip()
        if status not in ("paid", "failed", "returned"):
            skipped.append({"row": number, "reference": reference, "reason": "bad_status"})
            continue
        line = session.scalar(
            select(WindowLine)
            .where(WindowLine.window_id == window_id, WindowLine.rail_reference == reference)
            .with_for_update()
        )
        if line is None:
            skipped.append({"row": number, "reference": reference, "reason": "unknown_reference"})
            continue
        result = PayoutResult(
            reference=reference,
            status=status,  # type: ignore[arg-type]  # checked against the three statuses above
            utr=(row.get("utr") or "").strip() or None,
            reason=(row.get("reason") or "").strip() or None,
        )
        if settle_line(session, line, result, now):
            applied += 1
        else:
            skipped.append({"row": number, "reference": reference, "reason": "already_settled"})
    return {"applied": applied, "skipped": skipped}


# ---------- the RazorpayX webhook ----------


def verify_signature(raw: bytes, signature: str | None, secret: str) -> None:
    expected = hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest()
    if not signature or not hmac.compare_digest(expected, signature):
        raise Unauthorized("webhook signature does not match")


def _entity(body: dict[str, Any], name: str) -> dict[str, Any] | None:
    wrapped = (body.get("payload") or {}).get(name)
    entity = wrapped.get("entity") if isinstance(wrapped, dict) else None
    return entity if isinstance(entity, dict) else None


def _event_key(kind: str, entity: dict[str, Any] | None, digest: str) -> str:
    """What makes an event one event, read from the signed body (the event-id header is not signed): the event,
    the entity and the status it reports. Too long for the key column, its digest."""
    if entity is None or not entity.get("id"):
        return digest
    key = f"{kind}:{entity['id']}:{entity.get('status') or ''}"
    return key if len(key) <= 80 else hashlib.sha256(key.encode()).hexdigest()


def _line_of(reference: object) -> uuid.UUID | None:
    """The line a payout's `reference_id` (`<line>:<attempt>`) names."""
    try:
        return uuid.UUID(str(reference or "").split(":", 1)[0])
    except ValueError:
        return None


def ingest_webhook(
    session: Session,
    raw: bytes,
    signature: str | None,
    secret: str,
    tolerance_seconds: int,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Verify, record once, apply. The signed body names the event (event, entity id, status): a replay answers
    `duplicate` whatever event-id header it carries. `created_at` is required; an event older than the tolerance is
    recorded as stale and not applied (the poll job is the backstop). News about another attempt of a line is
    recorded as `other_attempt` and not applied. Bodies are never stored or logged."""
    now = now or datetime.now(UTC)
    verify_signature(raw, signature, secret)
    try:
        body = json.loads(raw)
    except ValueError as e:
        raise Invalid("webhook body is not JSON") from e
    if not isinstance(body, dict) or not isinstance(body.get("created_at"), int):
        raise Invalid("webhook body has no created_at")
    digest = hashlib.sha256(raw).hexdigest()
    kind = str(body.get("event") or "unknown")[:60]
    payout, validation = _entity(body, "payout"), _entity(body, "fund_account.validation")
    key = _event_key(kind, payout if payout is not None else validation, digest)
    recorded = session.scalar(
        pg_insert(WebhookEvent)
        .values(id=key, rail="razorpayx", event_type=kind, body_sha256=digest, applied=False)
        .on_conflict_do_nothing()
        .returning(WebhookEvent.id)
    )
    if recorded is None:
        return {"duplicate": True, "applied": False}
    record = session.get(WebhookEvent, key)
    assert record is not None
    if now - datetime.fromtimestamp(body["created_at"], UTC) > timedelta(seconds=tolerance_seconds):
        record.note = "stale"
        session.flush()
        log.warning("stale webhook recorded event_type=%s", kind)
        return {"duplicate": False, "applied": False, "note": "stale"}
    if kind.startswith("payout.") and payout is not None:
        line_id = _line_of(payout.get("reference_id"))
        line = None if line_id is None else _locked_line(session, line_id)
        result = payout_of(payout)
        if line is None:
            record.note = "unknown_line"
        elif not for_this_attempt(line, result):
            record.line_id, record.worker_id, record.note = line.id, line.worker_id, "other_attempt"
        else:
            record.line_id, record.worker_id = line.id, line.worker_id
            record.applied = settle_line(session, line, result, now)
    elif kind.startswith("fund_account.validation") and validation is not None:
        entity = validation
        account = session.scalar(
            select(BankAccount).where(BankAccount.validation_id == str(entity.get("id"))).with_for_update()
        )
        if account is None:
            record.note = "unknown_validation"
        else:
            record.worker_id = account.worker_id
            before = account.status
            complete_validation(session, account, validation_of(entity), now)
            record.applied = account.status != before
    else:
        record.note = "ignored"
    session.flush()
    return {"duplicate": False, "applied": record.applied, "note": record.note}


# ---------- reconciliation ----------


def _sum(session: Session, column: Any, *where: Any) -> Decimal:
    return Decimal(session.scalar(select(func.coalesce(func.sum(column), 0)).where(*where)) or 0)


def reconcile(
    session: Session, window_id: uuid.UUID, persist: bool = False, now: datetime | None = None
) -> dict[str, Any]:
    """Earnings in the window equal its unreleased, unheld lines; paid lines equal what the rail says it moved;
    a paid window has no unpaid earnings. Persisted runs set `reconciled_at` the first time a paid window balances
    and emit `payout.reconciliation.delta.v1` when it does not. Never adjusts."""
    now = now or datetime.now(UTC)
    window = _window(session, window_id, lock=False)
    counted = WindowLine.status.not_in(("held", "released"))
    earned = money(_sum(session, Earning.amount, Earning.window_id == window_id))
    lines = money(_sum(session, WindowLine.gross, WindowLine.window_id == window_id, counted))
    paid = money(_sum(session, WindowLine.gross, WindowLine.window_id == window_id, WindowLine.status == "paid"))
    rail = money(
        _sum(
            session,
            func.coalesce(WindowLine.rail_amount, WindowLine.gross),
            WindowLine.window_id == window_id,
            WindowLine.status == "paid",
        )
    )
    counts: dict[str, int] = {
        status: int(n)
        for status, n in session.execute(
            select(WindowLine.status, func.count()).where(WindowLine.window_id == window_id).group_by(WindowLine.status)
        )
    }
    failed = int(counts.get("failed", 0)) + int(counts.get("returned", 0))
    processing = int(counts.get("processing", 0)) + int(counts.get("queued", 0))
    unpaid = 0
    if window.status == "paid":
        unpaid = int(
            session.scalar(
                select(func.count())
                .select_from(Earning)
                .where(Earning.window_id == window_id, Earning.status != "paid")
            )
            or 0
        )
    mismatched = [
        str(line_id)
        for (line_id,) in session.execute(
            select(WindowLine.id).where(
                WindowLine.window_id == window_id,
                WindowLine.status == "paid",
                WindowLine.rail_amount.is_not(None),
                WindowLine.rail_amount != WindowLine.gross,
            )
        )
    ]
    delta_lines, delta_rail = earned - lines, paid - rail
    balanced = delta_lines == ZERO and delta_rail == ZERO and unpaid == 0
    if window.status == "paid":
        balanced = balanced and failed == 0 and processing == 0
    report: dict[str, Any] = {
        "window_id": str(window.id),
        "status": window.status,
        "currency": window.currency,
        "earnings_total": str(earned),
        "lines_total": str(lines),
        "paid_total": str(paid),
        "rail_total": str(rail),
        "delta": str(delta_lines),
        "delta_rail": str(delta_rail),
        "failed_lines": failed,
        "processing_lines": processing,
        "unpaid_earnings": unpaid,
        "balanced": balanced,
        "reconciled_at": None if window.reconciled_at is None else window.reconciled_at.astimezone(UTC).isoformat(),
    }
    if not balanced:
        log.error(
            "reconciliation delta window_id=%s delta=%s delta_rail=%s unpaid=%s",
            window.id,
            delta_lines,
            delta_rail,
            unpaid,
        )
    if not persist:
        return report
    run = ReconciliationRun(
        window_id=window.id,
        ran_at=now,
        earnings_total=earned,
        lines_total=lines,
        paid_total=paid,
        rail_total=rail,
        delta_lines=delta_lines,
        delta_rail=delta_rail,
        failed_lines=failed,
        processing_lines=processing,
        balanced=balanced,
        details={"rail_amount_mismatch": mismatched, "unpaid_earnings": unpaid},
    )
    session.add(run)
    session.flush()
    if balanced and window.status == "paid" and window.reconciled_at is None:
        window.reconciled_at = now
        report["reconciled_at"] = now.astimezone(UTC).isoformat()
    if not balanced:
        emit(
            session,
            OUTBOX,
            f"window/{window.id}",
            PayoutReconciliationDelta(
                run_id=run.id,
                window_id=window.id,
                currency=window.currency,
                earnings_total=earned,
                lines_total=lines,
                paid_total=paid,
                rail_total=rail,
                delta_lines=delta_lines,
                delta_rail=delta_rail,
                failed_lines=failed,
                processing_lines=processing,
            ),
        )
    session.flush()
    report["run_id"] = str(run.id)
    return report


def reconcile_recent(factory: sessionmaker[Session], now: datetime | None = None) -> int:
    """The nightly job: a persisted run for every paying or paid window of the last 90 days. A window that fails is
    logged with its id and skipped; the others still reconcile. Returns how many did."""
    now = now or datetime.now(UTC)
    with unit_of_work(factory) as session:
        ids = list(
            session.scalars(
                select(PayWindow.id).where(
                    PayWindow.status.in_(("paying", "paid")), PayWindow.ends_at >= now - timedelta(days=RECONCILE_DAYS)
                )
            )
        )
    failed = 0
    for window_id in ids:
        try:
            with unit_of_work(factory) as session:
                reconcile(session, window_id, persist=True, now=now)
        except (SQLAlchemyError, DomainError):
            failed += 1
            log.exception("reconciliation failed window_id=%s", window_id)
    if failed:
        log.error("nightly reconciliation incomplete windows=%s failed=%s", len(ids), failed)
    return len(ids) - failed


def list_runs(
    session: Session, window_id: uuid.UUID | None = None, balanced: bool | None = None
) -> list[ReconciliationRun]:
    q = select(ReconciliationRun).order_by(ReconciliationRun.ran_at.desc()).limit(200)
    if window_id is not None:
        q = q.where(ReconciliationRun.window_id == window_id)
    if balanced is not None:
        q = q.where(ReconciliationRun.balanced.is_(balanced))
    return list(session.scalars(q))


# ---------- statements and the rail's state ----------


def statement_export(session: Session, window_id: uuid.UUID, worker_id: uuid.UUID, everyone: bool) -> str:
    """A window's statement as CSV, released only after the window reconciled. A worker gets their own earnings in
    it; finance and operators get every line."""
    window = _window(session, window_id, lock=False)
    if window.reconciled_at is None:
        raise Conflict("statements are released after the window reconciles").with_code("not_reconciled")
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    if everyone:
        writer.writerow(
            [
                "line_id",
                "worker_id",
                "gross",
                "currency",
                "earning_count",
                "status",
                "hold_reason",
                "rail_reference",
                "utr",
                "settled_at",
            ]
        )
        for line in session.scalars(
            select(WindowLine).where(WindowLine.window_id == window_id).order_by(WindowLine.worker_id)
        ):
            _csv_row(
                writer,
                [
                    line.id,
                    line.worker_id,
                    f"{line.gross:.2f}",
                    window.currency,
                    line.earning_count,
                    line.status,
                    line.hold_reason or "",
                    line.rail_reference or "",
                    line.utr or "",
                    "" if line.settled_at is None else line.settled_at.astimezone(UTC).isoformat(),
                ],
            )
        return out.getvalue()
    own = session.scalar(select(WindowLine).where(WindowLine.window_id == window_id, WindowLine.worker_id == worker_id))
    if own is None:
        raise NotFound("you have no line in this window", window_id=str(window_id))
    writer.writerow(
        ["window_starts", "window_ends", "line_status", "utr", "kind", "unit_id", "amount", "currency", "earned_at"]
    )
    for e in session.scalars(
        select(Earning)
        .where(Earning.window_id == window_id, Earning.worker_id == worker_id)
        .order_by(Earning.created_at)
    ):
        _csv_row(
            writer,
            [
                window.starts_at.astimezone(UTC).isoformat(),
                window.ends_at.astimezone(UTC).isoformat(),
                own.status,
                own.utr or "",
                e.kind,
                e.unit_id,
                f"{e.amount:.2f}",
                e.currency,
                e.created_at.astimezone(UTC).isoformat(),
            ],
        )
    return out.getvalue()


def rail_state(session: Session, rail: Rail, lease_rows: dict[str, datetime | None]) -> dict[str, Any]:
    counts: dict[str, int] = {
        status: int(n)
        for status, n in session.execute(
            select(WindowLine.status, func.count())
            .where(WindowLine.status.in_(("queued", "processing", "failed", "returned")))
            .group_by(WindowLine.status)
        )
    }
    return {
        "rail": rail.name,
        "supports_penny_drop": rail.supports_penny_drop,
        "lines": {k: int(counts.get(k, 0)) for k in ("queued", "processing", "failed", "returned")},
        "accounts_verifying": int(
            session.scalar(select(func.count()).select_from(BankAccount).where(BankAccount.status == "verifying")) or 0
        ),
        "last_dispatch_at": _iso(lease_rows.get("payout_dispatch")),
        "last_poll_at": _iso(lease_rows.get("payout_rail_poll")),
    }


def _iso(value: datetime | None) -> str | None:
    return None if value is None else value.astimezone(UTC).isoformat()


def attention(session: Session) -> dict[str, Any]:
    """What finance should look at now: windows with one approval, reconciliations that did not balance (latest
    run per window), lines the rail failed or returned (a reversed payout included), queued lines that cannot go out
    (a held worker, another rail, an account gone or changed), bank accounts waiting to be erased until the money
    owed is paid, accounts waiting for finance's confirmation, adjustments waiting, dead letters."""
    from yantra_payout.models import DEAD, Adjustment, Approval

    one_approval = select(Approval.window_id).group_by(Approval.window_id).having(func.count() == 1).subquery()
    awaiting = session.scalar(
        select(func.count())
        .select_from(PayWindow)
        .where(PayWindow.status == "closed", PayWindow.id.in_(select(one_approval.c.window_id)))
    )
    latest = (
        select(ReconciliationRun.window_id, func.max(ReconciliationRun.ran_at).label("ran_at"))
        .group_by(ReconciliationRun.window_id)
        .subquery()
    )
    deltas = session.scalar(
        select(func.count())
        .select_from(ReconciliationRun)
        .join(
            latest,
            (latest.c.window_id == ReconciliationRun.window_id) & (latest.c.ran_at == ReconciliationRun.ran_at),
        )
        .where(ReconciliationRun.balanced.is_(False))
    )
    failed = session.scalar(
        select(func.count()).select_from(WindowLine).where(WindowLine.status.in_(("failed", "returned")))
    )
    blocked = session.scalar(
        select(func.count())
        .select_from(WindowLine)
        .where(WindowLine.status == "queued", WindowLine.rail_status.in_(BLOCKED))
    )
    erasures = session.scalar(
        select(func.count()).select_from(BankAccount).where(BankAccount.erasure_requested_at.is_not(None))
    )
    unconfirmed = session.scalar(
        select(func.count())
        .select_from(BankAccount)
        .where(
            BankAccount.status == "verified",
            BankAccount.verification == "penny_drop",
            BankAccount.registered_name_match.is_(None),
            BankAccount.confirmed_at.is_(None),
        )
    )
    pending = session.scalar(select(func.count()).select_from(Adjustment).where(Adjustment.status == "pending"))
    dead = session.scalar(select(func.count()).select_from(DEAD))
    return {
        "windows_awaiting_second_approval": int(awaiting or 0),
        "reconciliation_deltas": int(deltas or 0),
        "failed_lines": int(failed or 0),
        "lines_blocked": int(blocked or 0),
        "erasures_pending": int(erasures or 0),
        "accounts_awaiting_confirmation": int(unconfirmed or 0),
        "pending_adjustments": int(pending or 0),
        "dead_letters": {"payout": int(dead or 0)},
    }
