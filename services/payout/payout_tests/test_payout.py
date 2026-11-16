import dataclasses
import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from unittest.mock import ANY

import pytest
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from yantra_common.consumer import handle_in_transaction
from yantra_common.errors import Conflict, Invalid, NotFound
from yantra_payout.models import CONSUMED, OUTBOX, Adjustment, CostLedger, Earning, WindowLine, WorkerAccount
from yantra_payout.paying import reconcile
from yantra_payout.service import (
    IST,
    account_summary,
    approve_window,
    close_window,
    decide_adjustment,
    list_adjustments,
    list_windows,
    margin_report,
    on_unit_published,
    on_verdict_accepted,
    on_verdict_rejected,
    overview,
    propose_adjustment,
    set_hold,
    statement,
    window_bounds,
    window_lines,
)
from yantra_payout.testing import accepted, envelope, pay_out, published, rejected, verified_account

# a Monday in IST, well after the week of 25-31 October 2026 (Sat-Fri)
MONDAY = datetime(2026, 11, 2, 10, 0, tzinfo=IST)


def events(session):
    return session.execute(select(OUTBOX.c.type, OUTBOX.c.payload).order_by(OUTBOX.c.occurred_at)).all()


def seed_batch(session, **rates) -> uuid.UUID:
    batch = uuid.uuid4()
    on_unit_published(session, published(batch, **rates))
    session.commit()
    return batch


def test_window_bounds_are_saturday_to_friday_in_ist():
    starts, ends = window_bounds(MONDAY)
    assert starts.astimezone(IST) == datetime(2026, 10, 24, 0, 0, tzinfo=IST)
    assert ends.astimezone(IST) == datetime(2026, 10, 30, 23, 59, 59, 999999, tzinfo=IST)
    sat_early = datetime(2026, 10, 31, 0, 0, 1, tzinfo=IST)
    assert window_bounds(sat_early)[1].astimezone(IST) == datetime(2026, 10, 30, 23, 59, 59, 999999, tzinfo=IST)
    fri_late = datetime(2026, 10, 30, 23, 0, tzinfo=IST)
    assert window_bounds(fri_late)[1].astimezone(IST) == datetime(2026, 10, 23, 23, 59, 59, 999999, tzinfo=IST)


def test_an_accept_creates_exactly_the_earnings_and_the_cost_line(session):
    batch = seed_batch(session)
    worker, reviewer, auditor = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    env = accepted(batch, worker, reviewer, auditor)
    on_verdict_accepted(session, env)
    session.commit()
    earnings = {(e.kind, e.worker_id): e.amount for e in session.scalars(select(Earning))}
    assert earnings == {
        ("unit", worker): Decimal("28"),
        ("review", reviewer): Decimal("6"),
        ("audit", auditor): Decimal("6"),
    }
    cost = session.scalar(select(CostLedger).where(CostLedger.unit_id == uuid.UUID(env.data["unit_id"])))
    assert (cost.price, cost.pay, cost.review, cost.audit, cost.accepted) == (
        Decimal("60"),
        Decimal("28"),
        Decimal("6"),
        Decimal("6"),
        True,
    )
    # a redelivery of the same event is refused by the unique constraint, not paid twice
    with pytest.raises(IntegrityError):
        on_verdict_accepted(session, env)
    session.rollback()
    assert len(session.scalars(select(Earning)).all()) == 3


def test_the_consumer_wrapper_makes_a_redelivery_a_no_op(factory, session):
    batch = seed_batch(session)
    env = accepted(batch, uuid.uuid4(), uuid.uuid4())
    assert handle_in_transaction(factory, CONSUMED, on_verdict_accepted, env) is True
    assert handle_in_transaction(factory, CONSUMED, on_verdict_accepted, env) is False
    assert len(session.scalars(select(Earning)).all()) == 2


def test_a_rejection_pays_the_reviewer_only_and_records_billable_rework(session):
    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    env = rejected(batch, worker, reviewer, billable=True)
    on_verdict_rejected(session, env)
    session.commit()
    earnings = session.scalars(select(Earning)).all()
    assert [(e.kind, e.worker_id, e.amount) for e in earnings] == [("review", reviewer, Decimal("6"))]
    cost = session.scalar(select(CostLedger).where(CostLedger.unit_id == uuid.UUID(env.data["unit_id"])))
    assert cost.accepted is False and cost.pay == 0 and cost.billable_rework is True


def test_a_verdict_before_the_rate_is_known_is_refused_and_retried_later(session):
    with pytest.raises(NotFound):
        on_verdict_accepted(session, accepted(uuid.uuid4(), uuid.uuid4(), uuid.uuid4()))


def test_published_twice_keeps_the_first_rate(session):
    batch = seed_batch(session)
    on_unit_published(session, published(batch, unit_pay="99"))
    session.commit()
    from yantra_payout.models import BatchRate

    assert session.get(BatchRate, batch).unit_pay == Decimal("28")


def earn_in_window(session, batch, worker, reviewer, when: datetime, n: int = 1):
    """Earnings at `when` for two workers who already have verified bank accounts."""
    verified_account(session, worker)
    verified_account(session, reviewer)
    for _ in range(n):
        env = accepted(batch, worker, reviewer)
        on_verdict_accepted(session, env)
        session.commit()
    for e in session.scalars(select(Earning).where(Earning.created_at > when)):
        e.created_at = when
    session.commit()


