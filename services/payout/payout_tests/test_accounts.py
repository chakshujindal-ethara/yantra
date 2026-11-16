"""The bank account a worker is paid into: sealed, registered with the rail, verified by the penny drop, one per
number, a few checks a day, and a 72-hour hold when a verified account changes. Close holds a line without one."""

import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest
from sqlalchemy import select

from yantra_common.errors import Conflict, NotFound
from yantra_payout.accounts import (
    AccountIn,
    RailDown,
    TooManyValidations,
    account_view,
    get_account,
    poll_verifying,
    register_account,
)
from yantra_payout.models import OUTBOX, BankAccount, WindowLine, WorkerAccount
from yantra_payout.rails import RailError, RailUnavailable, Validation
from yantra_payout.rails.fake import FakeRail
from yantra_payout.rails.file import FileRail
from yantra_payout.service import IST, close_window, on_unit_published, on_verdict_accepted
from yantra_payout.testing import accepted, published, verified_account

NOW = datetime(2026, 11, 4, 10, 0, tzinfo=UTC)
GOOD = AccountIn("Asha Rao", "123456789012", "HDFC0001234")


def events(session, type_):
    return [p for t, p in session.execute(select(OUTBOX.c.type, OUTBOX.c.payload)) if t == type_]


def test_an_account_is_sealed_registered_and_pending_until_the_penny_drop_answers(session, factory, caplog):
    rail = FakeRail()
    worker = uuid.uuid4()
    with caplog.at_level("DEBUG"):
        account = register_account(session, rail, worker, GOOD, NOW)
    session.commit()
    assert account.status == "verifying" and account.verification == "penny_drop"
    assert account.account_last4 == "9012" and account.ifsc == "HDFC0001234"
    assert b"123456789012" not in account.account_sealed and account.key_id
    assert rail.calls == ["register", "start_validation"]
    view = account_view(account)
    assert "123456789012" not in str(view) and view["status"] == "verifying"
    assert "123456789012" not in caplog.text
    # the same account again is a no-op, not a second paid check
    assert register_account(session, rail, worker, GOOD, NOW) is account and rail.calls.count("register") == 1
    session.commit()
    assert poll_verifying(factory, rail, NOW) == 1
    session.expire_all()
    account = get_account(session, worker)
    assert account.status == "verified" and account.registered_name_match is True and account.verified_at == NOW
    [event] = events(session, "payout.account.verified.v1")
    assert event["worker_id"] == str(worker) and event["account_last4"] == "9012"
    assert event["verification"] == "penny_drop" and len(event["account_name_hash"]) == 64
    assert poll_verifying(factory, rail, NOW) == 0


def test_an_invalid_account_or_another_name_fails_with_the_reason(session, factory):
    rail = FakeRail()
    invalid, other = uuid.uuid4(), uuid.uuid4()
    register_account(session, rail, invalid, AccountIn("Asha Rao", "123456780000", "HDFC0001234"), NOW)
    register_account(session, rail, other, AccountIn("Asha Rao", "123456781111", "HDFC0001234"), NOW)
    session.commit()
    assert poll_verifying(factory, rail, NOW) == 2
    session.expire_all()
    assert get_account(session, invalid).failure_reason == "invalid_account"
    mismatch = get_account(session, other)
    assert (mismatch.status, mismatch.failure_reason, mismatch.registered_name_match) == (
        "failed",
        "name_mismatch",
        False,
    )
    assert {e["reason"] for e in events(session, "payout.account.rejected.v1")} == {"invalid_account", "name_mismatch"}


def test_one_account_per_number_and_a_few_checks_a_day(session):
    rail = FakeRail()
    first, second = uuid.uuid4(), uuid.uuid4()
    register_account(session, rail, first, GOOD, NOW)
    session.commit()
    with pytest.raises(Conflict) as e:
        register_account(session, rail, second, GOOD, NOW)
    assert e.value.code == "account_in_use"
    session.rollback()
    for n in range(2):
        register_account(session, rail, second, AccountIn("B", f"99999999{n}000", "HDFC0001234"), NOW)
    with pytest.raises(TooManyValidations):
        register_account(session, rail, second, AccountIn("B", "999999992111", "HDFC0001234"), NOW, 2)
    session.rollback()
    tomorrow = NOW + timedelta(days=1, minutes=1)
    assert register_account(session, rail, second, AccountIn("B", "999999993111", "HDFC0001234"), tomorrow, 2)


def test_changing_a_verified_account_holds_payouts_for_72_hours_and_checks_again(session):
    rail = FakeRail()
    worker = uuid.uuid4()
    verified_account(session, worker)
    session.add(WorkerAccount(worker_id=worker, hold_until=NOW + timedelta(days=30), hold_reason="integrity"))
    session.commit()
    account = register_account(session, rail, worker, AccountIn("Asha Rao", "555566667777", "ICIC0000001"), NOW)
    assert account.status == "verifying" and account.account_last4 == "7777"
    held = session.get(WorkerAccount, worker)
    assert held.hold_reason == "integrity"  # a longer hold is never shortened
    other = uuid.uuid4()
    verified_account(session, other)
    register_account(session, rail, other, AccountIn("Asha Rao", "555566668888", "ICIC0000001"), NOW)
    hold = session.get(WorkerAccount, other)
    assert (hold.hold_reason, hold.hold_until) == ("bank_change", NOW + timedelta(hours=72))


