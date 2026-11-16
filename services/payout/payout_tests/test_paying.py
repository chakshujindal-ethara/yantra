"""Paying a window line by line on a rail: queue, dispatch, poll, settle (rank-ordered, idempotent), retry and
release a failed line, the bank file and its return file, the RazorpayX webhook, reconciliation runs, the statement
export, finance's attention list and the scheduled jobs."""

import hashlib
import hmac
import json
import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest
from sqlalchemy import func, select

from yantra_common.errors import Conflict, Invalid, NotFound, Unauthorized
from yantra_payout import paying
from yantra_payout.config import PayoutSettings
from yantra_payout.jobs import close_due_windows, payout_jobs
from yantra_payout.models import (
    OUTBOX,
    Approval,
    BankAccount,
    Earning,
    PayWindow,
    ReconciliationRun,
    WebhookEvent,
    WindowLine,
    WorkerAccount,
)
from yantra_payout.rails import PayoutResult, RailError, RailUnavailable, RailUnknownOutcome
from yantra_payout.rails.fake import FakeRail
from yantra_payout.service import (
    IST,
    approve_window,
    close_window,
    get_window,
    held_accounts,
    on_anomaly_upheld,
    set_hold,
)
from yantra_payout.testing import envelope, pay_out, verified_account

MONDAY = datetime(2026, 11, 2, 10, 0, tzinfo=IST)
IN_WINDOW = datetime(2026, 10, 27, 12, 0, tzinfo=IST)
CAP = Decimal("1000000")
SECRET = "whsec_test"


def events(session, type_):
    return [p for t, p in session.execute(select(OUTBOX.c.type, OUTBOX.c.payload)) if t == type_]


def approved(
    session, amounts: list[str], approve: bool = True, weeks_later: int = 0
) -> tuple[PayWindow, list[uuid.UUID]]:
    """A closed (and approved) window with one line per amount, every worker verified and long paid before. Each
    call in one test needs its own week: `weeks_later`."""
    shift = timedelta(days=7 * weeks_later)
    workers = []
    for amount in amounts:
        w = uuid.uuid4()
        workers.append(w)
        verified_account(session, w)
        session.add(WorkerAccount(worker_id=w, first_paid_at=MONDAY - timedelta(days=60)))
        session.add(
            Earning(
                event_id=uuid.uuid4(),
                kind="unit",
                worker_id=w,
                unit_id=uuid.uuid4(),
                batch_id=uuid.uuid4(),
                amount=Decimal(amount),
                currency="INR",
                created_at=IN_WINDOW + shift,
            )
        )
    session.commit()
    window = close_window(session, "INR", now=MONDAY + shift)
    if approve:
        approve_window(session, window.id, "a")
        approve_window(session, window.id, "b")
    session.commit()
    return window, workers


def lines_of(session, window_id) -> dict[uuid.UUID, WindowLine]:
    session.expire_all()
    return {
        line.worker_id: line for line in session.scalars(select(WindowLine).where(WindowLine.window_id == window_id))
    }