def test_close_window_lines_payable_earnings_and_holds_first_payouts(session):
    batch = seed_batch(session)
    old_hand, newcomer, reviewer = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    in_window = datetime(2026, 10, 27, 12, 0, tzinfo=IST)
    earn_in_window(session, batch, old_hand, reviewer, in_window, n=2)
    earn_in_window(session, batch, newcomer, reviewer, datetime(2026, 10, 30, 12, 0, tzinfo=IST), n=1)
    session.get(WorkerAccount, old_hand).first_paid_at = in_window - timedelta(days=30)
    session.get(WorkerAccount, reviewer).first_paid_at = in_window - timedelta(days=30)
    # an earning after the window end stays out of it
    earn_in_window(session, batch, old_hand, reviewer, datetime(2026, 11, 1, 12, 0, tzinfo=IST), n=1)
    session.commit()
    window = close_window(session, "INR", now=MONDAY)
    session.commit()
    lines = {line.worker_id: line for line in session.scalars(select(WindowLine))}
    assert lines[old_hand].gross == Decimal("56") and lines[old_hand].status == "payable"
    assert lines[reviewer].gross == Decimal("18") and lines[reviewer].earning_count == 3
    assert lines[newcomer].status == "held" and lines[newcomer].hold_reason == "first_payout"
    assert window.gross_total == Decimal("74") and window.held_total == Decimal("28")
    windowed = session.scalars(select(Earning).where(Earning.window_id == window.id)).all()
    assert len(windowed) == 5 and all(e.status == "windowed" for e in windowed)
    assert session.scalar(select(Earning).where(Earning.worker_id == newcomer)).status == "payable"
    assert events(session)[-1].type == "payout.window.closed.v1"
    assert events(session)[-1].payload["line_count"] == 3
    with pytest.raises(Conflict):
        close_window(session, "INR", now=MONDAY)


def test_an_integrity_hold_keeps_a_line_back(session):
    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 10, 27, 12, 0, tzinfo=IST))
    for w in (worker, reviewer):
        session.get(WorkerAccount, w).first_paid_at = MONDAY - timedelta(days=60)
    set_hold(session, worker, "duplicate_account", MONDAY + timedelta(days=3))
    session.commit()
    close_window(session, "INR", now=MONDAY)
    session.commit()
    line = session.scalar(select(WindowLine).where(WindowLine.worker_id == worker))
    assert line.status == "held" and line.hold_reason == "duplicate_account"
    assert statement(session, worker)["hold"] == "duplicate_account"


def test_two_distinct_approvals_release_the_window(session):
    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 10, 27, 12, 0, tzinfo=IST))
    for w in (worker, reviewer):
        session.get(WorkerAccount, w).first_paid_at = MONDAY - timedelta(days=60)
    session.commit()
    window = close_window(session, "INR", now=MONDAY)
    session.commit()
    approve_window(session, window.id, "finance lead")
    session.commit()
    assert window.status == "closed"
    with pytest.raises(Conflict) as e:
        approve_window(session, window.id, "finance lead")
    assert e.value.code == "already_approved"
    session.rollback()
    approve_window(session, window.id, "second approver")
    session.commit()
    session.refresh(window)
    assert window.status == "approved"
    with pytest.raises(Conflict):
        approve_window(session, window.id, "third")


def test_paying_every_line_settles_the_window_records_first_payouts_and_reconciles(session):
    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 10, 20, 12, 0, tzinfo=IST))
    session.commit()
    window = close_window(session, "INR", now=MONDAY)
    session.commit()
    with pytest.raises(Conflict):
        pay_out(session, window.id)
    session.rollback()
    approve_window(session, window.id, "a")
    approve_window(session, window.id, "b")
    session.commit()
    paid = pay_out(session, window.id, now=MONDAY)
    session.commit()
    assert paid.status == "paid" and paid.rail_reference == f"fake:{window.id.hex[:8]}" and paid.paid_at == MONDAY
    assert all(e.status == "paid" for e in session.scalars(select(Earning)))
    assert session.get(WorkerAccount, worker).first_paid_at == MONDAY
    paid_events = [e for e in events(session) if e.type == "payout.paid.v1"]
    assert {e.payload["worker_id"] for e in paid_events} == {str(worker), str(reviewer)}
    assert all(e.payload["utr"].startswith("UTR") and e.payload["line_id"] for e in paid_events)
    report = reconcile(session, window.id)
    assert report["balanced"] is True and report["earnings_total"] == "34.00" and report["delta"] == "0.00"
    assert statement(session, worker)["totals"] == {"paid": "28.00"}
    with pytest.raises(NotFound):
        reconcile(session, uuid.uuid4())


def test_reconcile_reports_a_delta_and_never_adjusts(session, caplog):
    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 10, 20, 12, 0, tzinfo=IST))
    window = close_window(session, "INR", now=MONDAY)
    session.commit()
    line = session.scalar(select(WindowLine).where(WindowLine.worker_id == worker))
    line.gross = Decimal("27")  # tampered
    session.commit()
    with caplog.at_level("ERROR", logger="yantra.payout"):
        report = reconcile(session, window.id)
    assert report["balanced"] is False and report["delta"] == "1.00"
    assert "reconciliation delta" in caplog.text
    session.refresh(line)
    assert line.gross == Decimal("27")


