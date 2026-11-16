"""The payout routes the app and finance use for real money: the worker's bank account, paying a window, retrying
and releasing a failed line, the bank file and its return file, reconciliation runs, the statement export, the
rail's state, the attention list, held accounts, one window, and the RazorpayX webhook through the money app."""

import hashlib
import hmac
import json
import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

from fastapi.testclient import TestClient
from pydantic import SecretStr
from sqlalchemy import select

from yantra_money.app import create_app
from yantra_payout.config import PayoutSettings
from yantra_payout.models import Earning, WindowLine, WorkerAccount
from yantra_payout.paying import dispatch_queued, poll_processing
from yantra_payout.rails.fake import FakeRail
from yantra_payout.service import IST, approve_window, close_window
from yantra_payout.testing import verified_account

FINANCE = {"X-Role": "finance", "X-Worker-Id": str(uuid.uuid4())}
OPS = {"X-Role": "ops", "X-Worker-Id": str(uuid.uuid4())}
MONDAY = datetime(2026, 11, 2, 10, 0, tzinfo=IST)
WEBHOOK_SECRET = "whsec_" + "x" * 32


def worker_headers(worker: uuid.UUID) -> dict[str, str]:
    return {"X-Role": "worker", "X-Worker-Id": str(worker)}


def approved_window(factory, amounts: list[str]) -> tuple[uuid.UUID, list[uuid.UUID]]:
    workers = []
    with factory() as s:
        for amount in amounts:
            w = uuid.uuid4()
            workers.append(w)
            verified_account(s, w)
            s.add(WorkerAccount(worker_id=w, first_paid_at=MONDAY - timedelta(days=60)))
            s.add(
                Earning(
                    event_id=uuid.uuid4(),
                    kind="unit",
                    worker_id=w,
                    unit_id=uuid.uuid4(),
                    batch_id=uuid.uuid4(),
                    amount=Decimal(amount),
                    currency="INR",
                    created_at=datetime(2026, 10, 27, 12, tzinfo=IST),
                )
            )
        s.commit()
        window = close_window(s, "INR", now=MONDAY)
        approve_window(s, window.id, "a")
        approve_window(s, window.id, "b")
        s.commit()
        return window.id, workers


def test_a_worker_registers_a_bank_account_and_finance_sees_it_without_the_number(factory):
    rail = FakeRail()
    client = TestClient(create_app(factory, rate_limit_per_minute=1000, rail=rail, config=PayoutSettings()))
    worker = uuid.uuid4()
    h = worker_headers(worker)
    assert client.get("/v1/payout/accounts/me", headers=h).status_code == 404
    body = {"account_name": " Asha Rao ", "account_number": "123456789012", "ifsc": "HDFC0001234"}
    assert client.put("/v1/payout/accounts/me", json={**body, "ifsc": "hdfc1"}, headers=h).status_code == 422
    assert (
        client.put(
            "/v1/payout/accounts/me", json=body, headers={"X-Role": "client", **{"X-Worker-Id": str(worker)}}
        ).status_code
        == 403
    )
    r = client.put("/v1/payout/accounts/me", json=body, headers=h)
    assert r.status_code == 200 and r.json()["status"] == "verifying" and r.json()["account_name"] == "Asha Rao"
    assert "123456789012" not in r.text and r.json()["account_last4"] == "9012"
    from yantra_payout.accounts import poll_verifying

    poll_verifying(factory, rail)
    assert client.get("/v1/payout/accounts/me", headers=h).json()["status"] == "verified"
    with factory() as s:
        s.add(WorkerAccount(worker_id=worker))
        s.commit()
    summary = client.get(f"/v1/payout/accounts/{worker}", headers=FINANCE).json()
    assert summary["bank"]["status"] == "verified" and "123456789012" not in json.dumps(summary)
    other = uuid.uuid4()
    with factory() as s:
        s.add(WorkerAccount(worker_id=other))
        s.commit()
    assert client.get(f"/v1/payout/accounts/{other}", headers=FINANCE).json()["bank"] is None
    r = client.put("/v1/payout/accounts/me", json=body, headers=worker_headers(uuid.uuid4()))
    assert r.status_code == 409 and r.json()["code"] == "account_in_use"


