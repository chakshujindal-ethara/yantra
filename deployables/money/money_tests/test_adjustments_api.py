"""Two-person adjustments, the ops overview and the account lookup over HTTP, ops only."""

import uuid
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from yantra_money.app import create_app
from yantra_payout.service import on_unit_published, on_verdict_accepted
from yantra_payout.testing import accepted, published

OPS1 = {"X-Role": "ops,finance", "X-Worker-Id": str(uuid.uuid4())}
OPS2 = {"X-Role": "ops,finance,worker", "X-Worker-Id": str(uuid.uuid4())}
WORKER = {"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4())}


@pytest.fixture
def client(factory):
    return TestClient(create_app(factory, rate_limit_per_minute=1000), raise_server_exceptions=False)


def test_an_adjustment_needs_two_people_and_a_positive_amount(client, factory):
    worker = str(uuid.uuid4())
    body = {"worker_id": worker, "amount": "150.00", "currency": "INR", "kind": "bonus", "reason": "festival bonus"}
    assert client.post("/v1/payout/adjustments", json=body, headers=WORKER).status_code == 403
    assert client.post("/v1/payout/adjustments", json=body, headers={"X-Role": "ops"}).status_code == 422  # unsigned
    for bad in (
        {**body, "amount": "0"},
        {**body, "amount": "-5"},
        {**body, "currency": "inr"},
        {**body, "kind": "refund"},
        {**body, "reason": ""},
        {**body, "reason": "x" * 501},
    ):
        r = client.post("/v1/payout/adjustments", json=bad, headers=OPS1)
        assert r.status_code == 422 and r.json()["code"] == "validation_error", bad
    created = client.post("/v1/payout/adjustments", json=body, headers=OPS1)
    assert created.status_code == 201, created.text
    adj = created.json()
    assert adj["status"] == "pending" and adj["proposed_by"] == OPS1["X-Worker-Id"] and adj["decided_by"] is None
    assert adj["amount"] == "150.00" and adj["kind"] == "bonus" and adj["decision_note"] is None
    assert client.get("/v1/payout/adjustments", headers=WORKER).status_code == 403
    assert [a["id"] for a in client.get("/v1/payout/adjustments", headers=OPS1).json()] == [adj["id"]]
    assert client.get("/v1/payout/adjustments", params={"status": "approved"}, headers=OPS1).json() == []
    assert client.get("/v1/payout/adjustments", params={"status": "nope"}, headers=OPS1).status_code == 422
    ops_only = {"X-Role": "ops", "X-Worker-Id": str(uuid.uuid4())}
    r = client.post(f"/v1/payout/adjustments/{adj['id']}/approve", headers=ops_only)
    assert (r.status_code, r.json()["message"]) == (403, "finance role required")
    same = client.post(f"/v1/payout/adjustments/{adj['id']}/approve", headers=OPS1)
    assert same.status_code == 409 and same.json()["code"] == "same_person"
    approved = client.post(f"/v1/payout/adjustments/{adj['id']}/approve", json={"note": "ok"}, headers=OPS2)
    assert approved.status_code == 200, approved.text
    assert approved.json()["status"] == "approved" and approved.json()["decided_by"] == OPS2["X-Worker-Id"]
    assert approved.json()["decided_at"] and approved.json()["decision_note"] == "ok"
    again = client.post(f"/v1/payout/adjustments/{adj['id']}/reject", headers=OPS2)
    assert again.status_code == 409 and again.json()["code"] == "already_decided"
    assert client.post(f"/v1/payout/adjustments/{uuid.uuid4()}/reject", headers=OPS2).status_code == 404
    statement = client.get("/v1/payout/statement", headers={"X-Role": "worker", "X-Worker-Id": worker}).json()
    [earning] = statement["earnings"]
    assert earning["kind"] == "adjust" and earning["status"] == "payable" and earning["amount"] == "150.00"
    second = client.post("/v1/payout/adjustments", json={**body, "kind": "correction"}, headers=OPS1).json()
    rejected = client.post(f"/v1/payout/adjustments/{second['id']}/reject", json={"note": "no"}, headers=OPS2)
    assert rejected.status_code == 200 and rejected.json()["status"] == "rejected"
    assert (
        len(client.get("/v1/payout/statement", headers={"X-Role": "worker", "X-Worker-Id": worker}).json()["earnings"])
        == 1
    )
    pending = client.get("/v1/payout/adjustments", params={"status": "pending"}, headers=OPS1).json()
    assert pending == []


def test_the_overview_and_the_account_lookup_are_ops_only(client, factory):
    worker, reviewer = uuid.uuid4(), uuid.uuid4()
    with factory() as s:
        batch = uuid.uuid4()
        on_unit_published(s, published(batch))
        on_verdict_accepted(s, accepted(batch, worker, reviewer))
        s.commit()
    assert client.get("/v1/payout/overview", headers=WORKER).status_code == 403
    out = client.get("/v1/payout/overview", headers=OPS1).json()
    assert out["payable_now"] == {} and out["held_total"] == {"INR": "34.00"}  # first payouts wait seven days
    assert out["paid_total"] == {} and out["windows"] == {"closed": 0, "approved": 0, "paying": 0, "paid": 0}
    assert out["margin_total"] == {"INR": "26.00"} and out["pending_adjustments"] == 0
    assert out["open_window"]["closes_in_seconds"] > 0
    assert datetime.fromisoformat(out["open_window"]["ends_at"]) > datetime.now(UTC)
    assert client.get(f"/v1/payout/accounts/{worker}", headers=WORKER).status_code == 403
    account = client.get(f"/v1/payout/accounts/{worker}", headers=OPS1).json()
    assert account["account"]["worker_id"] == str(worker) and account["account"]["first_paid_at"] is None
    assert account["totals"] == {"payable": "0.00", "paid": "0.00", "held": "28.00", "currency": "INR"}
    assert client.get(f"/v1/payout/accounts/{uuid.uuid4()}", headers=OPS1).status_code == 404