def test_margin_report_is_invoice_minus_every_cost_line(session):
    batch = seed_batch(session)
    worker, reviewer, auditor = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    on_verdict_accepted(session, accepted(batch, worker, reviewer))
    on_verdict_accepted(session, accepted(batch, worker, reviewer, auditor))
    on_verdict_rejected(session, rejected(batch, worker, reviewer, billable=True))
    session.commit()
    [row] = margin_report(session)
    assert row["units_judged"] == 3 and row["units_accepted"] == 2 and row["billable_rework_units"] == 1
    assert row["invoice"] == "120.00"
    assert (row["cost_pay"], row["cost_review"], row["cost_audit"]) == ("56.00", "18.00", "6.00")
    assert row["margin"] == "40.00" and row["margin_fraction"] == "0.3333"
    assert margin_report(session) == [row]


def test_a_rejection_with_an_auditor_pays_the_audit_too(session):
    batch = seed_batch(session)
    worker, reviewer, auditor = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    env = rejected(batch, worker, reviewer)
    env = envelope(env.type, {**env.data, "auditor_id": str(auditor)})
    on_verdict_rejected(session, env)
    session.commit()
    kinds = {(e.kind, e.worker_id) for e in session.scalars(select(Earning))}
    assert kinds == {("review", reviewer), ("audit", auditor)}


def test_a_held_earning_rolls_into_the_next_window(session):
    batch = seed_batch(session)
    newcomer, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, newcomer, reviewer, datetime(2026, 10, 30, 12, 0, tzinfo=IST))
    session.get(WorkerAccount, reviewer).first_paid_at = MONDAY - timedelta(days=60)
    session.commit()
    first = close_window(session, "INR", now=MONDAY)
    session.commit()
    held = session.scalar(select(WindowLine).where(WindowLine.window_id == first.id, WindowLine.worker_id == newcomer))
    assert held.status == "held"
    # a week later the seven days have passed: the earning lands in the next window, untouched in the first
    second = close_window(session, "INR", now=MONDAY + timedelta(days=7))
    session.commit()
    line = session.scalar(select(WindowLine).where(WindowLine.window_id == second.id, WindowLine.worker_id == newcomer))
    assert line.status == "payable" and line.gross == Decimal("28.00")
    earning = session.scalar(select(Earning).where(Earning.worker_id == newcomer))
    assert earning.status == "windowed" and earning.window_id == second.id
    session.refresh(held)
    assert held.status == "held" and first.gross_total == Decimal("6.00") and second.gross_total == Decimal("28.00")


def test_paying_leaves_held_lines_and_their_earnings_alone(session):
    batch = seed_batch(session)
    paid_worker, newcomer, reviewer = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, paid_worker, reviewer, datetime(2026, 10, 27, 12, 0, tzinfo=IST))
    earn_in_window(session, batch, newcomer, reviewer, datetime(2026, 10, 30, 12, 0, tzinfo=IST))
    for w in (paid_worker, reviewer):
        session.get(WorkerAccount, w).first_paid_at = MONDAY - timedelta(days=60)
    session.commit()
    window = close_window(session, "INR", now=MONDAY)
    approve_window(session, window.id, "a")
    approve_window(session, window.id, "b")
    session.commit()
    pay_out(session, window.id, now=MONDAY)
    session.commit()
    lines = {line.worker_id: line for line in session.scalars(select(WindowLine))}
    assert lines[newcomer].status == "held" and lines[paid_worker].status == "paid"
    newcomer_earning = session.scalar(select(Earning).where(Earning.worker_id == newcomer))
    assert newcomer_earning.status == "payable" and newcomer_earning.window_id is None
    assert session.get(WorkerAccount, newcomer).first_paid_at is None
    assert len([e for e in events(session) if e.type == "payout.paid.v1"]) == 2


def test_the_window_edge_is_inclusive_at_friday_midnight_and_exclusive_at_saturday(session):
    batch = seed_batch(session)
    friday_worker, saturday_worker, reviewer = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, friday_worker, reviewer, datetime(2026, 10, 30, 23, 59, 59, 999999, tzinfo=IST))
    earn_in_window(session, batch, saturday_worker, reviewer, datetime(2026, 10, 31, 0, 0, 0, tzinfo=IST))
    for w in (friday_worker, saturday_worker, reviewer):
        session.get(WorkerAccount, w).first_paid_at = MONDAY - timedelta(days=60)
    session.commit()
    window = close_window(session, "INR", now=MONDAY)
    session.commit()
    assert session.scalar(select(Earning).where(Earning.worker_id == friday_worker)).window_id == window.id
    assert session.scalar(select(Earning).where(Earning.worker_id == saturday_worker)).window_id is None
    assert window_bounds(datetime(2026, 10, 31, 0, 0, 0, tzinfo=IST))[1].astimezone(IST) == datetime(
        2026, 10, 30, 23, 59, 59, 999999, tzinfo=IST
    )


def test_amounts_are_paisa_from_the_start_so_lines_and_ledger_agree(session):
    batch = seed_batch(session, unit_pay="12.345", review_pay="0.125")
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 10, 27, 12, 0, tzinfo=IST))
    for w in (worker, reviewer):
        session.get(WorkerAccount, w).first_paid_at = MONDAY - timedelta(days=60)
    session.commit()
    amounts = {e.worker_id: e.amount for e in session.scalars(select(Earning))}
    assert amounts[worker] == Decimal("12.35") and amounts[reviewer] == Decimal("0.13")  # half up, not half even
    window = close_window(session, "INR", now=MONDAY)
    approve_window(session, window.id, "a")
    approve_window(session, window.id, "b")
    session.commit()
    line = session.scalar(select(WindowLine).where(WindowLine.worker_id == worker))
    assert line.gross == Decimal("12.35") and reconcile(session, window.id)["balanced"]