def test_finance_pays_a_window_and_handles_a_failed_line_over_http(factory):
    rail = FakeRail()
    client = TestClient(create_app(factory, rate_limit_per_minute=1000, rail=rail, config=PayoutSettings()))
    wid, (good, broke) = approved_window(factory, ["28.00", "6.13"])
    assert client.post(f"/v1/payout/windows/{wid}/pay", headers=OPS).status_code == 403
    r = client.post(f"/v1/payout/windows/{wid}/pay", headers=FINANCE)
    assert r.status_code == 200 and r.json()["status"] == "paying" and r.json()["rail"] == "fake"
    tight = TestClient(
        create_app(factory, rate_limit_per_minute=1000, rail=rail, config=PayoutSettings(payout_max_per_window=1))
    )
    assert tight.post(f"/v1/payout/windows/{wid}/pay", headers=FINANCE).status_code == 409
    dispatch_queued(factory, rail)
    poll_processing(factory, rail, now=datetime.now(UTC) + timedelta(minutes=5))
    lines = {x["worker_id"]: x for x in client.get(f"/v1/payout/windows/{wid}/lines", headers=OPS).json()}
    assert lines[str(good)]["status"] == "paid" and lines[str(broke)]["failure_reason"] == "insufficient_funds"
    assert lines[str(good)]["attempts"] == 1 and "idempotency_key" not in lines[str(good)]
    bad = lines[str(broke)]["id"]
    r = client.post(f"/v1/payout/windows/{wid}/lines/{bad}/retry", headers=FINANCE)
    assert r.status_code == 200 and r.json()["status"] == "queued" and r.json()["attempts"] == 2
    with factory() as s:
        line = s.get(WindowLine, uuid.UUID(bad))
        line.status = "failed"
        s.commit()
    r = client.post(f"/v1/payout/windows/{wid}/lines/{bad}/release", headers=FINANCE)
    assert r.status_code == 200 and r.json()["status"] == "released"
    window = client.get(f"/v1/payout/windows/{wid}", headers=OPS).json()
    assert window["status"] == "paid" and Decimal(window["paid_total"]) == Decimal("28")
    assert client.get(f"/v1/payout/windows/{uuid.uuid4()}", headers=OPS).status_code == 404
    live = client.get(f"/v1/payout/windows/{wid}/reconcile", headers=OPS).json()
    assert live["balanced"] is True and "run_id" not in live
    assert client.post(f"/v1/payout/windows/{wid}/reconcile", headers=OPS).status_code == 403
    run = client.post(f"/v1/payout/windows/{wid}/reconcile", headers=FINANCE).json()
    assert run["balanced"] is True and run["run_id"]
    runs = client.get("/v1/payout/reconciliation-runs", params={"window_id": wid}, headers=OPS).json()
    assert len(runs) == 1 and runs[0]["balanced"] is True
    assert client.get("/v1/payout/reconciliation-runs", params={"balanced": "false"}, headers=OPS).json() == []
    mine = client.get(f"/v1/payout/statements/{wid}/export", headers=worker_headers(good))
    assert mine.headers["content-type"].startswith("text/csv") and "statement-" in mine.headers["content-disposition"]
    assert ",28.00,INR," in mine.text
    every = client.get(f"/v1/payout/statements/{wid}/export", headers=FINANCE)
    assert len(every.text.splitlines()) == 3
    assert (
        client.get(f"/v1/payout/statements/{wid}/export", params={"format": "pdf"}, headers=FINANCE).status_code == 422
    )
    assert (
        client.get(
            f"/v1/payout/statements/{wid}/export", headers={"X-Role": "client", "X-Worker-Id": str(good)}
        ).status_code
        == 403
    )
    state = client.get("/v1/payout/rail", headers=OPS).json()
    assert state["rail"] == "fake" and state["lines"]["failed"] == 0
    attention = client.get("/v1/payout/attention", headers=FINANCE).json()
    assert attention["failed_lines"] == 0 and attention["dead_letters"] == {"payout": 0}


