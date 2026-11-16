"""The money HTTP surface that finance and the Odoo bridge use: windows and their lines, ops only."""

import uuid
from datetime import UTC, datetime
from decimal import Decimal

from fastapi.testclient import TestClient

from yantra_money.app import create_app
from yantra_payout.service import IST, close_window, on_unit_published, on_verdict_accepted
from yantra_payout.testing import accepted, published

OPS = {"X-Role": "ops", "X-Worker-Id": str(uuid.uuid4())}


def test_windows_and_lines_are_listed_for_ops_only(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000), raise_server_exceptions=False)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    with factory() as s:
        batch = uuid.uuid4()
        on_unit_published(s, published(batch))
        on_verdict_accepted(s, accepted(batch, worker, reviewer))
        s.commit()
        window = close_window(s, "INR", now=datetime(2030, 1, 7, 10, 0, tzinfo=IST))
        s.commit()
        window_id = str(window.id)
    assert client.get("/v1/payout/windows").status_code == 403
    assert client.get("/v1/payout/windows", params={"status": "nope"}, headers=OPS).status_code == 422
    [w] = client.get("/v1/payout/windows", params={"status": "closed"}, headers=OPS).json()
    assert (
        w["id"] == window_id and client.get("/v1/payout/windows", params={"status": "paid"}, headers=OPS).json() == []
    )
    lines = client.get(f"/v1/payout/windows/{window_id}/lines", headers=OPS).json()
    assert {line["worker_id"] for line in lines} == {str(worker), str(reviewer)}
    assert {Decimal(line["gross"]) for line in lines} == {Decimal("28"), Decimal("6")}
    assert client.get(f"/v1/payout/windows/{uuid.uuid4()}/lines", headers=OPS).status_code == 404


def test_a_worker_reads_a_statement_rich_enough_for_the_earnings_screen(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000), raise_server_exceptions=False)
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    with factory() as s:
        batch = uuid.uuid4()
        on_unit_published(s, published(batch))
        on_verdict_accepted(s, accepted(batch, worker, reviewer))
        on_verdict_accepted(s, accepted(batch, worker, reviewer))
        s.commit()
    assert client.get("/v1/payout/statement").status_code == 403  # no role
    assert client.get("/v1/payout/statement", headers={"X-Role": "worker"}).status_code == 422  # no identity header
    out = client.get("/v1/payout/statement", headers={"X-Role": "worker", "X-Worker-Id": str(worker)}).json()
    assert out["worker_id"] == str(worker) and out["totals"] == {"payable": "56.00"} and out["hold"] is None
    assert len(out["earnings"]) == 2 and out["earnings"][0]["status"] == "payable"
    assert out["account"] == {"first_paid_at": None, "hold_until": None, "hold_reason": None}
    assert out["windows"] == []
    assert out["pending_next"] == {"currency": "INR", "amount": "56.00", "count": 2}
    assert len(out["weeks"]) == 12 and out["weeks"][-1]["amount"] == "56.00" and out["weeks"][-1]["count"] == 2
    assert all(w["currency"] == "INR" for w in out["weeks"]) and out["weeks"][0]["amount"] == "0.00"
    assert out["next_window_closes_at"] == out["weeks"][-1]["ends_at"]
    assert datetime.fromisoformat(out["next_window_closes_at"]) > datetime.now(UTC)
    stranger = client.get(
        "/v1/payout/statement", headers={"X-Role": "reviewer", "X-Worker-Id": str(uuid.uuid4())}
    ).json()
    assert stranger["earnings"] == [] and stranger["pending_next"]["amount"] == "0.00" and len(stranger["weeks"]) == 12