def test_a_resubmitted_unit_accumulates_cost_lines(session):
    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    rej = rejected(batch, worker, reviewer, billable=True)
    on_verdict_rejected(session, rej)
    acc = accepted(batch, worker, reviewer)
    acc = envelope(acc.type, {**acc.data, "unit_id": rej.data["unit_id"]})
    on_verdict_accepted(session, acc)
    session.commit()
    [row] = margin_report(session)
    assert row["units_judged"] == 1 and row["units_accepted"] == 1 and row["billable_rework_units"] == 1
    assert row["cost_review"] == "12.00" and row["invoice"] == "60.00" and row["margin"] == "20.00"


def test_two_closes_for_the_same_period_are_serialised(factory, session):
    from concurrent.futures import ThreadPoolExecutor

    from yantra_common.db import unit_of_work

    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 10, 27, 12, 0, tzinfo=IST))
    for w in (worker, reviewer):
        session.get(WorkerAccount, w).first_paid_at = MONDAY - timedelta(days=60)
    session.commit()

    def go(_: int) -> str:
        try:
            with unit_of_work(factory) as s:
                close_window(s, "INR", now=MONDAY)
            return "ok"
        except Conflict:
            return "conflict"

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(go, range(2))) == ["conflict", "ok"]
    assert len(session.scalars(select(WindowLine)).all()) == 2


def test_finance_lists_windows_and_their_lines(session):
    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 10, 27, 12, 0, tzinfo=IST), n=2)
    session.commit()
    window = close_window(session, "INR", now=MONDAY)
    session.commit()
    later = close_window(session, "INR", now=MONDAY + timedelta(days=7))
    session.commit()
    assert [w.id for w in list_windows(session)] == [later.id, window.id]  # newest first
    assert list_windows(session, "paid") == [] and len(list_windows(session, "closed")) == 2
    lines = window_lines(session, window.id)
    assert {line.worker_id for line in lines} == {worker, reviewer}
    assert all(line.status == "held" and line.hold_reason == "first_payout" for line in lines)
    with pytest.raises(NotFound):
        window_lines(session, uuid.uuid4())


# ---------- the statement ----------


def test_statement_weeks_are_twelve_pay_weeks_oldest_first_with_the_window_edges(session):
    """The current week straddles a month end (Sat 31 Oct to Fri 6 Nov 2026); Friday midnight stays in the
    previous week and Saturday 00:00 opens the next one, exactly as close_window cuts them."""
    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 8, 14, 23, 59, 59, tzinfo=IST))  # off the grid
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 8, 15, 0, 0, 0, tzinfo=IST))  # oldest week
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 10, 30, 23, 59, 59, 999999, tzinfo=IST))
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 10, 31, 0, 0, 0, tzinfo=IST), n=2)
    out = statement(session, worker, now=MONDAY)
    weeks = out["weeks"]
    assert len(weeks) == 12
    starts = [datetime.fromisoformat(w["starts_at"]).astimezone(IST) for w in weeks]
    ends = [datetime.fromisoformat(w["ends_at"]).astimezone(IST) for w in weeks]
    assert starts[0] == datetime(2026, 8, 15, 0, 0, tzinfo=IST)
    assert starts[-1] == datetime(2026, 10, 31, 0, 0, tzinfo=IST)
    assert ends[-1] == datetime(2026, 11, 6, 23, 59, 59, 999999, tzinfo=IST)
    assert all(e - s == timedelta(days=7, microseconds=-1) for s, e in zip(starts, ends, strict=True))
    assert all(starts[i + 1] - starts[i] == timedelta(days=7) for i in range(11))
    assert (weeks[0]["amount"], weeks[0]["count"], weeks[0]["currency"]) == ("28.00", 1, "INR")
    assert (weeks[-2]["amount"], weeks[-2]["count"]) == ("28.00", 1)
    assert (weeks[-1]["amount"], weeks[-1]["count"]) == ("56.00", 2)
    assert [w["count"] for w in weeks[1:-2]] == [0] * 9
    assert out["next_window_closes_at"] == ends[-1].astimezone(UTC).isoformat()
    # the reviewer's statement counts review earnings only: 5 reviews, 4 on the grid
    assert sum(w["count"] for w in statement(session, reviewer, now=MONDAY)["weeks"]) == 4


def test_statement_of_a_worker_without_money_has_twelve_zero_weeks_and_nulls(session):
    out = statement(session, uuid.uuid4(), now=MONDAY)
    assert out["totals"] == {} and out["hold"] is None and out["earnings"] == []
    assert out["account"] == {"first_paid_at": None, "hold_until": None, "hold_reason": None}
    assert out["windows"] == []
    assert out["weeks"] == [
        {"starts_at": w["starts_at"], "ends_at": w["ends_at"], "currency": "INR", "amount": "0.00", "count": 0}
        for w in out["weeks"]
    ]
    assert len(out["weeks"]) == 12
    assert out["pending_next"] == {"currency": "INR", "amount": "0.00", "count": 0}