def test_a_window_is_paid_line_by_line_and_a_failed_line_is_retried_or_released(session, factory, caplog):
    window, (good, broke, closed) = approved(session, ["28.00", "28.13", "28.99"])
    with pytest.raises(Conflict) as e:
        paying.pay_window(session, window.id, "fake", Decimal("50"))
    assert e.value.code == "window_over_cap"
    session.rollback()
    paid = paying.pay_window(session, window.id, "fake", CAP)
    session.commit()
    assert paid.status == "paying" and paid.rail == "fake" and paid.rail_reference == f"fake:{window.id.hex[:8]}"
    lines = lines_of(session, window.id)
    assert {line.status for line in lines.values()} == {"queued"}
    assert len({line.idempotency_key for line in lines.values()}) == 3
    assert lines[good].idempotency_key == f"{lines[good].id}:1"
    with pytest.raises(Conflict):
        paying.pay_window(session, window.id, "fake", CAP)
    session.rollback()
    rail = FakeRail()
    assert paying.dispatch_queued(factory, rail, MONDAY) == 3
    lines = lines_of(session, window.id)
    assert {line.status for line in lines.values()} == {"processing"} and all(x.rail_reference for x in lines.values())
    assert paying.poll_processing(factory, rail, MONDAY + timedelta(minutes=1)) == 0  # too young to ask about
    with caplog.at_level("WARNING"):
        assert paying.poll_processing(factory, rail, MONDAY + timedelta(minutes=5)) == 3
    lines = lines_of(session, window.id)
    assert (lines[good].status, lines[good].utr, lines[good].rail_amount) == (
        "paid",
        f"UTR{lines[good].id.hex[:12].upper()}",
        Decimal("28.00"),
    )
    assert (lines[broke].status, lines[broke].failure_reason) == ("failed", "insufficient_funds")
    assert (lines[closed].status, lines[closed].failure_reason) == ("returned", "beneficiary_account_closed")
    assert "Asha" not in caplog.text
    [paid_event] = events(session, "payout.paid.v1")
    assert paid_event["line_id"] == str(lines[good].id) and paid_event["utr"] == lines[good].utr
    failed = {e["status"]: e for e in events(session, "payout.line.failed.v1")}
    assert failed["failed"]["reason"] == "insufficient_funds" and Decimal(failed["returned"]["amount"]) == Decimal(
        "28.99"
    )
    assert session.get(PayWindow, window.id).status == "paying"
    assert session.get(WorkerAccount, good).first_paid_at == MONDAY - timedelta(days=60)  # an old hand keeps theirs
    with pytest.raises(Conflict) as e:
        paying.retry_line(session, window.id, lines[good].id, "fake", MONDAY)
    assert e.value.code == "line_not_failed"
    session.rollback()
    with pytest.raises(Conflict):
        paying.release_line(session, window.id, lines[good].id)
    session.rollback()
    with pytest.raises(NotFound):
        paying.retry_line(session, window.id, uuid.uuid4(), "fake", MONDAY)
    session.rollback()
    retried = paying.retry_line(session, window.id, lines[broke].id, "fake", MONDAY)
    session.commit()
    assert (retried.status, retried.attempts, retried.idempotency_key) == ("queued", 2, f"{retried.id}:2")
    assert retried.rail_reference is None and retried.failure_reason is None
    paying.dispatch_queued(factory, rail, MONDAY + timedelta(minutes=6))
    paying.poll_processing(factory, rail, MONDAY + timedelta(minutes=10))
    assert lines_of(session, window.id)[broke].status == "failed"  # the fake rail fails 28.13 every time
    released = paying.release_line(session, window.id, lines[closed].id, MONDAY + timedelta(minutes=11))
    session.commit()
    assert released.status == "released"
    earning = session.scalar(select(Earning).where(Earning.worker_id == closed))
    assert earning.status == "payable" and earning.window_id is None
    paying.release_line(session, window.id, lines[broke].id, MONDAY + timedelta(minutes=12))
    session.commit()
    window = session.get(PayWindow, window.id)
    assert window.status == "paid" and window.paid_at == MONDAY + timedelta(minutes=12)
    assert window.gross_total == Decimal("28.00") and window.held_total == Decimal("57.12")
    assert window.paid_total == Decimal("28.00")
    assert paying.reconcile(session, window.id)["balanced"] is True
    # the released earnings land in the next close
    nxt = close_window(session, "INR", now=MONDAY + timedelta(days=7))
    assert {line.worker_id for line in session.scalars(select(WindowLine).where(WindowLine.window_id == nxt.id))} == {
        broke,
        closed,
    }


def test_settling_is_rank_ordered_and_idempotent(session, caplog):
    window, (worker,) = approved(session, ["10.00"])
    pay_out(session, window.id, MONDAY)
    session.commit()
    line = session.scalar(select(WindowLine).where(WindowLine.worker_id == worker))
    ref = line.rail_reference
    assert paying.settle_line(session, line, PayoutResult(ref, "processing")) is False
    assert paying.settle_line(session, line, PayoutResult(ref, "paid", utr="U2")) is False
    with caplog.at_level("ERROR"):
        assert paying.settle_line(session, line, PayoutResult(ref, "returned")) is True  # a reversal: owed again
    assert line.status == "returned" and line.rail_status == "returned" and "reversed after it was paid" in caplog.text
    assert len(events(session, "payout.paid.v1")) == 1
    window2, (w2,) = approved(session, ["5.00"], weeks_later=1)
    paying.pay_window(session, window2.id, "fake", CAP)
    line2 = session.scalar(select(WindowLine).where(WindowLine.worker_id == w2))
    assert paying.settle_line(session, line2, PayoutResult("r", "processing", reference_id=f"{line2.id}:1")) is True
    assert paying.settle_line(session, line2, PayoutResult("r", "queued")) is False
    assert (line2.status, line2.rail_reference) == ("processing", "r")


def test_a_window_with_nothing_payable_is_paid_at_once(session):
    window, (worker,) = approved(session, ["10.00"], approve=False)
    set_hold(session, worker, "integrity", MONDAY + timedelta(days=30))
    session.commit()
    nxt = close_window(session, "INR", now=MONDAY + timedelta(days=7))
    approve_window(session, nxt.id, "a")
    approve_window(session, nxt.id, "b")
    assert paying.pay_window(session, nxt.id, "fake", CAP).status == "paid"


def test_dispatch_survives_unknown_outcomes_refusals_outages_and_missing_accounts(session, factory):
    window, (unknown, refused, outage, gone) = approved(session, ["1.00", "2.00", "3.00", "4.00"])
    paying.pay_window(session, window.id, "fake", CAP)
    session.delete(session.get(BankAccount, gone))
    session.commit()

    class Scripted(FakeRail):
        def create_payout(self, request):
            amount = request.amount
            if amount == Decimal("1.00"):
                raise RailUnknownOutcome("timeout")
            if amount == Decimal("2.00"):
                raise RailError("BAD_REQUEST_ERROR")
            if amount == Decimal("3.00"):
                raise RailUnavailable("down")
            return super().create_payout(request)

    assert paying.dispatch_queued(factory, Scripted(), MONDAY) == 0
    lines = lines_of(session, window.id)
    assert (lines[unknown].status, lines[unknown].rail_reference) == ("processing", None)
    assert (lines[refused].status, lines[refused].failure_reason) == ("failed", "BAD_REQUEST_ERROR")
    assert (lines[outage].status, lines[outage].submitted_at) == ("queued", None)
    assert (lines[gone].status, lines[gone].failure_reason) == ("failed", "account_unverified")
    with pytest.raises(Conflict) as e:
        paying.retry_line(session, window.id, lines[gone].id, "fake", MONDAY)
    assert e.value.code == "account_unverified"


