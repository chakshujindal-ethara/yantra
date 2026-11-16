"""The payout operations.

Money is created in two places: `on_verdict_accepted` (the canonical accept) and `decide_adjustment` (a bonus
or correction that a second operator approved). The pay window runs Saturday 00:00 to Friday
23:59:59 IST. Holds happen before payout, never as clawbacks: a hold on the account (integrity, bank change, consent
withdrawn, by hand), a worker without a verified (and, where the penny drop proved no name, confirmed) bank account
and a first payout younger than seven days keep the line back. A worker over the per-worker cap is paid up to it and
the rest rolls on, payable, to the next window. Two distinct finance approvers release a window; `paying.py` pays it
line by line on the rail and checks the account's hold again before anything is sent."""

import logging
import uuid
from datetime import UTC, datetime, timedelta
from decimal import ROUND_HALF_UP, Decimal
from typing import Any
from zoneinfo import ZoneInfo

from sqlalchemy import func, or_, select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from yantra_common.errors import Conflict, Invalid, NotFound
from yantra_common.events import Envelope
from yantra_common.outbox import emit
from yantra_contracts.events.v1 import (
    PayoutAdjustmentApproved,
    PayoutHoldSet,
    PayoutWindowClosed,
    QualityVerdictAccepted,
    QualityVerdictRejected,
    TrackingAnomalyUpheld,
    WorkerConsentGiven,
    WorkerConsentWithdrawn,
    WorkUnitPublished,
)
from yantra_payout.accounts import awaiting_confirmation
from yantra_payout.models import (
    ADJUSTMENT_KINDS,
    OUTBOX,
    WINDOW_STATUSES,
    Adjustment,
    Approval,
    BankAccount,
    BatchRate,
    CostLedger,
    Earning,
    PayWindow,
    WindowLine,
    WorkerAccount,
)

log = logging.getLogger("yantra.payout")
IST = ZoneInfo("Asia/Kolkata")
FIRST_PAYOUT_HOLD = timedelta(days=7)
APPROVALS_REQUIRED = 2
ZERO = Decimal("0")
STATEMENT_EARNINGS = 500
STATEMENT_WINDOWS = 52
STATEMENT_WEEKS = 12
DEFAULT_CURRENCY = "INR"
# holds a manual hold may extend but never shorten while they are live
PROTECTED_HOLDS = ("integrity", "bank_change")


# ---------- consumers ----------


def on_unit_published(session: Session, env: Envelope) -> None:
    e = WorkUnitPublished.model_validate(env.data)
    rate = session.get(BatchRate, e.batch_id)
    if rate is None:
        session.add(
            BatchRate(
                batch_id=e.batch_id,
                unit_pay=e.unit_pay,
                unit_price=e.unit_price,
                review_pay=e.review_pay,
                currency=e.currency,
            )
        )
    session.flush()


def _rate(session: Session, batch_id: uuid.UUID) -> BatchRate:
    rate = session.get(BatchRate, batch_id)
    if rate is None:
        raise NotFound("no rate for batch; the published event has not arrived", batch_id=str(batch_id))
    return rate


def _account(session: Session, worker_id: uuid.UUID) -> WorkerAccount:
    account = session.get(WorkerAccount, worker_id)
    if account is None:
        account = WorkerAccount(worker_id=worker_id)
        session.add(account)
        session.flush()
    return account


PAISA = Decimal("0.01")


def money(amount: Decimal) -> Decimal:
    """Every amount that can be paid is quantized to the paisa when it is created, so files, events and
    reconciliation all see the same number."""
    return amount.quantize(PAISA, rounding=ROUND_HALF_UP)


def _earn(
    session: Session,
    env: Envelope,
    kind: str,
    worker_id: uuid.UUID,
    unit_id: uuid.UUID,
    rate: BatchRate,
    amount: Decimal,
) -> None:
    _account(session, worker_id)
    session.add(
        Earning(
            event_id=env.id,
            kind=kind,
            worker_id=worker_id,
            unit_id=unit_id,
            batch_id=rate.batch_id,
            amount=money(amount),
            currency=rate.currency,
        )
    )