def test_statement_lists_the_held_line_with_its_reason_and_the_account(session):
    batch = seed_batch(session)
    newcomer, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, newcomer, reviewer, datetime(2026, 10, 27, 12, 0, tzinfo=IST), n=2)
    set_hold(session, reviewer, "duplicate_account", MONDAY + timedelta(days=3))
    session.commit()
    window = close_window(session, "INR", now=MONDAY)
    session.commit()
    out = statement(session, newcomer, now=MONDAY)
    [line] = out["windows"]
    assert line == {
        "window_id": str(window.id),
        "starts_at": window.starts_at.astimezone(UTC).isoformat(),
        "ends_at": window.ends_at.astimezone(UTC).isoformat(),
        "currency": "INR",
        "window_status": "closed",
        "line_status": "held",
        "gross": "56.00",
        "earning_count": 2,
        "hold_reason": "first_payout",
        "utr": None,
        "failure_reason": None,
        "paid_at": None,
        "rail_reference": None,
        "closed_at": window.closed_at.astimezone(UTC).isoformat(),
    }
    assert out["account"] == {"first_paid_at": None, "hold_until": None, "hold_reason": None}
    # the held earnings are still payable: the next window will pick them up
    assert out["pending_next"] == {"currency": "INR", "amount": "56.00", "count": 2}
    reviewer_out = statement(session, reviewer, now=MONDAY)
    assert reviewer_out["windows"][0]["hold_reason"] == "duplicate_account"
    assert reviewer_out["account"] == {
        "first_paid_at": None,
        "hold_until": (MONDAY + timedelta(days=3)).astimezone(UTC).isoformat(),
        "hold_reason": "duplicate_account",
    }
    assert reviewer_out["hold"] == "duplicate_account"


def test_statement_lists_paid_windows_newest_first_with_the_rail_reference(session):
    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 10, 20, 12, 0, tzinfo=IST))
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 10, 27, 12, 0, tzinfo=IST), n=3)
    for w in (worker, reviewer):
        session.get(WorkerAccount, w).first_paid_at = MONDAY - timedelta(days=60)
    session.commit()
    first = close_window(session, "INR", now=MONDAY - timedelta(days=7))
    approve_window(session, first.id, "a")
    approve_window(session, first.id, "b")
    session.commit()
    pay_out(session, first.id, now=MONDAY - timedelta(days=6))
    second = close_window(session, "INR", now=MONDAY)
    session.commit()
    out = statement(session, worker, now=MONDAY)
    assert [w["window_id"] for w in out["windows"]] == [str(second.id), str(first.id)]
    newest, paid = out["windows"]
    assert (newest["window_status"], newest["line_status"], newest["gross"], newest["earning_count"]) == (
        "closed",
        "payable",
        "84.00",
        3,
    )
    assert (paid["window_status"], paid["line_status"], paid["gross"], paid["rail_reference"]) == (
        "paid",
        "paid",
        "28.00",
        f"fake:{first.id.hex[:8]}",
    )
    assert paid["utr"].startswith("UTR")
    assert paid["paid_at"] == (MONDAY - timedelta(days=6)).astimezone(UTC).isoformat()
    assert out["account"]["first_paid_at"] == (MONDAY - timedelta(days=60)).astimezone(UTC).isoformat()
    assert out["totals"] == {"paid": "28.00", "windowed": "84.00"}
    assert out["pending_next"] == {"currency": "INR", "amount": "0.00", "count": 0}
    # the paid week and the windowed week both show on the chart
    by_start = {datetime.fromisoformat(w["starts_at"]).astimezone(IST).day: w["amount"] for w in out["weeks"]}
    assert by_start[17] == "28.00" and by_start[24] == "84.00" and by_start[31] == "0.00"


def test_statement_pending_next_sums_payable_earnings_in_the_latest_currency(session):
    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, worker, reviewer, MONDAY - timedelta(hours=1), n=2)
    out = statement(session, worker, now=MONDAY)
    assert out["pending_next"] == {"currency": "INR", "amount": "56.00", "count": 2}
    assert out["weeks"][-1] == {
        "starts_at": out["weeks"][-1]["starts_at"],
        "ends_at": out["weeks"][-1]["ends_at"],
        "currency": "INR",
        "amount": "56.00",
        "count": 2,
    }
    assert out["totals"] == {"payable": "56.00"} and len(out["earnings"]) == 2
    # the statement without `now` uses the clock: the same week today
    assert statement(session, worker)["pending_next"]["amount"] == "56.00"


def test_statement_totals_cover_every_earning_while_the_list_is_capped(session):
    """`totals` and `pending_next` are summed in the database over all the worker's earnings; only the
    `earnings` list is cut at the limit."""
    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, worker, reviewer, MONDAY - timedelta(hours=1), n=3)
    out = statement(session, worker, now=MONDAY, limit=1)
    assert len(out["earnings"]) == 1
    assert out["totals"] == {"payable": "84.00"} and out["pending_next"]["count"] == 3


# ---------- adjustments (two-person), the ops overview and the account lookup ----------


