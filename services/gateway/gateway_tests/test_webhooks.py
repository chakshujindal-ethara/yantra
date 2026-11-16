"""The one unauthenticated path: a payout rail's webhook. It reaches money with the rail's own headers and nothing
that looks like an identity; everything else about it stays closed."""

import uuid

import httpx
from fastapi.testclient import TestClient
from redis.asyncio import Redis

from yantra_gateway.app import create_app
from yantra_gateway.store import Store

from .conftest import REDIS_URL, TestVerifier, auth, echo_app

HOOK = "/v1/payout/webhooks/razorpayx"


def test_a_webhook_post_reaches_money_without_a_token_and_with_only_the_rail_headers(gateway):
    r = gateway.post(
        HOOK,
        content=b'{"event":"payout.processed"}',
        headers={
            "Content-Type": "application/json",
            "X-Razorpay-Signature": "sig",
            "X-Razorpay-Event-Id": "evt_1",
            "X-Worker-Id": str(uuid.uuid4()),
            "X-Role": "ops,finance",
            "Cookie": "a=b",
        },
    )
    assert r.status_code == 200 and r.json()["upstream"] == "money"
    sent = gateway.app.state.money.state.calls[-1]["headers"]
    assert sent["x-razorpay-signature"] == "sig" and sent["x-razorpay-event-id"] == "evt_1"
    assert sent["x-role"] == "" and "x-worker-id" not in sent and "cookie" not in sent
    assert gateway.app.state.money.state.calls[-1]["body"] == '{"event":"payout.processed"}'


def test_the_webhook_path_is_closed_to_anything_but_a_post_and_other_paths_still_need_a_token(gateway):
    assert gateway.get(HOOK).status_code == 401
    assert gateway.post("/v1/payout/webhooks/other", content=b"{}").status_code == 401
    assert gateway.post(HOOK, content=b"x" * 2000).status_code == 413  # the boundary's cap applies first


def test_a_large_webhook_body_is_refused_and_an_unreachable_money_is_503(kv):
    money = echo_app("money")

    def down(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("down")

    upstreams = {
        "work": httpx.AsyncClient(transport=httpx.MockTransport(down), base_url="http://work"),
        "money": httpx.AsyncClient(transport=httpx.ASGITransport(app=money), base_url="http://money"),
    }
    store = Store(Redis.from_url(REDIS_URL), 5, 60)
    with TestClient(create_app(TestVerifier(), store, upstreams, max_body_bytes=1 << 20)) as c:
        r = c.post(HOOK, content=b"x" * (64 * 1024 + 1))
        assert r.status_code == 413 and r.json()["code"] == "payload_too_large"
        assert c.post(HOOK, content=b"{}").status_code == 200
        assert c.get("/v1/units/x", headers=auth(uuid.uuid4())).status_code == 503  # sanity: work is down
    upstreams = {
        n: httpx.AsyncClient(transport=httpx.MockTransport(down), base_url=f"http://{n}") for n in ("work", "money")
    }
    store = Store(Redis.from_url(REDIS_URL), 5, 60)
    with TestClient(create_app(TestVerifier(), store, upstreams), raise_server_exceptions=False) as c:
        r = c.post(HOOK, content=b"{}")
        assert r.status_code == 503 and r.json()["code"] == "upstream_unavailable"