def on_verdict_accepted(session: Session, env: Envelope) -> None:
    """The only place money is created: one unit earning for the author, one review earning for the reviewer,
    one audit earning for the auditor if there was one, and the unit's cost line."""
    e = QualityVerdictAccepted.model_validate(env.data)
    rate = _rate(session, e.batch_id)
    _earn(session, env, "unit", e.worker_id, e.unit_id, rate, rate.unit_pay)
    _earn(session, env, "review", e.reviewer_id, e.unit_id, rate, rate.review_pay)
    audit = ZERO
    if e.auditor_id is not None:
        _earn(session, env, "audit", e.auditor_id, e.unit_id, rate, rate.review_pay)
        audit = rate.review_pay
    session.add(
        CostLedger(
            unit_id=e.unit_id,
            event_id=env.id,
            batch_id=e.batch_id,
            currency=rate.currency,
            accepted=True,
            price=rate.unit_price,
            pay=rate.unit_pay,
            review=rate.review_pay,
            audit=audit,
        )
    )
    session.flush()


def on_verdict_rejected(session: Session, env: Envelope) -> None:
    """A rejection pays the reviewer (and auditor) for the review; the author earns nothing. The cost line
    records the review cost and whether the client caused the rework (billable)."""
    e = QualityVerdictRejected.model_validate(env.data)
    rate = _rate(session, e.batch_id)
    _earn(session, env, "review", e.reviewer_id, e.unit_id, rate, rate.review_pay)
    audit = ZERO
    if e.auditor_id is not None:
        _earn(session, env, "audit", e.auditor_id, e.unit_id, rate, rate.review_pay)
        audit = rate.review_pay
    session.add(
        CostLedger(
            unit_id=e.unit_id,
            event_id=env.id,
            batch_id=e.batch_id,
            currency=rate.currency,
            accepted=False,
            price=ZERO,
            pay=ZERO,
            review=rate.review_pay,
            audit=audit,
            billable_rework=e.billable,
        )
    )
    session.flush()


# ---------- the pay window ----------


def window_bounds(now: datetime) -> tuple[datetime, datetime]:
    """The most recent completed Saturday-to-Friday IST week ending before `now`."""
    local = now.astimezone(IST)
    days_since_saturday = (local.weekday() - 5) % 7  # Saturday is weekday 5
    this_saturday = (local - timedelta(days=days_since_saturday)).replace(hour=0, minute=0, second=0, microsecond=0)
    starts = this_saturday - timedelta(days=7)
    ends = this_saturday - timedelta(microseconds=1)
    return starts.astimezone(UTC), ends.astimezone(UTC)


def window_lock(session: Session, currency: str) -> None:
    """Serialise everything that moves earnings in or out of windows of one currency (close, release)."""
    session.execute(text("SELECT pg_advisory_xact_lock(hashtext(:k))"), {"k": f"pay_window:{currency}"})


def _up_to(earnings: list[Earning], cap: Decimal | None) -> list[Earning]:
    """The oldest earnings whose sum stays within the cap; the rest wait for the next window."""
    if cap is None:
        return earnings
    taken: list[Earning] = []
    running = ZERO
    for earning in earnings:
        if running + earning.amount > cap:
            break
        taken.append(earning)
        running += earning.amount
    return taken