def test_an_adjustment_is_proposed_by_one_person_and_approved_by_another_into_a_payable_earning(session):
    worker, ops1, ops2 = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    adj = propose_adjustment(session, worker, Decimal("150.005"), "INR", "bonus", "festival bonus", ops1)
    session.commit()
    assert adj.status == "pending" and adj.amount == Decimal("150.01") and adj.proposed_by == ops1
    assert adj.decided_by is None and adj.decided_at is None and adj.created_at is not None
    with pytest.raises(Conflict) as e:
        decide_adjustment(session, adj.id, ops1, "approved")
    assert e.value.code == "same_person"
    session.rollback()
    done = decide_adjustment(session, adj.id, ops2, "approved", note="agreed in standup")
    session.commit()
    assert done.status == "approved" and done.decided_by == ops2 and done.decided_at is not None
    assert done.decision_note == "agreed in standup"
    [earning] = session.scalars(select(Earning)).all()
    assert earning.kind == "adjust" and earning.status == "payable" and earning.amount == Decimal("150.01")
    assert earning.worker_id == worker and earning.currency == "INR"
    assert earning.event_id == earning.unit_id == earning.batch_id == adj.id  # an adjustment has no unit
    assert session.get(WorkerAccount, worker) is not None
    last = events(session)[-1]
    assert last.type == "payout.adjustment.approved.v1" and last.payload == {
        "adjustment_id": str(adj.id),
        "worker_id": str(worker),
        "amount": "150.01",
        "currency": "INR",
        "kind": "bonus",
    }
    with pytest.raises(Conflict) as e:
        decide_adjustment(session, adj.id, ops2, "rejected")
    assert e.value.code == "already_decided"
    session.rollback()
    with pytest.raises(NotFound):
        decide_adjustment(session, uuid.uuid4(), ops2, "approved")
    with pytest.raises(Invalid):
        decide_adjustment(session, adj.id, ops2, "maybe")
    for amount in (Decimal("0"), Decimal("-1"), Decimal("0.004")):
        with pytest.raises(Invalid):
            propose_adjustment(session, worker, amount, "INR", "correction", "x", ops1)
    with pytest.raises(Invalid):
        propose_adjustment(session, worker, Decimal("1"), "INR", "refund", "x", ops1)


def test_a_rejected_adjustment_moves_no_money_and_the_list_is_newest_first_with_a_status_filter(session):
    worker, ops1, ops2 = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    first = propose_adjustment(session, worker, Decimal("10"), "INR", "correction", "missed unit", ops1)
    session.commit()
    second = propose_adjustment(session, worker, Decimal("20"), "INR", "bonus", "referral", ops1)
    session.commit()
    rejected = decide_adjustment(session, second.id, ops2, "rejected", note="not this quarter")
    session.commit()
    assert rejected.status == "rejected" and rejected.decision_note == "not this quarter"
    assert session.scalars(select(Earning)).all() == [] and events(session) == []
    assert [a.id for a in list_adjustments(session)] == [second.id, first.id]
    assert [a.id for a in list_adjustments(session, "pending")] == [first.id]
    assert [a.id for a in list_adjustments(session, "rejected")] == [second.id]
    assert list_adjustments(session, "approved") == []


def test_an_approved_adjustment_is_windowed_with_the_rest_and_shows_as_adjust_on_the_statement(session):
    worker, ops1, ops2 = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    adj = propose_adjustment(session, worker, Decimal("150"), "INR", "bonus", "festival bonus", ops1)
    session.commit()
    decide_adjustment(session, adj.id, ops2, "approved")
    verified_account(session, worker)
    session.commit()
    session.get(WorkerAccount, worker).first_paid_at = MONDAY - timedelta(days=60)
    for e in session.scalars(select(Earning)):
        e.created_at = datetime(2026, 10, 27, 12, 0, tzinfo=IST)
    session.commit()
    window = close_window(session, "INR", now=MONDAY)
    session.commit()
    [line] = session.scalars(select(WindowLine).where(WindowLine.window_id == window.id)).all()
    assert line.worker_id == worker and line.gross == Decimal("150") and line.earning_count == 1
    assert line.status == "payable" and window.gross_total == Decimal("150")
    out = statement(session, worker, now=MONDAY)
    [row] = out["earnings"]
    assert row["kind"] == "adjust" and row["status"] == "windowed" and row["amount"] == "150.00"
    assert row["unit_id"] == str(adj.id) and row["window_id"] == str(window.id)
    assert out["totals"] == {"windowed": "150.00"} and out["windows"][0]["earning_count"] == 1
    assert reconcile(session, window.id)["balanced"] is True


def test_the_ops_overview_splits_payable_from_held_and_counts_the_rest(session):
    batch = seed_batch(session)
    paid_worker, paid_reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, paid_worker, paid_reviewer, datetime(2026, 10, 27, 12, 0, tzinfo=IST))
    for w in (paid_worker, paid_reviewer):
        session.get(WorkerAccount, w).first_paid_at = MONDAY - timedelta(days=60)
    session.commit()
    window = close_window(session, "INR", now=MONDAY)
    approve_window(session, window.id, "one")
    approve_window(session, window.id, "two")
    pay_out(session, window.id, now=MONDAY)
    session.commit()
    worker, reviewer, ops1, ops2 = uuid.uuid4(), uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    on_verdict_accepted(session, accepted(batch, worker, reviewer))
    verified_account(session, worker)
    verified_account(session, reviewer)
    session.commit()
    session.get(WorkerAccount, worker).first_paid_at = MONDAY - timedelta(days=60)
    set_hold(session, reviewer, "integrity", MONDAY + timedelta(days=30))
    bonus = propose_adjustment(session, worker, Decimal("150"), "INR", "bonus", "festival bonus", ops1)
    decide_adjustment(session, bonus.id, ops2, "approved")
    propose_adjustment(session, worker, Decimal("5"), "INR", "correction", "waiting", ops1)
    session.commit()
    now = MONDAY + timedelta(days=1)
    out = overview(session, now=now)
    assert out["payable_now"] == {"INR": "178.00"}  # the unit pay and the bonus; the held reviewer is not in it
    assert out["held_total"] == {"INR": "6.00"} and out["paid_total"] == {"INR": "34.00"}
    assert out["windows"] == {"closed": 0, "approved": 0, "paying": 0, "paid": 1} and out["pending_adjustments"] == 1
    assert out["margin_total"] == {"INR": "52.00"}  # two accepted units: 60 - (28 + 6) each
    starts, ends = window_bounds(now + timedelta(days=7))
    assert out["open_window"]["starts_at"] == starts.isoformat() and out["open_window"]["ends_at"] == ends.isoformat()
    assert out["open_window"]["closes_in_seconds"] == int((ends - now).total_seconds()) > 0
    newcomer = uuid.uuid4()
    on_verdict_accepted(session, accepted(batch, newcomer, reviewer))
    session.commit()
    fresh = overview(session, now=datetime.now(UTC))  # the newcomer's first payout is held for seven days
    assert fresh["held_total"] == {"INR": "40.00"} and fresh["payable_now"] == {"INR": "178.00"}