def test_the_poll_finds_a_payout_by_line_or_sends_it_again_with_the_same_key(session, factory):
    window, (found, never, gone) = approved(session, ["1.00", "2.00", "3.00"])
    paying.pay_window(session, window.id, "fake", CAP)
    session.commit()
    rail = FakeRail()
    lines = lines_of(session, window.id)
    for line in lines.values():
        line.status, line.submitted_at = "processing", MONDAY
    session.delete(session.get(BankAccount, gone))
    session.commit()
    from yantra_payout.rails import PayoutRequest

    rail.create_payout(PayoutRequest(lines[found].id, 1, "fa", Decimal("1.00"), "INR", "x"))

    class Broken(FakeRail):
        def fetch_payout(self, reference):
            raise RailUnavailable("down")

    assert paying.poll_processing(factory, rail, MONDAY + timedelta(minutes=5)) == 2
    lines = lines_of(session, window.id)
    assert lines[found].status == "paid" and lines[never].rail_reference.startswith("pout_fake_")
    assert lines[never].status == "processing" and lines[gone].failure_reason == "account_unverified"
    assert rail.calls.count("create_payout") == 2  # the one already there plus the resend; never a third
    assert paying.poll_processing(factory, Broken(), MONDAY + timedelta(minutes=10)) == 0


def test_the_bank_file_carries_real_accounts_and_the_return_file_settles_each_line(session):
    window, (one, two) = approved(session, ["28.00", "6.00"])
    with pytest.raises(Conflict) as e:
        paying.bank_file(session, window.id)
    assert e.value.code == "rail_mismatch"
    paying.pay_window(session, window.id, "file", CAP)
    session.commit()
    assert paying.bank_file(session, window.id)[0].count("\n") == 1  # nothing in flight yet: just the header
    lines = lines_of(session, window.id)
    for line in lines.values():
        line.status, line.rail_reference = "processing", f"FILE-{line.id.hex[:8]}-1"
        line.paid_account_hash = session.get(BankAccount, line.worker_id).account_hash
    session.get(PayWindow, window.id).status = "paying"
    session.commit()
    text, skipped = paying.bank_file(session, window.id)
    assert skipped == []
    header, *rows = text.splitlines()
    assert header == "reference,beneficiary_name,account_number,ifsc,amount,currency,narration"
    account = session.get(BankAccount, one)
    assert f"{lines[one].rail_reference},Asha Rao,{str(one.int)[:12]},HDFC0001234,28.00,INR," in text
    assert len(rows) == 2 and account.account_last4 in text
    back = (
        "reference,status,utr,reason\n"
        f"{lines[one].rail_reference},paid,UTR1,\n"
        f"{lines[two].rail_reference},returned,,account closed\n"
        "FILE-nope,paid,,\n"
        f"{lines[one].rail_reference},bogus,,\n"
        f"{lines[one].rail_reference},paid,UTR1,\n"
    )
    out = paying.reconcile_bank_file(session, window.id, back)
    assert out["applied"] == 2
    assert [s["reason"] for s in out["skipped"]] == ["unknown_reference", "bad_status", "already_settled"]
    lines = lines_of(session, window.id)
    assert (lines[one].status, lines[one].utr) == ("paid", "UTR1")
    assert (lines[two].status, lines[two].failure_reason) == ("returned", "account closed")
    with pytest.raises(Invalid):
        paying.reconcile_bank_file(session, window.id, "a,b\n1,2\n")
    paying.maybe_finish_window(session, session.get(PayWindow, window.id), MONDAY)  # still a returned line: paying
    assert session.get(PayWindow, window.id).status == "paying"
    lines[two].status = "processing"  # back in flight, and the worker's account is gone
    session.delete(session.get(BankAccount, two))
    session.flush()
    assert paying.bank_file(session, window.id)[0].count("\n") == 1
    session.get(PayWindow, window.id).status = "paid"
    paying.maybe_finish_window(session, session.get(PayWindow, window.id), MONDAY)
    with pytest.raises(Conflict):
        paying.bank_file(session, window.id)
    session.rollback()
    other, _ = approved(session, ["1.00"], approve=False, weeks_later=1)
    with pytest.raises(Conflict):
        paying.reconcile_bank_file(session, other.id, back)
    with pytest.raises(NotFound):
        paying.bank_file(session, uuid.uuid4())


def signed(body: dict) -> tuple[bytes, str]:
    raw = json.dumps(body).encode()
    return raw, hmac.new(SECRET.encode(), raw, hashlib.sha256).hexdigest()