def test_the_bank_file_rail_over_http(factory):
    from yantra_payout.rails.file import FileRail

    rail = FileRail()
    client = TestClient(create_app(factory, rate_limit_per_minute=1000, rail=rail, config=PayoutSettings(rail="file")))
    wid, (one,) = approved_window(factory, ["28.00"])
    client.post(f"/v1/payout/windows/{wid}/pay", headers=FINANCE)
    dispatch_queued(factory, rail)
    r = client.get(f"/v1/payout/windows/{wid}/bank-file", headers=FINANCE)
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/csv")
    assert "attachment" in r.headers["content-disposition"] and str(one.int)[:12] in r.text
    reference = r.text.splitlines()[1].split(",")[0]
    back = f"reference,status,utr,reason\n{reference},paid,UTR77,\n"
    out = client.post(
        f"/v1/payout/windows/{wid}/bank-file/reconcile", content=back, headers={**FINANCE, "Content-Type": "text/csv"}
    )
    assert out.status_code == 200 and out.json() == {"applied": 1, "skipped": []}
    bad = client.post(f"/v1/payout/windows/{wid}/bank-file/reconcile", content=b"\xff\xfe", headers=FINANCE)
    assert bad.status_code == 422


def test_held_accounts_and_the_upheld_anomaly_hold(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000, rail=FakeRail(), config=PayoutSettings()))
    worker = uuid.uuid4()
    r = client.put(
        f"/v1/payout/accounts/{worker}/hold",
        json={"reason": "integrity", "until": (datetime.now(UTC) + timedelta(days=2)).isoformat()},
        headers=OPS,
    )
    assert r.status_code == 200
    held = client.get("/v1/payout/accounts", params={"held": "true"}, headers=FINANCE).json()
    assert held["total"] == 1 and held["items"][0]["worker_id"] == str(worker)
    assert client.get("/v1/payout/accounts", params={"held": "false"}, headers=FINANCE).status_code == 422
    assert client.get("/v1/payout/accounts", headers=worker_headers(worker)).status_code == 403


def test_the_webhook_exists_only_on_razorpayx_with_a_secret_and_checks_the_signature(factory):
    plain = TestClient(create_app(factory, rate_limit_per_minute=1000, rail=FakeRail(), config=PayoutSettings()))
    assert plain.post("/v1/payout/webhooks/razorpayx", content=b"{}").status_code == 404
    config = PayoutSettings(
        rail="razorpayx",
        razorpayx_key_id="k",
        razorpayx_key_secret=SecretStr("s"),
        razorpayx_account_number="1",
        razorpayx_webhook_secret=SecretStr(WEBHOOK_SECRET),
    )
    client = TestClient(create_app(factory, rate_limit_per_minute=1000, rail=FakeRail(), config=config))
    raw = json.dumps(
        {
            "event": "payout.processed",
            "created_at": int(datetime.now(UTC).timestamp()),
            "payload": {"payout": {"entity": {"id": "p", "reference_id": "x"}}},
        }
    ).encode()
    sig = hmac.new(WEBHOOK_SECRET.encode(), raw, hashlib.sha256).hexdigest()
    assert (
        client.post("/v1/payout/webhooks/razorpayx", content=raw, headers={"X-Razorpay-Signature": "no"}).status_code
        == 401
    )
    r = client.post(
        "/v1/payout/webhooks/razorpayx", content=raw, headers={"X-Razorpay-Signature": sig, "X-Razorpay-Event-Id": "e1"}
    )
    assert r.status_code == 200 and r.json()["note"] == "unknown_line"
    again = client.post(  # a replay under a fresh event-id header is still the same signed body
        "/v1/payout/webhooks/razorpayx", content=raw, headers={"X-Razorpay-Signature": sig, "X-Razorpay-Event-Id": "e2"}
    )
    assert again.json()["duplicate"] is True