def test_the_overview_of_an_empty_ledger_is_all_zeros(session):
    out = overview(session, now=MONDAY)
    assert out["payable_now"] == {} and out["paid_total"] == {} and out["held_total"] == {}
    assert out["windows"] == {"closed": 0, "approved": 0, "paying": 0, "paid": 0} and out["pending_adjustments"] == 0
    assert out["margin_total"] == {} and out["open_window"]["closes_in_seconds"] > 0


def test_the_account_lookup_sums_the_workers_money_by_state(session):
    batch = seed_batch(session)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    earn_in_window(session, batch, worker, reviewer, datetime(2026, 10, 27, 12, 0, tzinfo=IST))
    for w in (worker, reviewer):
        session.get(WorkerAccount, w).first_paid_at = MONDAY - timedelta(days=60)
    session.commit()
    window = close_window(session, "INR", now=MONDAY)
    approve_window(session, window.id, "one")
    approve_window(session, window.id, "two")
    pay_out(session, window.id, now=MONDAY)
    on_verdict_accepted(session, accepted(batch, worker, reviewer))
    set_hold(session, reviewer, "integrity", MONDAY + timedelta(days=30))
    session.commit()
    now = MONDAY + timedelta(days=1)
    out = account_summary(session, worker, now=now)
    assert out["account"]["worker_id"] == str(worker) and out["account"]["hold_reason"] is None
    assert out["totals"] == {"payable": "28.00", "paid": "28.00", "held": "0.00", "currency": "INR"}
    held = account_summary(session, reviewer, now=now)
    assert held["account"]["hold_reason"] == "integrity" and held["account"]["hold_until"] is not None
    assert held["totals"] == {"payable": "0.00", "paid": "6.00", "held": "6.00", "currency": "INR"}
    with pytest.raises(NotFound):
        account_summary(session, uuid.uuid4(), now=now)
    assert session.scalar(select(Adjustment)) is None


# ---------- safeguards: the per-worker cap, the close's one read, people acting on themselves, consent ----------


def earn(session, worker, amount, at, kind="unit"):
    session.add(
        Earning(
            event_id=uuid.uuid4(),
            kind=kind,
            worker_id=worker,
            unit_id=uuid.uuid4(),
            batch_id=uuid.uuid4(),
            amount=Decimal(amount),
            currency="INR",
            created_at=at,
        )
    )


def paid_before(session, *workers):
    for w in workers:
        verified_account(session, w)
        session.merge(WorkerAccount(worker_id=w, first_paid_at=MONDAY - timedelta(days=60)))
    session.flush()


IN_WEEK = datetime(2026, 10, 27, 12, 0, tzinfo=IST)


def test_a_worker_over_the_cap_is_paid_up_to_it_and_the_rest_rolls_on_as_payable(session):
    rich, huge = uuid.uuid4(), uuid.uuid4()
    paid_before(session, rich, huge)
    for minutes in range(3):
        earn(session, rich, "30.00", IN_WEEK + timedelta(minutes=minutes))
    earn(session, huge, "100.00", IN_WEEK)
    session.commit()
    window = close_window(session, "INR", now=MONDAY, max_per_worker=Decimal("70"))
    lines = {line.worker_id: line for line in window_lines(session, window.id)}
    assert (lines[rich].status, lines[rich].gross, lines[rich].earning_count) == ("payable", Decimal("60.00"), 2)
    assert (lines[huge].status, lines[huge].hold_reason) == ("held", "over_cap")  # one earning above the cap
    statuses = sorted(e.status for e in session.scalars(select(Earning).where(Earning.worker_id == rich)))
    assert statuses == ["payable", "windowed", "windowed"]
    assert window.gross_total == Decimal("60.00") and window.held_total == Decimal("100.00")
    assert reconcile(session, window.id)["balanced"] is True
    nxt = close_window(session, "INR", now=MONDAY + timedelta(days=7), max_per_worker=Decimal("70"))
    carried = {line.worker_id: line for line in window_lines(session, nxt.id)}[rich]
    assert (carried.status, carried.gross, carried.hold_reason) == ("payable", Decimal("30.00"), None)