def close_window(
    session: Session, currency: str, now: datetime | None = None, max_per_worker: Decimal | None = None
) -> PayWindow:
    """Close the last completed week. The payable earnings created inside it are read once, locked, and every sum is
    over exactly those rows, so an earning committed meanwhile waits for the next close instead of being windowed
    uncounted. One line per worker: a held worker's earnings all stay payable; a worker over the per-worker cap is
    paid up to it, oldest first, and the rest stays payable for the next window. Only a single earning bigger than
    the cap is held (`over_cap`): raising the cap is the only way to pay it."""
    now = now or datetime.now(UTC)
    window_lock(session, currency)
    starts, ends = window_bounds(now)
    window = PayWindow(starts_at=starts, ends_at=ends, currency=currency)
    session.add(window)
    try:
        session.flush()
    except IntegrityError as e:
        raise Conflict("this window is already closed", ends_at=ends.isoformat(), currency=currency) from e
    by_worker: dict[uuid.UUID, list[Earning]] = {}
    for earning in session.scalars(
        select(Earning)
        .where(Earning.status == "payable", Earning.currency == currency, Earning.created_at <= ends)
        .order_by(Earning.worker_id, Earning.created_at, Earning.id)
        .with_for_update()
    ):
        by_worker.setdefault(earning.worker_id, []).append(earning)
    gross = held = ZERO
    for worker_id, owned in by_worker.items():
        account = _account(session, worker_id)
        reason = hold_reason(account, owned[0].created_at, now, _bank_hold(session, worker_id))
        taken = [] if reason else _up_to(owned, max_per_worker)
        if reason is None and not taken:
            reason = "over_cap"
        lined = owned if reason else taken
        total = money(sum((e.amount for e in lined), ZERO))
        session.add(
            WindowLine(
                window_id=window.id,
                worker_id=worker_id,
                gross=total,
                earning_count=len(lined),
                status="held" if reason else "payable",
                hold_reason=reason,
            )
        )
        if reason:
            held += total
            continue
        gross += total
        for earning in taken:
            earning.status, earning.window_id = "windowed", window.id
    window.gross_total, window.held_total = gross, held
    emit(
        session,
        OUTBOX,
        f"window/{window.id}",
        PayoutWindowClosed(
            window_id=window.id,
            starts_at=starts.isoformat(),
            ends_at=ends.isoformat(),
            currency=currency,
            line_count=len(by_worker),
            gross_total=gross,
            held_total=held,
        ),
    )
    session.flush()
    return window


def hold_reason(account: WorkerAccount, first_earning_at: datetime, now: datetime, bank_hold: str | None) -> str | None:
    if account.hold_until is not None and account.hold_until > now:
        return account.hold_reason or "integrity"
    if account.consent_withdrawn:
        return "consent_withdrawn"
    if bank_hold is not None:
        return bank_hold
    if account.first_paid_at is None and first_earning_at + FIRST_PAYOUT_HOLD > now:
        return "first_payout"
    return None


def _bank_hold(session: Session, worker_id: uuid.UUID) -> str | None:
    """Why the worker's bank account cannot be paid into yet, if it cannot."""
    bank = session.get(BankAccount, worker_id)
    if bank is None or bank.status != "verified":
        return "account_unverified"
    return "account_unconfirmed" if awaiting_confirmation(bank) else None


def _window(session: Session, window_id: uuid.UUID, lock: bool = True) -> PayWindow:
    stmt = select(PayWindow).where(PayWindow.id == window_id)
    window = session.scalar(stmt.with_for_update() if lock else stmt)
    if window is None:
        raise NotFound("window not found", window_id=str(window_id))
    return window


def approve_window(session: Session, window_id: uuid.UUID, approver: str) -> PayWindow:
    """Two distinct approvers release a window. The same person twice is one approval."""
    window = _window(session, window_id)
    if window.status != "closed":
        raise Conflict("window is not awaiting approval", window_id=str(window_id), status=window.status)
    if session.get(Approval, (window_id, approver)) is not None:
        raise Conflict("this approver has already approved", window_id=str(window_id)).with_code("already_approved")
    session.add(Approval(window_id=window_id, approver=approver))
    session.flush()
    count = session.scalar(select(func.count()).select_from(Approval).where(Approval.window_id == window_id)) or 0
    if count >= APPROVALS_REQUIRED:
        window.status = "approved"
    session.flush()
    return window


# ---------- statements and the margin report ----------


def week_grid(now: datetime, weeks: int = STATEMENT_WEEKS) -> list[tuple[datetime, datetime]]:
    """The `weeks` most recent IST pay weeks ending with the one that contains `now`, oldest first. Each is the
    `window_bounds` week of a point seven days later, so the edges are exactly the ones close_window cuts on."""
    return [window_bounds(now + timedelta(days=7 * (1 - back))) for back in reversed(range(weeks))]