def test_the_webhook_is_verified_recorded_once_and_applied(session, caplog):
    window, (worker,) = approved(session, ["28.00"])
    paying.pay_window(session, window.id, "razorpayx", CAP)
    line = session.scalar(select(WindowLine).where(WindowLine.worker_id == worker))
    line.status = "processing"
    session.commit()
    now = datetime.now(UTC)
    payout = {"id": "pout_9", "status": "processed", "utr": "UTR9", "amount": 2800, "reference_id": f"{line.id}:1"}
    body = {"event": "payout.processed", "created_at": int(now.timestamp()), "payload": {"payout": {"entity": payout}}}
    raw, sig = signed(body)
    with pytest.raises(Unauthorized):
        paying.ingest_webhook(session, raw, "bad", SECRET, 300, now)
    with pytest.raises(Unauthorized):
        paying.ingest_webhook(session, raw, None, SECRET, 300, now)
    with caplog.at_level("DEBUG"):
        out = paying.ingest_webhook(session, raw, sig, SECRET, 300, now)
    session.commit()
    assert out == {"duplicate": False, "applied": True, "note": None}
    assert (line.status, line.utr, line.rail_reference) == ("paid", "UTR9", "pout_9")
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300, now) == {"duplicate": True, "applied": False}
    record = session.get(WebhookEvent, "payout.processed:pout_9:processed")
    assert record.applied and record.line_id == line.id and record.body_sha256 == hashlib.sha256(raw).hexdigest()
    assert "UTR9" not in caplog.text
    old = {**payout, "status": "processing"}
    stale = {
        **body,
        "created_at": int((now - timedelta(minutes=10)).timestamp()),
        "payload": {"payout": {"entity": old}},
    }
    raw, sig = signed(stale)
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300, now)["note"] == "stale"
    stamp = int(now.timestamp())
    unknown = {
        "event": "payout.processed",
        "created_at": stamp,
        "payload": {"payout": {"entity": {**payout, "id": "pout_x", "reference_id": "x"}}},
    }
    raw, sig = signed(unknown)
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300, now)["note"] == "unknown_line"
    raw, sig = signed({"event": "transaction.created", "created_at": stamp, "payload": {}})
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300, now)["note"] == "ignored"
    long = {**unknown, "event": "payout." + "x" * 70}
    raw, sig = signed(long)
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300, now)["note"] == "unknown_line"
    assert session.scalar(select(func.count()).select_from(WebhookEvent).where(func.length(WebhookEvent.id) == 64))
    raw = b"not json"
    with pytest.raises(Invalid):
        paying.ingest_webhook(session, raw, hmac.new(SECRET.encode(), raw, hashlib.sha256).hexdigest(), SECRET, 300)


def test_a_validation_webhook_settles_the_penny_drop(session):
    from yantra_payout.accounts import AccountIn, register_account

    worker = uuid.uuid4()
    account = register_account(session, FakeRail(), worker, AccountIn("Asha Rao", "123456789012", "HDFC0001234"))
    session.commit()
    entity = {
        "id": account.validation_id,
        "status": "completed",
        "results": {"account_status": "active", "registered_name": "Asha  Rao"},
    }
    stamp = int(datetime.now(UTC).timestamp())
    raw, sig = signed(
        {
            "event": "fund_account.validation.completed",
            "created_at": stamp,
            "payload": {"fund_account.validation": {"entity": entity}},
        }
    )
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300)["applied"] is True
    assert account.status == "verified"
    raw, sig = signed(
        {
            "event": "fund_account.validation.completed",
            "created_at": stamp,
            "payload": {"fund_account.validation": {"entity": {**entity, "id": "nope"}}},
        }
    )
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300)["note"] == "unknown_validation"


def test_reconciliation_runs_release_statements_and_report_deltas_without_adjusting(session, factory):
    window, (worker, other) = approved(session, ["28.00", "6.00"])
    paying.pay_window(session, window.id, "fake", CAP)
    session.commit()
    live = paying.reconcile(session, window.id)
    assert live["balanced"] is True and live["processing_lines"] == 2 and "run_id" not in live
    with pytest.raises(Conflict) as e:
        paying.statement_export(session, window.id, worker, everyone=False)
    assert e.value.code == "not_reconciled"
    session.rollback()
    pay_out_rest(session, window.id)
    session.commit()
    run = paying.reconcile(session, window.id, persist=True, now=MONDAY)
    session.commit()
    assert run["balanced"] is True and run["reconciled_at"] == MONDAY.astimezone(UTC).isoformat()
    assert session.get(PayWindow, window.id).reconciled_at == MONDAY
    paying.reconcile(session, window.id, persist=True, now=MONDAY + timedelta(days=1))
    assert session.get(PayWindow, window.id).reconciled_at == MONDAY  # the first balanced run only
    mine = paying.statement_export(session, window.id, worker, everyone=False)
    header, row = mine.splitlines()
    assert header.startswith("window_starts,window_ends,line_status,utr,kind")
    assert ",paid,UTR" in row and ",unit," in row and ",28.00,INR," in row
    every = paying.statement_export(session, window.id, worker, everyone=True)
    assert every.splitlines()[0].startswith("line_id,worker_id,gross") and len(every.splitlines()) == 3
    with pytest.raises(NotFound):
        paying.statement_export(session, window.id, uuid.uuid4(), everyone=False)
    line = session.scalar(select(WindowLine).where(WindowLine.worker_id == worker))
    line.rail_amount = Decimal("27.00")  # the rail says it moved less
    session.commit()
    bad = paying.reconcile(session, window.id, persist=True, now=MONDAY + timedelta(days=2))
    assert bad["balanced"] is False and bad["delta_rail"] == "1.00"
    [delta] = events(session, "payout.reconciliation.delta.v1")
    assert delta["delta_rail"] == "1.00" and delta["window_id"] == str(window.id)
    stored = session.get(ReconciliationRun, uuid.UUID(bad["run_id"]))
    assert stored.details["rail_amount_mismatch"] == [str(line.id)]
    assert line.rail_amount == Decimal("27.00")  # never adjusted
    assert len(paying.list_runs(session, window.id)) == 3 and len(paying.list_runs(session, balanced=False)) == 1
    assert paying.reconcile_recent(factory, MONDAY + timedelta(days=3)) == 1
    assert paying.reconcile_recent(factory, MONDAY + timedelta(days=200)) == 0
    assert paying.attention(session)["reconciliation_deltas"] == 1


