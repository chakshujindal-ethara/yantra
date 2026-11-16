"""The talent routes through the work deployable: listings, the application flow, onboarding, the ops views."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select, update

from yantra_common.events import Envelope
from yantra_common.pii import normalise_name, pii_hash
from yantra_talent.consumers import on_account_verified
from yantra_talent.models import ONBOARDING_STEPS, OUTBOX, Application
from yantra_work.app import create_app

OPS_ID = str(uuid.uuid4())
OPS = {"X-Role": "ops", "X-Worker-Id": OPS_ID}
LISTING = {
    "title": "Hindi transcription",
    "domain": "transcription",
    "summary": "Short clips",
    "pay_min": "20",
    "pay_max": "30",
    "currency": "INR",
    "commitment": "task_based",
    "slots_total": 2,
    "cert_gate": "transcription",
    "questions": [{"key": "experience", "prompt": "Years", "kind": "text", "required": True}],
    "status": "open",
}
ANSWERS = {"answers": {"experience": "3"}}


@pytest.fixture
def client(factory):
    return TestClient(create_app(factory, rate_limit_per_minute=1000), raise_server_exceptions=False)


def verified_event(worker_id: str, account_name: str) -> Envelope:
    return Envelope(
        id=uuid.uuid4(),
        type="payout.account.verified.v1",
        subject=worker_id,
        occurred_at=datetime.now(UTC),
        data={
            "worker_id": worker_id,
            "account_name_hash": pii_hash(normalise_name(account_name)),
            "account_last4": "6789",
            "ifsc": "HDFC0001234",
            "verification": "penny_drop",
        },
    )


def worker_headers() -> dict[str, str]:
    return {"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4())}


def post_listing(client: TestClient, **fields) -> dict:
    r = client.post("/v1/talent/listings", json={**LISTING, **fields}, headers=OPS)
    assert r.status_code == 201, r.text
    return r.json()


def apply(client: TestClient, listing_id: str, headers: dict[str, str]) -> dict:
    r = client.post(f"/v1/talent/listings/{listing_id}/applications", json=ANSWERS, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


def test_listings_for_workers_and_for_ops(client):
    w = worker_headers()
    assert client.post("/v1/talent/listings", json=LISTING, headers=w).status_code == 403
    bad = client.post("/v1/talent/listings", json={**LISTING, "pay_min": "40"}, headers=OPS)
    assert bad.status_code == 422 and bad.json()["code"] == "validation_error"
    open_ = post_listing(client)
    draft = post_listing(client, title="draft", status="draft")
    assert open_["posted_at"] and open_["slots_filled"] == 0 and draft["posted_at"] is None
    rows = client.get("/v1/talent/listings", headers=w)
    assert rows.status_code == 200 and [r["id"] for r in rows.json()] == [open_["id"]]
    assert rows.json()[0]["viewer"] == {
        "prequalified": False,
        "application_id": None,
        "application_status": None,
        "redirect": None,
    }
    assert client.get("/v1/talent/listings", headers=w, params={"domain": "other"}).json() == []
    assert client.get("/v1/talent/listings", headers=w, params={"commitment": "weekend"}).status_code == 422
    assert client.get("/v1/talent/listings", headers=w, params={"all": "true"}).status_code == 403
    app = apply(client, open_["id"], w)
    everything = client.get("/v1/talent/listings", headers=OPS, params={"all": "true"})
    assert everything.status_code == 200 and {r["id"] for r in everything.json()} == {open_["id"], draft["id"]}
    counts = next(r for r in everything.json() if r["id"] == open_["id"])["applications"]
    assert counts["screening"] == 1 and counts["offered"] == 0
    one = client.get(f"/v1/talent/listings/{open_['id']}", headers=w)
    assert one.status_code == 200 and one.json()["viewer"]["application_id"] == app["id"]
    assert client.get(f"/v1/talent/listings/{draft['id']}", headers=w).status_code == 404
    assert client.get(f"/v1/talent/listings/{draft['id']}", headers=OPS).status_code == 200
    assert client.get(f"/v1/talent/listings/{uuid.uuid4()}", headers=w).status_code == 404
    closed = client.patch(f"/v1/talent/listings/{open_['id']}", json={"status": "closed"}, headers=OPS)
    assert closed.status_code == 200 and closed.json()["status"] == "closed"
    evergreen = post_listing(client, title="evergreen")
    view = client.get(f"/v1/talent/listings/{open_['id']}", headers=w).json()
    assert view["status"] == "closed" and view["viewer"]["redirect"] == {
        "listing_id": evergreen["id"],
        "title": "evergreen",
    }
    r = client.patch(f"/v1/talent/listings/{open_['id']}", json={"pay_max": "5"}, headers=OPS)
    assert r.status_code == 422 and r.json()["code"] == "invalid" and "pay_min" in r.json()["message"]
    assert client.patch(f"/v1/talent/listings/{open_['id']}", json={"nope": 1}, headers=OPS).status_code == 422
    assert client.patch(f"/v1/talent/listings/{uuid.uuid4()}", json={"title": "x"}, headers=OPS).status_code == 404


def test_application_flow_over_http(client, factory):
    w = worker_headers()
    listing = post_listing(client, slots_total=1)
    r = client.post(f"/v1/talent/listings/{listing['id']}/applications", json={"answers": {}}, headers=w)
    assert r.status_code == 422 and r.json()["code"] == "invalid" and r.json()["key"] == "experience"
    app = apply(client, listing["id"], w)
    assert app["status"] == "screening" and app["steps"] == [{"kind": "form", "status": "done"}]
    assert app["listing_title"] == "Hindi transcription" and app["worker_id"] == w["X-Worker-Id"]
    dup = client.post(f"/v1/talent/listings/{listing['id']}/applications", json=ANSWERS, headers=w)
    assert dup.status_code == 409 and dup.json()["code"] == "already_applied"
    mine = client.get("/v1/talent/applications/me", headers=w)
    assert mine.status_code == 200 and [a["id"] for a in mine.json()] == [app["id"]]
    assert (
        client.post(f"/v1/talent/applications/{app['id']}/decide", json={"decision": "offer"}, headers=w).status_code
        == 403
    )
    early = client.post(f"/v1/talent/applications/{app['id']}/offer", json={"accept": True}, headers=w)
    assert early.status_code == 409 and early.json()["code"] == "not_offered"
    body = {"decision": "offer", "note": "welcome", "offer_days": 3}
    offered = client.post(f"/v1/talent/applications/{app['id']}/decide", json=body, headers=OPS)
    assert offered.status_code == 200 and offered.json()["status"] == "offered"
    assert offered.json()["decided_by"] == OPS_ID and offered.json()["note"] == "welcome"
    expires = datetime.fromisoformat(offered.json()["offer_expires_at"])
    assert timedelta(days=2, hours=23) < expires - datetime.now(UTC) <= timedelta(days=3)
    again = client.post(f"/v1/talent/applications/{app['id']}/decide", json=body, headers=OPS)
    assert again.status_code == 409 and again.json()["code"] == "not_screening"
    assert (
        client.post(
            f"/v1/talent/applications/{app['id']}/decide", json={"decision": "offer", "offer_days": 31}, headers=OPS
        ).status_code
        == 422
    )
    pipeline = client.get(
        f"/v1/talent/listings/{listing['id']}/applications", headers=OPS, params={"status": "offered"}
    )
    assert pipeline.status_code == 200 and [a["id"] for a in pipeline.json()] == [app["id"]]
    assert client.get(f"/v1/talent/listings/{listing['id']}/applications", headers=w).status_code == 403
    accepted = client.post(f"/v1/talent/applications/{app['id']}/offer", json={"accept": True}, headers=w)
    assert accepted.status_code == 200 and accepted.json()["status"] == "accepted"
    assert client.get(f"/v1/talent/listings/{listing['id']}", headers=w).json()["slots_filled"] == 1
    assert client.get(f"/v1/talent/listings/{listing['id']}", headers=w).json()["viewer"]["prequalified"] is True
    full = client.post(f"/v1/talent/listings/{listing['id']}/applications", json=ANSWERS, headers=worker_headers())
    assert full.status_code == 409 and full.json()["code"] == "listing_full"
    gone = client.post(f"/v1/talent/applications/{app['id']}/withdraw", headers=w)
    assert gone.status_code == 409 and gone.json()["code"] == "not_withdrawable"
    with factory() as s:
        types = [t for (t,) in s.execute(select(OUTBOX.c.type).order_by(OUTBOX.c.occurred_at))]
    assert [t for t in types if t != "talent.application.moved.v1"] == [
        "talent.application.decided.v1",
        "talent.offer.accepted.v1",
    ]
    assert types.count("talent.application.moved.v1") == 3  # applied, offered, accepted
    assert client.get("/ready").json()["outbox_unpublished"].get("market") == 0


def test_withdraw_decline_and_expiry_over_http(client, factory):
    listing = post_listing(client)
    w1, w2, w3 = worker_headers(), worker_headers(), worker_headers()
    a1, a2, a3 = (apply(client, listing["id"], w) for w in (w1, w2, w3))
    withdrawn = client.post(f"/v1/talent/applications/{a1['id']}/withdraw", headers=w1)
    assert withdrawn.status_code == 200 and withdrawn.json()["status"] == "withdrawn"
    assert client.post(f"/v1/talent/applications/{a1['id']}/withdraw", headers=w2).status_code == 404
    for a in (a2, a3):
        assert (
            client.post(
                f"/v1/talent/applications/{a['id']}/decide", json={"decision": "offer"}, headers=OPS
            ).status_code
            == 200
        )
    declined = client.post(f"/v1/talent/applications/{a2['id']}/offer", json={"accept": False}, headers=w2)
    assert declined.status_code == 200 and declined.json()["status"] == "declined"
    with factory() as s:
        s.execute(
            update(Application)
            .where(Application.id == uuid.UUID(a3["id"]))
            .values(offer_expires_at=datetime.now(UTC) - timedelta(seconds=1))
        )
        s.commit()
    expired = client.post(f"/v1/talent/applications/{a3['id']}/offer", json={"accept": True}, headers=w3)
    assert expired.status_code == 409 and expired.json()["code"] == "offer_expired"
    assert client.get("/v1/talent/applications/me", headers=w3).json()[0]["status"] == "expired"
    rejected = client.post(
        f"/v1/talent/applications/{apply(client, listing['id'], w3)['id']}/decide",
        json={"decision": "reject", "note": "no"},
        headers=OPS,
    )
    assert rejected.status_code == 200 and rejected.json()["status"] == "rejected"
    assert (
        client.post(f"/v1/talent/applications/{uuid.uuid4()}/offer", json={"accept": True}, headers=w3).status_code
        == 404
    )


def test_onboarding_over_http(client, factory):
    w = worker_headers()
    base = "/v1/talent/workers/me/onboarding"
    empty = client.get(base, headers=w)
    assert empty.status_code == 200 and empty.json()["complete"] is False and len(empty.json()["steps"]) == 6
    moved = client.put(f"{base}/bank", json={"account_name": "A"}, headers=w)
    assert moved.status_code == 409 and moved.json()["code"] == "bank_moved"
    assert moved.json()["location"] == "/v1/payout/accounts/me"
    assert (
        client.put(
            f"{base}/profile", json={"legal_name": "Asha Rani", "phone": "1234567890", "city": "Pune"}, headers=w
        ).status_code
        == 422
    )
    r = client.put(
        f"{base}/profile", json={"legal_name": "Asha Rani", "phone": "9876543210", "city": "Pune"}, headers=w
    )
    assert r.status_code == 200 and r.json()["steps"][0] == {
        "key": "profile",
        "status": "done",
        "done_at": r.json()["steps"][0]["done_at"],
        "group": "Profile",
    }
    assert client.put(f"{base}/agreement", json={"accepted": False, "version": "2026-11"}, headers=w).status_code == 422
    old = client.put(f"{base}/agreement", json={"accepted": True, "version": "v1"}, headers=w)
    assert old.status_code == 422 and (old.json()["code"], old.json()["latest"]) == ("policy_outdated", "2026-11")
    agreed = client.put(f"{base}/agreement", json={"accepted": True, "version": "2026-11"}, headers=w)
    assert agreed.status_code == 200 and agreed.json()["agreement_version"] == "2026-11"
    assert client.put(f"{base}/consent", json={"accepted": True}, headers=w).status_code == 200
    bad_pan = client.put(f"{base}/identity", json={"pan": "ABC1234567", "aadhaar_last4": "1234"}, headers=w)
    assert bad_pan.status_code == 422 and bad_pan.json()["code"] == "invalid"
    assert (
        client.put(f"{base}/identity", json={"pan": "abcde1234f", "aadhaar_last4": "1234"}, headers=w).status_code
        == 200
    )
    taken = client.put(
        f"{base}/identity", json={"pan": "ABCDE1234F", "aadhaar_last4": "1234"}, headers=worker_headers()
    )
    assert taken.status_code == 409 and taken.json()["code"] == "pan_in_use"
    locked = client.put(f"{base}/identity", json={"pan": "ZZZZZ9999Z", "aadhaar_last4": "1234"}, headers=w)
    assert locked.status_code == 409 and locked.json()["code"] == "pan_locked"
    with factory() as s:  # payout verified the account: what the payout.account.verified.v1 consumer does
        on_account_verified(s, verified_event(w["X-Worker-Id"], "asha  rani"))
        s.commit()
    assert client.get(base, headers=w).json()["steps"][4]["status"] == "done"
    assert client.get("/v1/talent/onboarding", headers=OPS, params={"status": "complete"}).json() == []
    done = client.put(f"{base}/payout_ack", json={"accepted": True}, headers=w)
    assert done.status_code == 200 and done.json()["complete"] is True and done.json()["eligible_sent_at"]
    assert client.get(base, headers=w).json() == done.json()
    rows = client.get("/v1/talent/onboarding", headers=OPS, params={"status": "complete"})
    assert rows.status_code == 200 and [(r["worker_id"], r["steps_done"]) for r in rows.json()] == [
        (w["X-Worker-Id"], 6)
    ]
    assert client.get("/v1/talent/onboarding", headers=w).status_code == 403
    with factory() as s:
        payloads = [
            dict(p) for (p,) in s.execute(select(OUTBOX.c.payload).where(OUTBOX.c.type == "worker.eligible.v1"))
        ]
    assert len(payloads) == 1 and payloads[0]["pan_last4"] == "234F" and "ABCDE" not in str(payloads)


def test_a_client_only_caller_is_refused_the_listing_application_and_onboarding_surfaces(client):
    client_only = {"X-Role": "client", "X-Worker-Id": str(uuid.uuid4())}
    for method, path in (
        ("GET", "/v1/talent/listings"),
        ("GET", f"/v1/talent/listings/{uuid.uuid4()}"),
        ("POST", f"/v1/talent/listings/{uuid.uuid4()}/applications"),
        ("GET", "/v1/talent/applications/me"),
        ("POST", f"/v1/talent/applications/{uuid.uuid4()}/withdraw"),
        ("POST", f"/v1/talent/applications/{uuid.uuid4()}/offer"),
        ("GET", "/v1/talent/workers/me/onboarding"),
        *(("PUT", f"/v1/talent/workers/me/onboarding/{step}") for step in ONBOARDING_STEPS),
    ):
        r = client.request(method, path, headers=client_only, json={})
        assert (r.status_code, r.json()["message"]) == (403, "worker role required"), (method, path, r.text)