def _iso(value: datetime | None) -> str | None:
    """Every instant the new statement keys carry is UTC, whatever zone the row or the caller's clock was in."""
    return None if value is None else value.astimezone(UTC).isoformat()


def _weekly(
    session: Session, worker_id: uuid.UUID, grid: list[tuple[datetime, datetime]], fallback: str
) -> list[dict[str, Any]]:
    """One row per week per currency seen on the grid (the `fallback` currency when none), every week present."""
    rows = session.execute(
        select(Earning.created_at, Earning.currency, Earning.amount).where(
            Earning.worker_id == worker_id, Earning.created_at >= grid[0][0], Earning.created_at <= grid[-1][1]
        )
    ).all()
    sums: dict[tuple[int, str], Decimal] = {}
    counts: dict[tuple[int, str], int] = {}
    for created_at, currency, amount in rows:
        index = next(i for i, (starts, ends) in enumerate(grid) if starts <= created_at <= ends)
        sums[index, currency] = sums.get((index, currency), ZERO) + amount
        counts[index, currency] = counts.get((index, currency), 0) + 1
    currencies = sorted({currency for _, currency in sums}) or [fallback]
    return [
        {
            "starts_at": _iso(starts),
            "ends_at": _iso(ends),
            "currency": currency,
            "amount": str(money(sums.get((i, currency), ZERO))),
            "count": counts.get((i, currency), 0),
        }
        for i, (starts, ends) in enumerate(grid)
        for currency in currencies
    ]


def _pending_next(session: Session, worker_id: uuid.UUID, fallback: str) -> dict[str, Any]:
    """What the next close will pick up: the worker's payable earnings. A worker earns in one currency in
    Stage 1; were there several, the largest pending one is the one reported."""
    row = session.execute(
        select(Earning.currency, func.sum(Earning.amount), func.count())
        .where(Earning.worker_id == worker_id, Earning.status == "payable")
        .group_by(Earning.currency)
        .order_by(func.sum(Earning.amount).desc())
        .limit(1)
    ).first()
    if row is None:
        return {"currency": fallback, "amount": str(money(ZERO)), "count": 0}
    currency, total, count = row
    return {"currency": currency, "amount": str(money(Decimal(total))), "count": int(count)}


def _window_rows(session: Session, worker_id: uuid.UUID) -> list[dict[str, Any]]:
    """The worker's line in every window it reached, newest first: the payouts table of the earnings screen."""
    rows = session.execute(
        select(WindowLine, PayWindow)
        .join(PayWindow, PayWindow.id == WindowLine.window_id)
        .where(WindowLine.worker_id == worker_id)
        .order_by(PayWindow.ends_at.desc())
        .limit(STATEMENT_WINDOWS)
    ).all()
    return [
        {
            "window_id": str(window.id),
            "starts_at": _iso(window.starts_at),
            "ends_at": _iso(window.ends_at),
            "currency": window.currency,
            "window_status": window.status,
            "line_status": line.status,
            "gross": str(money(line.gross)),
            "earning_count": line.earning_count,
            "hold_reason": line.hold_reason,
            "utr": line.utr,
            "failure_reason": line.failure_reason,
            "paid_at": _iso(window.paid_at),
            "rail_reference": window.rail_reference,
            "closed_at": _iso(window.closed_at),
        }
        for line, window in rows
    ]