def test_close_lines_exactly_the_earnings_it_read(session, engine):
    from sqlalchemy import event

    worker = uuid.uuid4()
    paid_before(session, worker)
    earn(session, worker, "10.00", IN_WEEK)
    session.commit()
    late = uuid.uuid4()
    state = {"window_inserted": False, "done": False}

    def commit_a_late_earning(conn, cursor, statement, parameters, context, executemany):
        if statement.startswith("INSERT INTO payout.pay_window"):
            state["window_inserted"] = True
        elif state["window_inserted"] and not state["done"] and "FROM payout.earning" in statement:
            state["done"] = True
            with engine.begin() as other:
                other.execute(
                    Earning.__table__.insert().values(
                        id=late,
                        event_id=uuid.uuid4(),
                        kind="unit",
                        worker_id=worker,
                        unit_id=uuid.uuid4(),
                        batch_id=uuid.uuid4(),
                        amount=Decimal("5.00"),
                        currency="INR",
                        status="payable",
                        created_at=IN_WEEK,
                    )
                )

    event.listen(engine, "after_cursor_execute", commit_a_late_earning)
    try:
        window = close_window(session, "INR", now=MONDAY)
        session.commit()
    finally:
        event.remove(engine, "after_cursor_execute", commit_a_late_earning)
    assert state["done"]
    assert reconcile(session, window.id)["balanced"] is True
    session.expire_all()
    left = session.get(Earning, late)
    assert (left.status, left.window_id) == ("payable", None)  # the next close picks it up


def test_nobody_proposes_or_decides_an_adjustment_for_themselves(session):
    worker, colleague = uuid.uuid4(), uuid.uuid4()
    with pytest.raises(Conflict) as e:
        propose_adjustment(session, worker, Decimal("10"), "INR", "bonus", "mine", proposed_by=worker)
    assert e.value.code == "same_person"
    adjustment = propose_adjustment(session, worker, Decimal("10"), "INR", "bonus", "great week", proposed_by=colleague)
    with pytest.raises(Conflict) as e:
        decide_adjustment(session, adjustment.id, worker, "approved")
    assert e.value.code == "same_person"
    assert adjustment.status == "pending"


def test_a_manual_hold_never_targets_the_caller_or_shortens_an_integrity_or_bank_change_hold(session):
    from yantra_payout.service import on_anomaly_upheld

    worker, operator = uuid.uuid4(), uuid.uuid4()
    with pytest.raises(Conflict) as e:
        set_hold(session, operator, None, None, by=operator)
    assert e.value.code == "same_person"
    env = envelope(
        "tracking.anomaly.upheld.v1",
        {
            "anomaly_id": str(uuid.uuid4()),
            "worker_id": str(worker),
            "session_id": None,
            "kind": "duplicate_device",
            "decided_by": str(uuid.uuid4()),
        },
    )
    on_anomaly_upheld(session, env, hold_days=30)
    until = env.occurred_at + timedelta(days=30)
    for shorter in (None, until - timedelta(days=1)):
        account = set_hold(session, worker, "cleared", shorter, by=operator)
        assert (account.hold_reason, account.hold_until) == ("integrity", until)
    longer = until + timedelta(days=5)
    assert set_hold(session, worker, "under review", longer, by=operator).hold_until == longer
    changed = uuid.uuid4()
    session.add(WorkerAccount(worker_id=changed, hold_reason="bank_change", hold_until=MONDAY + timedelta(days=3)))
    session.flush()
    assert set_hold(session, changed, None, None, by=operator, now=MONDAY).hold_reason == "bank_change"
    # a lapsed protected hold is no hold: an operator may set anything
    assert set_hold(session, changed, None, None, by=operator, now=MONDAY + timedelta(days=4)).hold_until is None


def test_withdrawn_consent_holds_payouts_until_consent_is_given_again(session):
    from yantra_payout.paying import live_hold
    from yantra_payout.service import held_accounts, on_consent_given, on_consent_withdrawn

    worker = uuid.uuid4()
    paid_before(session, worker)
    earn(session, worker, "10.00", IN_WEEK)
    session.commit()
    withdrawn = envelope("worker.consent.withdrawn.v1", {"worker_id": str(worker)})
    on_consent_withdrawn(session, withdrawn)
    on_consent_withdrawn(session, withdrawn)  # redelivered
    account = session.get(WorkerAccount, worker)
    assert account.consent_withdrawn and account.hold_until is None
    assert live_hold(session, worker, MONDAY) == "consent_withdrawn"
    assert held_accounts(session, MONDAY)["items"] == [
        {"worker_id": str(worker), "hold_reason": "consent_withdrawn", "hold_until": None, "first_paid_at": ANY}
    ]
    assert statement(session, worker, MONDAY)["hold"] == "consent_withdrawn"
    window = close_window(session, "INR", now=MONDAY)
    [line] = window_lines(session, window.id)
    assert (line.status, line.hold_reason) == ("held", "consent_withdrawn")
    older = envelope("worker.consent.given.v1", {"worker_id": str(worker)})
    older = dataclasses.replace(older, occurred_at=withdrawn.occurred_at - timedelta(minutes=1))
    on_consent_given(session, older)  # given before the withdrawal, delivered late: changes nothing
    assert session.get(WorkerAccount, worker).consent_withdrawn
    on_consent_given(session, envelope("worker.consent.given.v1", {"worker_id": str(worker)}))
    assert not session.get(WorkerAccount, worker).consent_withdrawn and live_hold(session, worker, MONDAY) is None
    # withdrawing and giving consent again never clears an integrity hold
    other = uuid.uuid4()
    set_hold(session, other, "integrity", MONDAY + timedelta(days=30))
    on_consent_withdrawn(session, envelope("worker.consent.withdrawn.v1", {"worker_id": str(other)}))
    on_consent_given(session, envelope("worker.consent.given.v1", {"worker_id": str(other)}))
    assert live_hold(session, other, MONDAY) == "integrity"
    # finance lifts a consent hold by hand
    third = uuid.uuid4()
    on_consent_withdrawn(session, envelope("worker.consent.withdrawn.v1", {"worker_id": str(third)}))
    assert not set_hold(session, third, None, None, by=uuid.uuid4()).consent_withdrawn