def test_a_rail_without_a_penny_drop_registers_the_account_as_given(session):
    account = register_account(session, FileRail(), uuid.uuid4(), GOOD, NOW)
    assert (account.status, account.verification, account.registered_name_match) == ("verified", "none", None)
    assert events(session, "payout.account.verified.v1")[0]["verification"] == "none"


def test_a_refusing_rail_fails_the_account_and_a_down_rail_is_503(session):
    class Refusing(FakeRail):
        def register(self, *a):
            raise RailError("BAD_REQUEST_ERROR")

    class Down(FakeRail):
        def register(self, *a):
            raise RailUnavailable("down")

    worker = uuid.uuid4()
    assert register_account(session, Refusing(), worker, GOOD, NOW).failure_reason == "rail_error"
    with pytest.raises(RailDown):
        register_account(session, Down(), uuid.uuid4(), AccountIn("C", "444455556666", "HDFC0001234"), NOW)


def test_late_news_and_lookups_that_fail_change_nothing(session, factory):
    from yantra_payout.accounts import complete_validation

    class Flaky(FakeRail):
        def fetch_validation(self, validation_id):
            raise RailUnavailable("down")

    worker = uuid.uuid4()
    account = register_account(session, FakeRail(), worker, GOOD, NOW)
    session.commit()
    assert poll_verifying(factory, Flaky(), NOW) == 0
    complete_validation(session, account, Validation("x", "pending"), NOW)
    assert account.status == "verifying"
    complete_validation(session, account, Validation("x", "verified"), NOW)  # a rail with no registered name
    assert account.status == "verified" and account.registered_name_match is None
    complete_validation(session, account, Validation("x", "failed", reason="late"), NOW)
    assert account.status == "verified"
    with pytest.raises(NotFound):
        get_account(session, uuid.uuid4())
    assert account_view(None) is None


def test_close_holds_a_line_without_a_verified_account_and_one_over_the_worker_cap(session):
    batch, worker, reviewer, rich = uuid.uuid4(), uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    on_unit_published(session, published(batch))
    for env in (accepted(batch, worker, reviewer), accepted(batch, rich, reviewer), accepted(batch, rich, reviewer)):
        on_verdict_accepted(session, env)
    verified_account(session, reviewer)
    verified_account(session, rich)
    session.flush()
    for w in (worker, reviewer, rich):
        session.get(WorkerAccount, w).first_paid_at = NOW - timedelta(days=60)
    session.commit()
    close_window(session, "INR", now=datetime.now(IST) + timedelta(days=8), max_per_worker=Decimal("50"))
    lines = {line.worker_id: line for line in session.scalars(select(WindowLine))}
    assert (lines[worker].status, lines[worker].hold_reason) == ("held", "account_unverified")
    # over the cap: paid up to it, the rest stays payable for the next window (never held for good)
    assert (lines[rich].status, lines[rich].gross, lines[rich].earning_count) == ("payable", Decimal("28"), 1)
    assert lines[reviewer].status == "payable"
    assert session.scalar(select(BankAccount).where(BankAccount.worker_id == worker)) is None


def test_an_erased_worker_loses_the_bank_account_once_nothing_is_owed(session):
    from yantra_payout.accounts import erase_when_paid, on_erasure_completed
    from yantra_payout.paying import pay_window, release_line, settle_line
    from yantra_payout.rails import PayoutResult
    from yantra_payout.service import approve_window
    from yantra_payout.testing import envelope

    assert erase_when_paid(session, uuid.uuid4()) is True  # nothing to erase
    owed, paid_up = uuid.uuid4(), uuid.uuid4()
    verified_account(session, paid_up)
    session.commit()
    on_erasure_completed(session, envelope("worker.erasure.completed.v1", {"worker_id": str(paid_up)}))
    assert session.get(BankAccount, paid_up) is None
    batch, reviewer = uuid.uuid4(), uuid.uuid4()
    on_unit_published(session, published(batch))
    on_verdict_accepted(session, accepted(batch, owed, reviewer))
    on_verdict_accepted(session, accepted(batch, owed, reviewer))
    verified_account(session, owed)
    verified_account(session, reviewer)
    session.flush()
    for w in (owed, reviewer):
        session.get(WorkerAccount, w).first_paid_at = NOW - timedelta(days=60)
    session.commit()
    window = close_window(session, "INR", now=datetime.now(IST) + timedelta(days=8))
    approve_window(session, window.id, "a")
    approve_window(session, window.id, "b")
    pay_window(session, window.id, "fake", Decimal("1e9"))
    session.commit()
    on_erasure_completed(session, envelope("worker.erasure.completed.v1", {"worker_id": str(owed)}))
    assert session.get(BankAccount, owed).erasure_requested_at is not None  # still owed money: kept to pay it
    erase_when_paid(session, owed)  # asked again: still owed, the mark stays
    lines = {x.worker_id: x for x in session.scalars(select(WindowLine).where(WindowLine.window_id == window.id))}
    lines[owed].status = "processing"
    settle_line(session, lines[owed], PayoutResult("p1", "paid", utr="U", reference_id=f"{lines[owed].id}:1"))
    assert session.get(BankAccount, owed) is None  # paid: the account goes
    lines[reviewer].status = "processing"
    settle_line(
        session, lines[reviewer], PayoutResult("p2", "failed", reason="x", reference_id=f"{lines[reviewer].id}:1")
    )
    session.get(BankAccount, reviewer).erasure_requested_at = NOW
    release_line(session, window.id, lines[reviewer].id)
    assert session.get(BankAccount, reviewer) is not None  # released: still owed (payable for the next close)