def statement(
    session: Session, worker_id: uuid.UUID, now: datetime | None = None, limit: int = STATEMENT_EARNINGS
) -> dict[str, Any]:
    """The worker's earnings screen in one read. `worker_id`, `totals`, `hold` and `earnings` are the original
    shape the CLI renders; `account`, `windows`, `weeks`, `pending_next` and `next_window_closes_at` feed the
    totals, the weekly chart, the payouts table and the hold explanation. `totals` is summed in the database
    over every earning the worker has; only the `earnings` list is cut to the newest `limit` rows."""
    now = now or datetime.now(UTC)
    earnings = session.scalars(
        select(Earning).where(Earning.worker_id == worker_id).order_by(Earning.created_at.desc()).limit(limit)
    ).all()
    totals = {
        status: money(Decimal(total))
        for status, total in session.execute(
            select(Earning.status, func.sum(Earning.amount))
            .where(Earning.worker_id == worker_id)
            .group_by(Earning.status)
        )
    }
    account = session.get(WorkerAccount, worker_id)
    currency = earnings[0].currency if earnings else DEFAULT_CURRENCY
    grid = week_grid(now)
    return {
        "worker_id": str(worker_id),
        "totals": {k: str(v) for k, v in sorted(totals.items())},
        "hold": None if account is None else _hold_label(account),
        "earnings": [
            {
                "id": str(e.id),
                "kind": e.kind,
                "unit_id": str(e.unit_id),
                "amount": str(money(e.amount)),
                "currency": e.currency,
                "status": e.status,
                "window_id": None if e.window_id is None else str(e.window_id),
                "created_at": e.created_at.isoformat(),
            }
            for e in earnings
        ],
        "account": {
            "first_paid_at": None if account is None else _iso(account.first_paid_at),
            "hold_until": None if account is None else _iso(account.hold_until),
            "hold_reason": None if account is None else account.hold_reason,
        },
        "windows": _window_rows(session, worker_id),
        "weeks": _weekly(session, worker_id, grid, currency),
        "pending_next": _pending_next(session, worker_id, currency),
        "next_window_closes_at": _iso(grid[-1][1]),
    }


def _hold_label(account: WorkerAccount) -> str | None:
    if account.hold_until is not None:
        return account.hold_reason
    return "consent_withdrawn" if account.consent_withdrawn else None


def margin_report(session: Session) -> list[dict[str, Any]]:
    """Per batch: what the accepted units invoice, every cost line, and the margin. Reads the cost ledger only."""
    rows = session.execute(
        select(
            CostLedger.batch_id,
            CostLedger.currency,
            func.count(func.distinct(CostLedger.unit_id)).filter(CostLedger.accepted),
            func.count(func.distinct(CostLedger.unit_id)),
            func.sum(CostLedger.price),
            func.sum(CostLedger.pay),
            func.sum(CostLedger.review),
            func.sum(CostLedger.audit),
            func.count().filter(CostLedger.billable_rework),
        )
        .group_by(CostLedger.batch_id, CostLedger.currency)
        .order_by(CostLedger.batch_id)
    ).all()
    report = []
    for batch_id, currency, accepted, units, price, pay, review, audit, billable in rows:
        revenue = money(Decimal(price))
        cost = money(Decimal(pay)) + money(Decimal(review)) + money(Decimal(audit))
        report.append(
            {
                "batch_id": str(batch_id),
                "currency": currency,
                "units_judged": int(units),
                "units_accepted": int(accepted or 0),
                "invoice": str(revenue),
                "cost_pay": str(money(Decimal(pay))),
                "cost_review": str(money(Decimal(review))),
                "cost_audit": str(money(Decimal(audit))),
                "billable_rework_units": int(billable or 0),
                "margin": str(revenue - cost),
                "margin_fraction": str(((revenue - cost) / revenue).quantize(Decimal("0.0001"))) if revenue else "0",
            }
        )
    return report


def set_hold(
    session: Session,
    worker_id: uuid.UUID,
    reason: str | None,
    until: datetime | None,
    source: str = "manual",
    by: uuid.UUID | None = None,
    now: datetime | None = None,
) -> WorkerAccount:
    """Put a hold on a worker's payouts, or lift it (`until` None). By hand, never on the caller's own account, and
    never shorter than a live integrity or bank-change hold: that hold keeps its later end and its reason. Lifting
    by hand also releases payouts held for withdrawn consent (finance decided to pay what was already earned)."""
    if by is not None and by == worker_id:
        raise Conflict("nobody holds or lifts their own payouts", worker_id=str(worker_id)).with_code("same_person")
    now = now or datetime.now(UTC)
    account = _account(session, worker_id)
    if (
        source == "manual"
        and account.hold_reason in PROTECTED_HOLDS
        and account.hold_until is not None
        and account.hold_until > now
        and (until is None or until <= account.hold_until)
    ):
        log.info("manual hold kept the longer hold worker_id=%s reason=%s", worker_id, account.hold_reason)
        return account
    if until is None and account.consent_withdrawn:
        account.consent_withdrawn = False
        log.info("consent hold lifted by hand worker_id=%s by=%s", worker_id, by)
    account.hold_reason, account.hold_until = reason, until
    emit(
        session,
        OUTBOX,
        f"account/{worker_id}",
        PayoutHoldSet(
            worker_id=worker_id,
            reason=reason,
            until=None if until is None else until.astimezone(UTC).isoformat(),
            source="anomaly" if source == "anomaly" else "manual",
        ),
    )
    session.flush()
    return account


