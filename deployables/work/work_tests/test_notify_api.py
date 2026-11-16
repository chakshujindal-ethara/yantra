"""The notify surface through the work deployable: a worker's channel and inbox, never anyone else's."""

import uuid
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from yantra_common.events import Envelope
from yantra_notify.service import on_verdict_accepted, send_verifications
from yantra_notify.testing import FakeMailer
from yantra_work.app import create_app


@pytest.fixture
def client(factory):
    return TestClient(create_app(factory, rate_limit_per_minute=1000), raise_server_exceptions=False)


def test_channel_and_inbox_are_the_callers_own(client, factory):
    worker, other = str(uuid.uuid4()), str(uuid.uuid4())
    h = {"X-Role": "worker", "X-Worker-Id": worker}
    bad = client.put("/v1/notify/channel", json={"email": "not-an-address"}, headers=h)
    assert bad.status_code == 422 and bad.json()["code"] == "validation_error"
    ok = client.put("/v1/notify/channel", json={"email": "w@example.test"}, headers=h)
    assert ok.status_code == 200 and ok.json()["worker_id"] == worker and ok.json()["email"] is None
    assert ok.json()["pending_email"] == "w@example.test" and ok.json()["verify_sent_at"] is None
    assert client.get("/v1/notify/inbox", headers=h).json() == []
    mailer = FakeMailer()
    with factory() as s:
        assert send_verifications(s, mailer) == 1
        s.commit()
    code = mailer.sent[0][2].split("Your code is ")[1][:6]
    wrong = client.post("/v1/notify/channel/verify", json={"code": f"{(int(code) + 1) % 1_000_000:06d}"}, headers=h)
    assert wrong.status_code == 422 and wrong.json()["code"] == "wrong_code"
    malformed = client.post("/v1/notify/channel/verify", json={"code": "12ab56"}, headers=h)
    assert malformed.status_code == 422 and malformed.json()["code"] == "validation_error"
    right = client.post("/v1/notify/channel/verify", json={"code": code}, headers=h)
    assert right.status_code == 200 and right.json()["email"] == "w@example.test"
    again = client.post("/v1/notify/channel/verify", json={"code": code}, headers=h)
    assert again.status_code == 409 and again.json()["code"] == "nothing_to_verify"
    assert client.get("/v1/notify/channel", headers=h).json()["email"] == "w@example.test"
    assert client.get("/v1/notify/channel", headers={"X-Role": "worker", "X-Worker-Id": other}).status_code == 404
    with factory() as s:
        data = {
            "unit_id": str(uuid.uuid4()),
            "batch_id": str(uuid.uuid4()),
            "submission_id": str(uuid.uuid4()),
            "worker_id": worker,
            "reviewer_id": other,
            "auditor_id": None,
            "rubric_version": "v1",
        }
        env = Envelope(uuid.uuid4(), "quality.verdict.accepted.v1", "t", datetime.now(UTC), data)
        on_verdict_accepted(s, env)
        s.commit()
    [n] = client.get("/v1/notify/inbox", headers=h).json()
    assert n["kind"] == "verdict_accepted" and n["read_at"] is None and n["emailed_at"] is None
    assert client.get("/v1/notify/inbox", headers={"X-Role": "worker", "X-Worker-Id": other}).json() == []
    assert (
        client.post(f"/v1/notify/inbox/{n['id']}/read", headers={"X-Role": "worker", "X-Worker-Id": other}).status_code
        == 404
    )
    assert client.post(f"/v1/notify/inbox/{n['id']}/read", headers=h).json()["read_at"] is not None
    assert client.get("/v1/notify/inbox", headers={"X-Role": "worker"}).status_code == 422
    assert client.get("/ready").json()["outbox_unpublished"] == {
        "market": 0,
        "talent": 0,
        "assess": 0,
        "quality": 0,
        "tracker": 0,
    }


def test_a_client_only_caller_has_no_channel_or_inbox_but_may_raise_a_ticket(client):
    client_only = {"X-Role": "client", "X-Worker-Id": str(uuid.uuid4())}
    for method, path in (
        ("PUT", "/v1/notify/channel"),
        ("GET", "/v1/notify/channel"),
        ("GET", "/v1/notify/inbox"),
        ("POST", f"/v1/notify/inbox/{uuid.uuid4()}/read"),
    ):
        r = client.request(method, path, headers=client_only, json={"email": "c@example.test"})
        assert (r.status_code, r.json()["code"]) == (403, "forbidden"), (method, path, r.text)
    ticket = {"category": "other", "title": "invoice question", "body": "where is it"}
    assert client.post("/v1/notify/tickets", json=ticket, headers=client_only).status_code == 201
    assert client.get("/v1/notify/tickets/me", headers=client_only).status_code == 200


def test_the_badge_count_ticket_author_names_and_the_board_counts(client, factory):
    from yantra_notify.service import on_person_seen

    worker = str(uuid.uuid4())
    h = {"X-Role": "worker", "X-Worker-Id": worker}
    ops = {"X-Role": "ops", "X-Worker-Id": str(uuid.uuid4())}
    assert client.get("/v1/notify/inbox/unread-count", headers=h).json() == {"unread": 0}
    with factory() as s:
        on_person_seen(
            s,
            Envelope(
                uuid.uuid4(),
                "talent.person.seen.v1",
                worker,
                datetime.now(UTC),
                {"id": worker, "name": "Asha Rani", "kind": "worker"},
            ),
        )
        on_verdict_accepted(s, Envelope(uuid.uuid4(), "quality.verdict.accepted.v1", "t", datetime.now(UTC), {
            "unit_id": str(uuid.uuid4()), "batch_id": str(uuid.uuid4()), "submission_id": str(uuid.uuid4()),
            "worker_id": worker, "reviewer_id": str(uuid.uuid4()), "auditor_id": None, "rubric_version": "v1",
        }))  # fmt: skip
        s.commit()
    assert client.get("/v1/notify/inbox/unread-count", headers=h).json() == {"unread": 1}
    made = client.post("/v1/notify/tickets", json={"category": "bug", "title": "t", "body": "b"}, headers=h)
    assert made.status_code == 201 and made.json()["author_name"] == "Asha Rani"
    assert client.get("/v1/notify/tickets/me", headers=h).json()[0]["author_name"] == "Asha Rani"
    assert client.get("/v1/notify/tickets", headers=ops).json()[0]["author_name"] == "Asha Rani"
    moved = client.post(f"/v1/notify/tickets/{made.json()['id']}/status", json={"status": "in_progress"}, headers=ops)
    assert moved.json()["author_name"] == "Asha Rani"
    assert client.get("/v1/notify/attention", headers=ops).json() == {"tickets_open": 0, "tickets_in_progress": 1}
    assert client.get("/v1/notify/attention", headers=h).status_code == 403