def test_the_app_picks_the_rail_from_the_environment(factory, monkeypatch):
    from yantra_payout.config import payout_settings

    monkeypatch.setenv("YANTRA_RAIL", "file")
    payout_settings.cache_clear()
    try:
        app = create_app(factory, rate_limit_per_minute=1000)
        assert app.state.rail.name == "file" and app.state.payout_settings.rail == "file"
    finally:
        payout_settings.cache_clear()
    assert select(WindowLine) is not None


def test_the_safeguards_over_http(factory):
    from yantra_payout.models import BankAccount, PayWindow
    from yantra_payout.rails.file import FileRail

    client = TestClient(create_app(factory, rate_limit_per_minute=1000, rail=FakeRail(), config=PayoutSettings()))
    worker = uuid.uuid4()
    # the statement is a worker surface
    assert (
        client.get("/v1/payout/statement", headers={"X-Role": "client", "X-Worker-Id": str(worker)}).status_code == 403
    )
    assert client.get("/v1/payout/statement", headers=worker_headers(worker)).status_code == 200
    # a name that could start a spreadsheet formula is refused
    body = {"account_name": "=HYPERLINK(1)", "account_number": "123456789012", "ifsc": "HDFC0001234"}
    assert client.put("/v1/payout/accounts/me", json=body, headers=worker_headers(worker)).status_code == 422
    # an operator never holds or lifts their own account
    me = uuid.UUID(OPS["X-Worker-Id"])
    r = client.put(f"/v1/payout/accounts/{me}/hold", json={"reason": None, "until": None}, headers=OPS)
    assert r.status_code == 409 and r.json()["code"] == "same_person"
    # finance confirms a penny drop that proved no name
    with factory() as s:
        account = verified_account(s, worker)
        account.registered_name_match = None
        s.commit()
    assert client.get("/v1/payout/accounts/me", headers=worker_headers(worker)).json()["awaiting_confirmation"]
    assert client.post(f"/v1/payout/accounts/{worker}/confirm", headers=OPS).status_code == 403
    r = client.post(f"/v1/payout/accounts/{worker}/confirm", headers=FINANCE)
    assert r.status_code == 200 and r.json()["awaiting_confirmation"] is False
    assert client.post(f"/v1/payout/accounts/{worker}/confirm", headers=FINANCE).status_code == 409
    attention = client.get("/v1/payout/attention", headers=FINANCE).json()
    assert {"lines_blocked", "erasures_pending", "accounts_awaiting_confirmation"} <= set(attention)
    # a window over the cap is paid only with an explicit, explained override
    tight = TestClient(
        create_app(
            factory,
            rate_limit_per_minute=1000,
            rail=FileRail(),
            config=PayoutSettings(rail="file", payout_max_per_window=1),
        )
    )
    wid, (one, gone) = approved_window(factory, ["28.00", "6.00"])
    pay = f"/v1/payout/windows/{wid}/pay"
    assert tight.post(pay, headers=FINANCE).json()["code"] == "window_over_cap"
    assert tight.post(pay, json={"override_cap": True}, headers=FINANCE).status_code == 422
    r = tight.post(pay, json={"override_cap": True, "reason": "festival bonus week"}, headers=FINANCE)
    assert r.status_code == 200 and r.json()["cap_override_reason"] == "festival bonus week"
    assert r.json()["cap_override_by"] == FINANCE["X-Worker-Id"]
    # the bank file names the lines it left out
    dispatch_queued(factory, FileRail())
    with factory() as s:
        s.delete(s.get(BankAccount, gone))
        s.commit()
    r = tight.get(f"/v1/payout/windows/{wid}/bank-file", headers=FINANCE)
    with factory() as s:
        [gone_line] = s.scalars(select(WindowLine).where(WindowLine.worker_id == gone)).all()
        assert s.get(PayWindow, wid).status == "paying" and gone_line.status == "queued"
    assert r.headers["x-skipped-lines"] == f"{gone_line.id}:account_missing"