def on_anomaly_upheld(session: Session, env: Envelope, hold_days: int = 30) -> None:
    """An operator upheld a tracker anomaly: the worker's payouts are held for `hold_days` from the decision. An
    existing longer hold is never shortened; a redelivery changes nothing."""
    e = TrackingAnomalyUpheld.model_validate(env.data)
    account = _account(session, e.worker_id)
    until = env.occurred_at + timedelta(days=hold_days)
    if account.hold_until is not None and account.hold_until >= until:
        return
    set_hold(session, e.worker_id, "integrity", until, source="anomaly")


def _consent_event(session: Session, worker_id: uuid.UUID, at: datetime) -> WorkerAccount | None:
    """The worker's account if this consent event is newer than the last one applied (event time), else None: a
    redelivery or an older event arriving late changes nothing."""
    account = session.scalar(select(WorkerAccount).where(WorkerAccount.worker_id == worker_id).with_for_update())
    account = account or _account(session, worker_id)
    if account.consent_changed_at is not None and at <= account.consent_changed_at:
        return None
    account.consent_changed_at = at
    return account


def on_consent_withdrawn(session: Session, env: Envelope) -> None:
    """The worker withdrew the data-processing consent: their payouts stop (`consent_withdrawn`) until
    `worker.consent.given.v1`, or until a hold is lifted by hand (finance decides to pay what was already earned).
    It sits beside any other hold, so consenting again never clears an integrity or bank-change hold."""
    e = WorkerConsentWithdrawn.model_validate(env.data)
    account = _consent_event(session, e.worker_id, env.occurred_at)
    if account is not None:
        account.consent_withdrawn = True
        session.flush()
        log.info("payouts held for withdrawn consent worker_id=%s", e.worker_id)


def on_consent_given(session: Session, env: Envelope) -> None:
    """The worker consented again: payouts held for withdrawn consent go out again. Any other hold stays."""
    e = WorkerConsentGiven.model_validate(env.data)
    account = _consent_event(session, e.worker_id, env.occurred_at)
    if account is not None:
        account.consent_withdrawn = False
        session.flush()


def held_accounts(session: Session, now: datetime | None = None, limit: int = 50, offset: int = 0) -> dict[str, Any]:
    """Accounts on a live hold, the longest-held first: finance's Holds tab."""
    now = now or datetime.now(UTC)
    live = or_(WorkerAccount.hold_until > now, WorkerAccount.consent_withdrawn.is_(True))
    total = session.scalar(select(func.count()).select_from(WorkerAccount).where(live)) or 0
    rows = session.scalars(
        select(WorkerAccount)
        .where(live)
        .order_by(WorkerAccount.hold_until.desc().nulls_last(), WorkerAccount.worker_id)
        .limit(limit)
        .offset(offset)
    )
    return {
        "total": int(total),
        "items": [
            {
                "worker_id": str(a.worker_id),
                "hold_reason": a.hold_reason
                if a.hold_until is not None and a.hold_until > now
                else "consent_withdrawn",
                "hold_until": _iso(a.hold_until),
                "first_paid_at": _iso(a.first_paid_at),
            }
            for a in rows
        ],
    }


def get_window(session: Session, window_id: uuid.UUID) -> PayWindow:
    return _window(session, window_id, lock=False)


