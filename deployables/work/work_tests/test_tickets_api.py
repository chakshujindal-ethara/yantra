"""Support tickets through the work deployable: anyone raises and reads their own; ops read and move every one."""

import uuid

import pytest
from fastapi.testclient import TestClient

from yantra_work.app import create_app

OPS = {"X-Role": "ops", "X-Worker-Id": str(uuid.uuid4())}


@pytest.fixture
def client(factory):
    return TestClient(create_app(factory, rate_limit_per_minute=1000), raise_server_exceptions=False)


def test_tickets_are_raised_by_anyone_read_by_their_author_and_moved_by_ops(client):
    worker, other = {"X-Worker-Id": str(uuid.uuid4()), "X-Role": "worker"}, {"X-Worker-Id": str(uuid.uuid4())}
    body = {
        "category": "bug",
        "title": "Claim button does nothing",
        "body": "On the work screen, tapping claim shows no error.",
        "screen": "work/claim",
        "context": {"build": "1.2.0", "platform": "android"},
    }
    assert client.post("/v1/notify/tickets", json=body).status_code == 422  # no identity
    for bad in (
        {**body, "category": "praise"},
        {**body, "title": ""},
        {**body, "title": "x" * 141},
        {**body, "body": ""},
        {**body, "body": "x" * 4001},
        {**body, "context": "not-an-object"},
    ):
        r = client.post("/v1/notify/tickets", json=bad, headers=worker)
        assert r.status_code == 422 and r.json()["code"] == "validation_error", bad
    for huge in ({**body, "context": {f"k{i}": 1 for i in range(51)}}, {**body, "context": {"blob": "x" * 16385}}):
        r = client.post("/v1/notify/tickets", json=huge, headers=worker)
        assert r.status_code == 422 and r.json()["code"] == "too_large"
    created = client.post("/v1/notify/tickets", json=body, headers=worker)
    assert created.status_code == 201, created.text
    ticket = created.json()
    assert ticket["status"] == "open" and ticket["author_id"] == worker["X-Worker-Id"] and ticket["note"] is None
    assert ticket["screen"] == "work/claim" and ticket["context"] == body["context"] and ticket["created_at"]
    minimal = client.post("/v1/notify/tickets", json={"category": "other", "title": "Hi", "body": "?"}, headers=other)
    assert minimal.status_code == 201 and minimal.json()["screen"] is None and minimal.json()["context"] == {}
    assert [t["id"] for t in client.get("/v1/notify/tickets/me", headers=worker).json()] == [ticket["id"]]
    assert [t["id"] for t in client.get("/v1/notify/tickets/me", headers=other).json()] == [minimal.json()["id"]]
    assert client.get("/v1/notify/tickets", headers=worker).status_code == 403
    board = client.get("/v1/notify/tickets", headers=OPS).json()
    assert [t["id"] for t in board] == [minimal.json()["id"], ticket["id"]]  # newest first
    assert client.get("/v1/notify/tickets", params={"status": "nope"}, headers=OPS).status_code == 422
    assert len(client.get("/v1/notify/tickets", params={"status": "open"}, headers=OPS).json()) == 2
    path = f"/v1/notify/tickets/{ticket['id']}/status"
    assert client.post(path, json={"status": "in_progress"}, headers=worker).status_code == 403
    assert client.post(path, json={"status": "closed"}, headers=OPS).status_code == 422
    moved = client.post(path, json={"status": "in_progress", "note": "on it"}, headers=OPS)
    assert moved.status_code == 200 and moved.json()["status"] == "in_progress" and moved.json()["note"] == "on it"
    same = client.post(path, json={"status": "in_progress"}, headers=OPS)
    assert same.status_code == 409 and same.json()["code"] == "same_status"
    assert (
        client.post(f"/v1/notify/tickets/{uuid.uuid4()}/status", json={"status": "resolved"}, headers=OPS).status_code
        == 404
    )
    done = client.post(path, json={"status": "resolved"}, headers=OPS).json()
    assert done["status"] == "resolved" and done["note"] == "on it" and done["updated_at"] >= done["created_at"]
    assert [t["id"] for t in client.get("/v1/notify/tickets", params={"status": "resolved"}, headers=OPS).json()] == [
        ticket["id"]
    ]
    mine = client.get("/v1/notify/tickets/me", headers=worker).json()
    assert mine[0]["status"] == "resolved" and mine[0]["note"] == "on it"