def pay_out_rest(session, window_id):
    for line in session.scalars(
        select(WindowLine).where(WindowLine.window_id == window_id, WindowLine.status == "queued")
    ):
        line.status = "processing"
        paid = PayoutResult(f"p_{line.id.hex[:6]}", "paid", utr="UTR1", reference_id=f"{line.id}:{line.attempts}")
        paying.settle_line(session, line, paid, MONDAY)


def test_an_unpaid_window_with_a_failed_line_does_not_balance_once_paid(session):
    window, (worker,) = approved(session, ["5.00"])
    paying.pay_window(session, window.id, "fake", CAP)
    window.status = "paid"  # as if someone forced it
    session.commit()
    report = paying.reconcile(session, window.id)
    assert report["balanced"] is False and report["processing_lines"] == 1 and report["unpaid_earnings"] == 1


def test_attention_counts_what_finance_should_look_at(session):
    window, _ = approved(session, ["5.00", "6.13"], approve=False)
    approve_window(session, window.id, "a")
    session.commit()
    assert paying.attention(session) == {
        "windows_awaiting_second_approval": 1,
        "reconciliation_deltas": 0,
        "failed_lines": 0,
        "lines_blocked": 0,
        "erasures_pending": 0,
        "accounts_awaiting_confirmation": 0,
        "pending_adjustments": 0,
        "dead_letters": {"payout": 0},
    }
    assert session.scalar(select(Approval.window_id)) == window.id


def test_the_rail_state_counts_lines_in_flight_and_the_last_job_runs(session):
    window, _ = approved(session, ["5.00"])
    paying.pay_window(session, window.id, "fake", CAP)
    state = paying.rail_state(session, FakeRail(), {"payout_dispatch": MONDAY, "payout_rail_poll": None})
    assert state["lines"] == {"queued": 1, "processing": 0, "failed": 0, "returned": 0}
    assert state["last_dispatch_at"] == MONDAY.astimezone(UTC).isoformat() and state["last_poll_at"] is None
    assert state["rail"] == "fake" and state["accounts_verifying"] == 0


def test_the_scheduled_close_runs_once_per_currency_and_the_job_list(session, factory):
    approved(session, ["5.00"], approve=False)
    settings = PayoutSettings(payout_currencies=["INR", "USD"])
    assert close_due_windows(factory, settings, MONDAY) == 1  # INR was closed by hand above; USD closes now
    assert close_due_windows(factory, settings, MONDAY) == 0
    jobs = {j.name: j for j in payout_jobs(factory, FakeRail(), settings)}
    assert jobs["payout_window_close"].at.weekday == 5 and jobs["payout_window_close"].at.minute == 5
    assert jobs["payout_dispatch"].every == timedelta(seconds=15)
    assert jobs["payout_reconcile"].at.hour == 2
    assert jobs["payout_dispatch"].run() == 0 and jobs["payout_rail_poll"].run() == 0
    assert jobs["payout_account_validation_poll"].run() == 0 and jobs["payout_reconcile"].run() == 0
    # the job closes against the real clock, so what it finds due depends on today's date; what holds on any date is
    # that a second run closes nothing
    jobs["payout_window_close"].run()
    assert jobs["payout_window_close"].run() == 0


def test_an_upheld_anomaly_holds_payouts_without_shortening_a_longer_hold(session):
    worker = uuid.uuid4()
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
    account = session.get(WorkerAccount, worker)
    assert account.hold_reason == "integrity" and account.hold_until == env.occurred_at + timedelta(days=30)
    [hold] = events(session, "payout.hold.set.v1")
    assert hold["source"] == "anomaly" and hold["reason"] == "integrity"
    on_anomaly_upheld(session, env, hold_days=30)  # redelivered
    assert len(events(session, "payout.hold.set.v1")) == 1
    set_hold(session, worker, "integrity", None)  # a live integrity hold is not lifted by hand
    assert len(events(session, "payout.hold.set.v1")) == 1
    other = uuid.uuid4()
    set_hold(session, other, "manual review", MONDAY + timedelta(days=3))
    set_hold(session, other, None, None)
    assert events(session, "payout.hold.set.v1")[-1]["until"] is None