def list_windows(session: Session, status: str | None = None) -> list[PayWindow]:
    q = select(PayWindow).order_by(PayWindow.ends_at.desc()).limit(200)
    if status is not None:
        q = q.where(PayWindow.status == status)
    return list(session.scalars(q))


def window_lines(session: Session, window_id: uuid.UUID) -> list[WindowLine]:
    if session.get(PayWindow, window_id) is None:
        raise NotFound("window not found", window_id=str(window_id))
    return list(
        session.scalars(select(WindowLine).where(WindowLine.window_id == window_id).order_by(WindowLine.worker_id))
    )


# ---------- adjustments: proposed by one operator, decided by another ----------


def propose_adjustment(
    session: Session,
    worker_id: uuid.UUID,
    amount: Decimal,
    currency: str,
    kind: str,
    reason: str,
    proposed_by: uuid.UUID,
) -> Adjustment:
    """A positive bonus or correction waiting for a different operator's decision. Adjustments never take money
    back: a negative correction is refused, not clamped."""
    if kind not in ADJUSTMENT_KINDS:
        raise Invalid("kind must be bonus or correction")
    if proposed_by == worker_id:
        raise Conflict("nobody proposes an adjustment for themselves").with_code("same_person")
    amount = money(amount)
    if amount <= ZERO:
        raise Invalid("amount must be positive (at least one paisa)", amount=str(amount))
    adjustment = Adjustment(
        worker_id=worker_id, amount=amount, currency=currency, kind=kind, reason=reason, proposed_by=proposed_by
    )
    session.add(adjustment)
    session.flush()
    session.refresh(adjustment)
    return adjustment


def list_adjustments(session: Session, status: str | None = None, limit: int = 200) -> list[Adjustment]:
    q = select(Adjustment).order_by(Adjustment.created_at.desc(), Adjustment.id.desc()).limit(limit)
    if status is not None:
        q = q.where(Adjustment.status == status)
    return list(session.scalars(q))


def decide_adjustment(
    session: Session, adjustment_id: uuid.UUID, decided_by: uuid.UUID, outcome: str, note: str | None = None
) -> Adjustment:
    """The second person approves or rejects, once. Approval creates a payable `adjust` earning (its event, unit
    and batch ids are the adjustment's id) and emits `payout.adjustment.approved`."""
    if outcome not in ("approved", "rejected"):
        raise Invalid("outcome must be approved or rejected")
    adjustment = session.scalar(select(Adjustment).where(Adjustment.id == adjustment_id).with_for_update())
    if adjustment is None:
        raise NotFound("adjustment not found", adjustment_id=str(adjustment_id))
    if adjustment.status != "pending":
        raise Conflict(
            "adjustment already decided", adjustment_id=str(adjustment_id), status=adjustment.status
        ).with_code("already_decided")
    if decided_by in (adjustment.proposed_by, adjustment.worker_id):
        raise Conflict(
            "neither the proposer nor the worker paid can decide an adjustment", adjustment_id=str(adjustment_id)
        ).with_code("same_person")
    adjustment.status, adjustment.decided_by, adjustment.decision_note = outcome, decided_by, note
    adjustment.decided_at = datetime.now(UTC)
    if outcome == "approved":
        _account(session, adjustment.worker_id)
        session.add(
            Earning(
                event_id=adjustment.id,
                kind="adjust",
                worker_id=adjustment.worker_id,
                unit_id=adjustment.id,
                batch_id=adjustment.id,
                amount=money(adjustment.amount),
                currency=adjustment.currency,
            )
        )
        emit(
            session,
            OUTBOX,
            f"adjustment/{adjustment.id}",
            PayoutAdjustmentApproved(
                adjustment_id=adjustment.id,
                worker_id=adjustment.worker_id,
                amount=money(adjustment.amount),
                currency=adjustment.currency,
                kind=adjustment.kind,
            ),
        )
    session.flush()
    return adjustment


# ---------- the ops overview and the account lookup ----------