# ---------- safeguards: erasure waits for payable money, an unproven name waits for finance, the race ----------


def test_erasure_waits_for_payable_earnings_outside_any_window(session):
    from yantra_payout.accounts import on_erasure_completed
    from yantra_payout.paying import attention
    from yantra_payout.service import approve_window
    from yantra_payout.testing import envelope, pay_out

    batch, worker, reviewer = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    on_unit_published(session, published(batch))
    on_verdict_accepted(session, accepted(batch, worker, reviewer))
    verified_account(session, worker)
    verified_account(session, reviewer)
    session.flush()
    for w in (worker, reviewer):
        session.get(WorkerAccount, w).first_paid_at = NOW - timedelta(days=60)
    session.commit()
    on_erasure_completed(session, envelope("worker.erasure.completed.v1", {"worker_id": str(worker)}))
    account = session.get(BankAccount, worker)
    assert account is not None and account.erasure_requested_at is not None  # owed money no window holds yet
    assert attention(session)["erasures_pending"] == 1
    window = close_window(session, "INR", now=datetime.now(IST) + timedelta(days=8))
    approve_window(session, window.id, "a")
    approve_window(session, window.id, "b")
    pay_out(session, window.id)
    assert session.get(BankAccount, worker) is None  # paid: the account goes
    assert attention(session)["erasures_pending"] == 0


def test_a_penny_drop_without_a_registered_name_waits_for_finance_to_confirm(session):
    from yantra_payout.accounts import complete_validation, confirm_account, verified_fund_account
    from yantra_payout.paying import attention

    worker, finance = uuid.uuid4(), uuid.uuid4()
    account = register_account(session, FakeRail(), worker, GOOD, NOW)
    complete_validation(session, account, Validation(account.validation_id or "", "verified"), NOW)
    assert (account.status, account.registered_name_match) == ("verified", None)
    assert account_view(account)["awaiting_confirmation"] is True
    assert verified_fund_account(session, worker) is None
    assert attention(session)["accounts_awaiting_confirmation"] == 1
    batch = uuid.uuid4()
    on_unit_published(session, published(batch))
    on_verdict_accepted(session, accepted(batch, worker, uuid.uuid4()))
    session.get(WorkerAccount, worker).first_paid_at = NOW - timedelta(days=60)
    session.commit()
    close_window(session, "INR", now=datetime.now(IST) + timedelta(days=8))
    line = session.scalar(select(WindowLine).where(WindowLine.worker_id == worker))
    assert (line.status, line.hold_reason) == ("held", "account_unconfirmed")
    with pytest.raises(Conflict) as e:
        confirm_account(session, worker, by=worker, now=NOW)
    assert e.value.code == "same_person"
    confirmed = confirm_account(session, worker, by=finance, now=NOW)
    assert (confirmed.confirmed_by, confirmed.confirmed_at) == (finance, NOW)
    assert account_view(confirmed)["awaiting_confirmation"] is False
    assert verified_fund_account(session, worker) is confirmed
    with pytest.raises(Conflict) as e:
        confirm_account(session, worker, by=finance, now=NOW)
    assert e.value.code == "not_awaiting_confirmation"
    with pytest.raises(NotFound):
        confirm_account(session, uuid.uuid4(), by=finance, now=NOW)
    # a new account starts unconfirmed again
    again = register_account(session, FakeRail(), worker, AccountIn("Asha Rao", "222233334444", "HDFC0001234"), NOW)
    assert again.confirmed_at is None and again.confirmed_by is None


def test_two_workers_registering_one_account_at_once_is_a_409_not_a_500(session, factory, engine):
    from sqlalchemy import event

    first, second = uuid.uuid4(), uuid.uuid4()
    state = {"done": False}

    def the_other_worker_commits_first(conn, cursor, statement, parameters, context, executemany):
        if not state["done"] and "bank_account.account_hash =" in statement:
            state["done"] = True
            with factory() as other:
                verified_account(other, first, number=GOOD.account_number, ifsc=GOOD.ifsc)
                other.commit()

    event.listen(engine, "after_cursor_execute", the_other_worker_commits_first)
    try:
        with pytest.raises(Conflict) as e:
            register_account(session, FakeRail(), second, GOOD, NOW)
    finally:
        event.remove(engine, "after_cursor_execute", the_other_worker_commits_first)
    assert state["done"] and e.value.code == "account_in_use"