def test_finance_lists_held_accounts_and_reads_one_window(session):
    window, (a, b) = approved(session, ["5.00", "6.00"], approve=False)
    set_hold(session, a, "integrity", datetime.now(UTC) + timedelta(days=3))
    set_hold(session, b, "bank_change", datetime.now(UTC) - timedelta(days=1))  # lapsed
    session.commit()
    out = held_accounts(session)
    assert (
        out["total"] == 1 and out["items"][0]["worker_id"] == str(a) and out["items"][0]["hold_reason"] == "integrity"
    )
    assert get_window(session, window.id).id == window.id
    with pytest.raises(NotFound):
        get_window(session, uuid.uuid4())


# ---------- safeguards: attempts, holds, rails, reversals, caps, webhooks, CSV cells ----------


def payout_event(line_id, attempt, reference, status, now, kind="payout.updated", created=True):
    entity = {"id": reference, "status": status, "amount": 2813, "reference_id": f"{line_id}:{attempt}"}
    body = {"event": kind, "payload": {"payout": {"entity": entity}}}
    if created:
        body["created_at"] = int(now.timestamp())
    return signed(body)


def test_a_late_event_for_an_earlier_attempt_never_settles_the_current_one(session, factory):
    window, (worker,) = approved(session, ["28.13"])
    paying.pay_window(session, window.id, "fake", CAP)
    session.commit()
    rail = FakeRail()
    paying.dispatch_queued(factory, rail, MONDAY)
    line = lines_of(session, window.id)[worker]
    first = line.rail_reference
    now = datetime.now(UTC)
    raw, sig = payout_event(line.id, 1, first, "failed", now, "payout.failed")
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300, now)["applied"] is True
    session.commit()
    paying.retry_line(session, window.id, line.id, "fake", MONDAY)
    session.commit()
    # between the retry and the dispatch the line has no reference yet: attempt 1's news is not attempt 2's
    raw, sig = payout_event(line.id, 1, first, "reversed", now, "payout.reversed")
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300, now) == {
        "duplicate": False,
        "applied": False,
        "note": "other_attempt",
    }
    session.commit()
    paying.dispatch_queued(factory, rail, MONDAY)
    line = lines_of(session, window.id)[worker]
    second = line.rail_reference
    assert (line.status, line.attempts) == ("processing", 2) and second != first
    raw, sig = payout_event(line.id, 1, first, "rejected", now, "payout.rejected")
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300, now)["note"] == "other_attempt"
    stray = PayoutResult("pout_stray", "failed", reference_id=f"{line.id}:2")
    assert paying.settle_line(session, line, stray) is False  # the right attempt, but not the payout it sent
    raw, sig = payout_event(line.id, 2, second, "processed", now, "payout.processed")
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300, now)["applied"] is True
    session.commit()
    assert lines_of(session, window.id)[worker].status == "paid"


def test_a_line_is_never_retried_past_the_reference_limit(session):
    window, (worker,) = approved(session, ["28.13"])
    paying.pay_window(session, window.id, "fake", CAP)
    line = lines_of(session, window.id)[worker]
    line.status, line.attempts = "failed", paying.MAX_ATTEMPTS
    session.commit()
    with pytest.raises(Conflict) as e:
        paying.retry_line(session, window.id, line.id, "fake", MONDAY)
    assert e.value.code == "too_many_attempts"


def test_a_live_hold_stops_dispatch_retry_and_resend_until_it_lapses(session, factory):
    window, (held, free) = approved(session, ["28.13", "5.00"])
    paying.pay_window(session, window.id, "fake", CAP)
    session.commit()
    set_hold(session, held, "integrity", MONDAY + timedelta(days=30))
    session.commit()
    rail = FakeRail()
    assert paying.dispatch_queued(factory, rail, MONDAY) == 1
    lines = lines_of(session, window.id)
    assert (lines[held].status, lines[held].rail_status) == ("queued", "held")
    assert lines[free].status == "processing"
    assert paying.attention(session)["lines_blocked"] == 1
    assert paying.dispatch_queued(factory, rail, MONDAY) == 0  # still held: nothing new is sent
    later = MONDAY + timedelta(days=31)
    assert paying.dispatch_queued(factory, rail, later) == 1
    lines = lines_of(session, window.id)
    assert (lines[held].status, lines[held].rail_status) == ("processing", "processing")
    paying.poll_processing(factory, rail, later + timedelta(minutes=5))
    assert lines_of(session, window.id)[held].status == "failed"  # 28.13 fails on the fake rail
    set_hold(session, held, "bank_change", later + timedelta(hours=72))
    session.commit()
    with pytest.raises(Conflict) as e:
        paying.retry_line(session, window.id, lines[held].id, "fake", later)
    assert e.value.code == "worker_held"
    session.rollback()
    # withdrawn consent holds the dispatch too
    third, (w3,) = approved(session, ["4.00"], weeks_later=2)
    paying.pay_window(session, third.id, "fake", CAP)
    session.get(WorkerAccount, w3).consent_withdrawn = True
    session.commit()
    paying.dispatch_queued(factory, FakeRail(), later)
    assert lines_of(session, third.id)[w3].rail_status == "held"
    # an unknown outcome is never sent again while the worker is held: it goes back to the queue
    nxt, (w2,) = approved(session, ["3.00"], weeks_later=1)
    paying.pay_window(session, nxt.id, "fake", CAP)
    line = lines_of(session, nxt.id)[w2]
    line.status, line.submitted_at, line.attempts = "processing", later, 1
    session.commit()
    set_hold(session, w2, "integrity", later + timedelta(days=30))
    session.commit()
    rail = FakeRail()
    assert paying.poll_processing(factory, rail, later + timedelta(minutes=5)) == 0
    assert "create_payout" not in rail.calls
    line = lines_of(session, nxt.id)[w2]
    assert (line.status, line.rail_status, line.submitted_at) == ("queued", "held", None)