def _payable_split(
    session: Session, now: datetime, worker_id: uuid.UUID | None = None
) -> tuple[dict[str, Decimal], dict[str, Decimal]]:
    """Payable earnings per currency, split the way the next close would: (payable now, held). A worker is held
    for the same reasons `close_window` holds a line: an integrity hold on the account, or a first payout
    younger than FIRST_PAYOUT_HOLD."""
    q = (
        select(Earning.worker_id, Earning.currency, func.sum(Earning.amount), func.min(Earning.created_at))
        .where(Earning.status == "payable")
        .group_by(Earning.worker_id, Earning.currency)
    )
    if worker_id is not None:
        q = q.where(Earning.worker_id == worker_id)
    payable: dict[str, Decimal] = {}
    held: dict[str, Decimal] = {}
    for owner, currency, total, first_at in session.execute(q):
        account = session.get(WorkerAccount, owner) or WorkerAccount(worker_id=owner)
        bucket = held if hold_reason(account, first_at, now, _bank_hold(session, owner)) else payable
        bucket[currency] = bucket.get(currency, ZERO) + Decimal(total)
    return payable, held


def _per_currency(totals: dict[str, Decimal]) -> dict[str, str]:
    return {currency: str(money(total)) for currency, total in sorted(totals.items())}


def _paid_by_currency(session: Session, worker_id: uuid.UUID | None = None) -> dict[str, Decimal]:
    q = select(Earning.currency, func.sum(Earning.amount)).where(Earning.status == "paid").group_by(Earning.currency)
    if worker_id is not None:
        q = q.where(Earning.worker_id == worker_id)
    return {currency: Decimal(total) for currency, total in session.execute(q)}


def overview(session: Session, now: datetime | None = None) -> dict[str, Any]:
    """The finance numbers on the ops overview. Every money figure is per currency. `payable_now` is what the
    next close would pay and `held_total` what it would hold; `paid_total` is every paid earning;
    `open_window` is the IST pay week that contains `now` and when it closes; `margin_total` sums the margin
    report; `pending_adjustments` counts proposals waiting for their second person."""
    now = now or datetime.now(UTC)
    payable, held = _payable_split(session, now)
    counts = dict.fromkeys(WINDOW_STATUSES, 0)
    for status, count in session.execute(select(PayWindow.status, func.count()).group_by(PayWindow.status)):
        counts[status] = int(count)
    margin: dict[str, Decimal] = {}
    for row in margin_report(session):
        margin[row["currency"]] = margin.get(row["currency"], ZERO) + Decimal(row["margin"])
    starts, ends = window_bounds(now + timedelta(days=7))
    pending = session.scalar(select(func.count()).select_from(Adjustment).where(Adjustment.status == "pending")) or 0
    return {
        "payable_now": _per_currency(payable),
        "paid_total": _per_currency(_paid_by_currency(session)),
        "held_total": _per_currency(held),
        "open_window": {
            "starts_at": _iso(starts),
            "ends_at": _iso(ends),
            "closes_in_seconds": int((ends - now).total_seconds()),
        },
        "windows": counts,
        "margin_total": _per_currency(margin),
        "pending_adjustments": int(pending),
    }


def account_summary(session: Session, worker_id: uuid.UUID, now: datetime | None = None) -> dict[str, Any]:
    """One worker for ops: the account (holds, first payout) and their money by state. Stage 1 pays each worker in
    one currency, so the totals are plain sums and name that currency (the default one when nothing was earned)."""
    now = now or datetime.now(UTC)
    account = session.get(WorkerAccount, worker_id)
    if account is None:
        raise NotFound("account not found", worker_id=str(worker_id))
    payable, held = _payable_split(session, now, worker_id)
    paid = _paid_by_currency(session, worker_id)
    currencies = sorted({*payable, *held, *paid})
    return {
        "account": {
            "worker_id": str(worker_id),
            "first_paid_at": _iso(account.first_paid_at),
            "hold_until": _iso(account.hold_until),
            "hold_reason": account.hold_reason,
        },
        "totals": {
            "payable": str(money(sum(payable.values(), ZERO))),
            "paid": str(money(sum(paid.values(), ZERO))),
            "held": str(money(sum(held.values(), ZERO))),
            "currency": currencies[0] if currencies else DEFAULT_CURRENCY,
        },
    }