def test_a_line_on_another_rail_is_left_queued_and_never_retried_on_this_one(session, factory):
    window, (worker,) = approved(session, ["5.00"])
    paying.pay_window(session, window.id, "file", CAP)
    session.commit()
    assert paying.dispatch_queued(factory, FakeRail(), MONDAY) == 0
    line = lines_of(session, window.id)[worker]
    assert (line.status, line.rail_status) == ("queued", "rail_mismatch")
    assert paying.attention(session)["lines_blocked"] == 1
    line.status = "failed"
    session.commit()
    with pytest.raises(Conflict) as e:
        paying.retry_line(session, window.id, line.id, "fake", MONDAY)
    assert e.value.code == "rail_mismatch"


def test_the_bank_file_pays_only_the_account_checked_at_dispatch_and_reports_what_it_skips(session, factory):
    from yantra_payout.rails.file import FileRail

    window, (ok, held, changed, gone) = approved(session, ["1.00", "2.00", "3.00", "4.00"])
    paying.pay_window(session, window.id, "file", CAP)
    session.commit()
    assert paying.dispatch_queued(factory, FileRail(), MONDAY) == 4
    lines = lines_of(session, window.id)
    assert lines[ok].paid_account_hash == session.get(BankAccount, ok).account_hash
    set_hold(session, held, "integrity", MONDAY + timedelta(days=30))
    session.get(BankAccount, changed).account_hash = "f" * 64  # re-registered after the dispatch
    session.delete(session.get(BankAccount, gone))
    session.commit()
    text, skipped = paying.bank_file(session, window.id, MONDAY)
    session.commit()
    assert len(text.splitlines()) == 2 and lines[ok].rail_reference in text
    assert {(s["line_id"], s["reason"]) for s in skipped} == {
        (str(lines[held].id), "held"),
        (str(lines[changed].id), "account_changed"),
        (str(lines[gone].id), "account_missing"),
    }
    lines = lines_of(session, window.id)
    assert {w: (lines[w].status, lines[w].rail_status) for w in (held, changed, gone)} == {
        held: ("queued", "held"),
        changed: ("queued", "account_changed"),
        gone: ("queued", "account_missing"),
    }
    assert paying.attention(session)["lines_blocked"] == 3


def test_bank_file_and_statement_cells_never_start_a_formula(session):
    window, (worker,) = approved(session, ["5.00"])
    paying.pay_window(session, window.id, "file", CAP)
    line = lines_of(session, window.id)[worker]
    line.status, line.rail_reference = "processing", "FILE-1"
    line.paid_account_hash = session.get(BankAccount, worker).account_hash
    session.get(BankAccount, worker).account_name = "=HYPERLINK(1)"
    session.commit()
    text, _ = paying.bank_file(session, window.id, MONDAY)
    assert ",'=HYPERLINK(1)," in text and ",=HYPERLINK" not in text
    assert [paying.csv_cell(v) for v in ("+1", "-1", "@x", "\tx", "\rx", "ok", 5)] == [
        "'+1",
        "'-1",
        "'@x",
        "'\tx",
        "'\rx",
        "ok",
        "5",
    ]
    line.hold_reason = "@SUM(1)"
    paying.settle_line(session, line, PayoutResult("FILE-1", "paid", utr="U"), MONDAY)
    paying.reconcile(session, window.id, persist=True, now=MONDAY)
    every = paying.statement_export(session, window.id, worker, everyone=True)
    assert ",'@SUM(1)," in every


def test_a_payout_reversed_after_it_was_paid_is_returned_and_owed_again(session):
    window, (worker, other) = approved(session, ["10.00", "5.00"])
    pay_out(session, window.id, MONDAY)
    session.commit()
    line = lines_of(session, window.id)[worker]
    assert session.get(PayWindow, window.id).status == "paid"
    assert paying.settle_line(session, line, PayoutResult("pout_other", "returned")) is False  # not its payout
    reversed_ = PayoutResult(line.rail_reference, "returned", reason="beneficiary_account_closed")
    assert paying.settle_line(session, line, reversed_, MONDAY) is True
    assert (line.status, line.failure_reason, line.utr) == ("returned", "beneficiary_account_closed", None)
    assert {e.status for e in session.scalars(select(Earning).where(Earning.worker_id == worker))} == {"windowed"}
    window = session.get(PayWindow, window.id)
    assert window.paid_total == Decimal("5.00")
    [failed] = events(session, "payout.line.failed.v1")
    assert failed["status"] == "returned" and failed["line_id"] == str(line.id)
    assert paying.settle_line(session, line, reversed_, MONDAY) is False  # once
    report = paying.reconcile(session, window.id)
    assert report["balanced"] is False and report["failed_lines"] == 1 and report["unpaid_earnings"] == 1
    assert paying.attention(session)["failed_lines"] == 1
    session.commit()
    assert paying.retry_line(session, window.id, line.id, "fake", MONDAY).status == "queued"


def test_finance_pays_a_window_over_the_cap_only_with_a_recorded_override(session):
    window, _ = approved(session, ["60.00"])
    with pytest.raises(Conflict) as e:
        paying.pay_window(session, window.id, "fake", Decimal("50"), MONDAY)
    assert e.value.code == "window_over_cap"
    session.rollback()
    finance = uuid.uuid4()
    with pytest.raises(Invalid):
        paying.pay_window(session, window.id, "fake", Decimal("50"), MONDAY, override_by=finance, override_reason=" ")
    session.rollback()
    paid = paying.pay_window(
        session, window.id, "fake", Decimal("50"), MONDAY, override_by=finance, override_reason="Diwali bonus run"
    )
    assert (paid.status, paid.cap_override_by, paid.cap_override_reason, paid.cap_override_at) == (
        "paying",
        finance,
        "Diwali bonus run",
        MONDAY,
    )
    nxt, _ = approved(session, ["10.00"], weeks_later=1)
    assert paying.pay_window(session, nxt.id, "fake", Decimal("50"), MONDAY).cap_override_by is None


def test_one_window_that_fails_to_reconcile_does_not_stop_the_others(session, factory, monkeypatch, caplog):
    from sqlalchemy.exc import SQLAlchemyError

    first, _ = approved(session, ["5.00"])
    second, _ = approved(session, ["6.00"], weeks_later=1)
    for w in (first, second):
        pay_out(session, w.id, MONDAY)
    session.commit()
    real = paying.reconcile

    def flaky(s, window_id, **kw):
        if window_id == first.id:
            raise SQLAlchemyError("boom")
        return real(s, window_id, **kw)

    monkeypatch.setattr(paying, "reconcile", flaky)
    with caplog.at_level("ERROR"):
        assert paying.reconcile_recent(factory, MONDAY + timedelta(days=8)) == 1
    assert f"window_id={first.id}" in caplog.text and "failed=1" in caplog.text
    assert paying.list_runs(session, second.id)


def test_a_webhook_replay_is_recognised_by_its_signed_body_and_needs_a_timestamp(session):
    window, (worker,) = approved(session, ["28.00"])
    paying.pay_window(session, window.id, "razorpayx", CAP)
    line = lines_of(session, window.id)[worker]
    line.status = "processing"
    session.commit()
    now = datetime.now(UTC)
    raw, sig = payout_event(line.id, 1, "pout_1", "processed", now)
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300, now)["applied"] is True
    session.commit()
    # the same signed body again (whatever event-id header a replayer sends) is a duplicate
    assert paying.ingest_webhook(session, raw, sig, SECRET, 300, now)["duplicate"] is True
    raw, sig = payout_event(line.id, 1, "pout_1", "processed", now, created=False)
    with pytest.raises(Invalid):
        paying.ingest_webhook(session, raw, sig, SECRET, 300, now)


def test_the_poll_never_resends_a_line_that_settled_while_it_looked(session, factory):
    window, (worker,) = approved(session, ["3.00"])
    paying.pay_window(session, window.id, "fake", CAP)
    line = lines_of(session, window.id)[worker]
    line.status, line.submitted_at = "processing", MONDAY
    session.commit()

    class SettledMeanwhile(FakeRail):
        def find_payout(self, reference_id):
            with factory() as other:
                other.get(WindowLine, line.id).status = "failed"  # a webhook got there first
                other.commit()
            return None

    rail = SettledMeanwhile()
    assert paying.poll_processing(factory, rail, MONDAY + timedelta(minutes=5)) == 0
    assert "create_payout" not in rail.calls and lines_of(session, window.id)[worker].status == "failed"


def test_a_paid_report_on_a_failed_line_is_never_applied_but_is_shouted(session, caplog):
    window, (worker,) = approved(session, ["5.00"])
    paying.pay_window(session, window.id, "fake", CAP)
    line = lines_of(session, window.id)[worker]
    line.status, line.rail_reference = "failed", "pout_1"
    session.commit()
    with caplog.at_level("ERROR"):
        assert paying.settle_line(session, line, PayoutResult("pout_1", "paid", utr="U")) is False
    assert line.status == "failed" and "payout reported paid on a failed line" in caplog.text
