"""Gateway hardening: the display name forwarded, the security headers, readiness, idempotency bound to the body,
the insecure-JWKS guard, and the address limit keyed on the peer, never on a forwarded header."""

import asyncio
import uuid
from urllib.parse import unquote

import httpx
import pytest
from fastapi.testclient import TestClient
from jwt import PyJWKClientConnectionError
from redis.asyncio import Redis

from yantra_common.deps import role_header
from yantra_gateway.app import create_app, identity_headers
from yantra_gateway.auth import Caller, Verifier
from yantra_gateway.config import GatewaySettings
from yantra_gateway.store import MISMATCH, Store

from .conftest import ISSUER, REDIS_URL, TestVerifier, auth, build_gateway, echo_app, token


def test_the_display_name_is_cleaned_capped_and_percent_encoded():
    caller = Caller(uuid.uuid4(), frozenset({"worker"}), "j", name="  आशा \n रानी ")
    headers = identity_headers(caller, "rid")
    assert headers["X-Name"].isascii() and unquote(headers["X-Name"]) == "आशा रानी"
    assert "X-Name" not in identity_headers(Caller(uuid.uuid4(), frozenset(), "j"), "rid")
    assert "X-Name" not in identity_headers(Caller(uuid.uuid4(), frozenset(), "j", name="  "), "rid")


def test_the_name_comes_from_the_token_and_a_client_cannot_set_it(gateway):
    worker = uuid.uuid4()
    bearer = {"Authorization": f"Bearer {token(worker, ('worker',), name='Asha Rani')}"}
    gateway.get("/v1/units/x", headers={**bearer, "X-Name": "Someone%20Else"})
    assert gateway.app.state.work.state.calls[-1]["headers"]["x-name"] == "Asha%20Rani"
    fallback = {"Authorization": f"Bearer {token(worker, preferred_username='worker1')}"}
    gateway.get("/v1/units/x", headers=fallback)
    assert gateway.app.state.work.state.calls[-1]["headers"]["x-name"] == "worker1"
    gateway.get("/v1/units/x", headers={**auth(worker), "X-Name": "spoof"})
    assert "x-name" not in gateway.app.state.work.state.calls[-1]["headers"]


def test_the_email_and_its_verification_come_from_the_token_and_a_client_cannot_set_them(gateway):
    worker = uuid.uuid4()
    verified = {"Authorization": f"Bearer {token(worker, email='aśā+1@yantra.local', email_verified=True)}"}
    gateway.get("/v1/units/x", headers={**verified, "X-Email": "evil@example.com", "X-Email-Verified": "true"})
    sent = gateway.app.state.work.state.calls[-1]["headers"]
    assert unquote(sent["x-email"]) == "aśā+1@yantra.local" and sent["x-email"].isascii()
    assert sent["x-email-verified"] == "true"
    unverified = {"Authorization": f"Bearer {token(worker, email='w@yantra.local', email_verified='yes')}"}
    gateway.get("/v1/units/x", headers=unverified)
    assert gateway.app.state.work.state.calls[-1]["headers"]["x-email-verified"] == "false"
    gateway.get("/v1/units/x", headers={**auth(worker), "X-Email": "spoof@example.com"})
    assert "x-email" not in gateway.app.state.work.state.calls[-1]["headers"]
    assert "x-email-verified" not in gateway.app.state.work.state.calls[-1]["headers"]


def test_the_mfa_marker_role_never_reaches_a_service():
    assert role_header(frozenset({"ops", "mfa-required", "default-roles-yantra", "finance"})) == "ops,finance"


def test_every_answer_carries_the_security_headers_and_hsts_only_when_asked(gateway, kv):
    r = gateway.get("/v1/units/x", headers=auth(uuid.uuid4()))
    for header, value in (
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "no-referrer"),
        ("Cache-Control", "no-store"),
    ):
        assert r.headers[header] == value
    assert "default-src 'none'" in r.headers["Content-Security-Policy"]
    assert "Strict-Transport-Security" not in r.headers
    assert gateway.get("/v1/units/x").headers["X-Frame-Options"] == "DENY"  # a 401 too
    work, money = echo_app("work"), echo_app("money")
    upstreams = {
        "work": httpx.AsyncClient(transport=httpx.ASGITransport(app=work), base_url="http://work"),
        "money": httpx.AsyncClient(transport=httpx.ASGITransport(app=money), base_url="http://money"),
    }
    store = Store(Redis.from_url(REDIS_URL), 5, 60)
    with TestClient(create_app(TestVerifier(), store, upstreams, hsts=True), raise_server_exceptions=False) as c:
        assert c.get("/health").headers["Strict-Transport-Security"].startswith("max-age=31536000")
        assert "Content-Security-Policy" not in c.get("/docs").headers


def test_ready_needs_redis_and_the_keys(gateway, monkeypatch):
    assert gateway.get("/ready").json() == {"status": "ok"}
    monkeypatch.setattr(gateway.app.state, "verifier", None, raising=False)
    upstreams = {n: httpx.AsyncClient(base_url=f"http://{n}") for n in ("work", "money")}
    cold = TestVerifier()
    monkeypatch.setattr(cold, "warm", lambda: False)
    with TestClient(create_app(cold, Store(Redis.from_url(REDIS_URL), 5, 60), upstreams)) as c:
        r = c.get("/ready")
        assert (r.status_code, r.json()) == (503, {"status": "jwks_not_loaded"})
        c.get("/v1/units/x", headers=auth(uuid.uuid4()))  # a verified token proves the keys are here
        assert c.get("/ready").status_code == 200
    late = TestVerifier()
    attempts = iter([False, True])  # the identity provider is down at start, up by the next probe
    monkeypatch.setattr(late, "warm", lambda: next(attempts) and setattr(late, "loaded", True) is None)
    upstreams = {n: httpx.AsyncClient(base_url=f"http://{n}") for n in ("work", "money")}
    with TestClient(create_app(late, Store(Redis.from_url(REDIS_URL), 5, 60), upstreams)) as c:
        assert c.get("/ready").status_code == 200  # the start-up warm failed; /ready fetched the keys itself
        assert late.loaded
    dead = Redis.from_url("redis://127.0.0.1:1/0", socket_connect_timeout=0.2, socket_timeout=0.2)
    upstreams = {n: httpx.AsyncClient(base_url=f"http://{n}") for n in ("work", "money")}
    with TestClient(create_app(TestVerifier(), Store(dead, 5, 60), upstreams)) as c:
        r = c.get("/ready")
        assert (r.status_code, r.json()) == (503, {"status": "redis_unavailable"})


def test_warming_fetches_the_keys_once_and_logs_a_failure(monkeypatch, caplog):
    v = Verifier(ISSUER, "yantra", "https://keys.example/realms/yantra/protocol/openid-connect/certs")
    monkeypatch.setattr(v._jwks, "get_jwk_set", lambda: {"keys": []})
    assert v.warm() is True and v.loaded is True
    v2 = Verifier(ISSUER, "yantra", "https://keys.example/realms/yantra/protocol/openid-connect/certs")

    def down() -> None:
        raise PyJWKClientConnectionError("down")

    monkeypatch.setattr(v2._jwks, "get_jwk_set", down)
    assert v2.warm() is False and v2.loaded is False and "jwks warm-up failed" in caplog.text


def test_a_key_reused_with_another_body_is_422_and_the_same_body_replays(gateway):
    h = {**auth(uuid.uuid4()), "Idempotency-Key": "pay-0000001"}
    first = gateway.post("/v1/things", headers=h, json={"a": 1})
    assert first.status_code == 200
    assert gateway.post("/v1/things", headers=h, json={"a": 1}).json() == first.json()  # a replay
    other = gateway.post("/v1/things", headers=h, json={"a": 2})
    assert other.status_code == 422 and other.json()["code"] == "idempotency_mismatch"
    assert len(gateway.app.state.work.state.calls) == 1


def test_a_key_in_flight_with_another_body_is_a_mismatch_not_a_409(kv):
    async def run() -> None:
        store = Store(Redis.from_url(REDIS_URL), 5, 60)
        assert await store.begin("idem:k", "aaa") is None
        assert await store.begin("idem:k", "aaa") is False
        assert await store.begin("idem:k", "bbb") is MISMATCH
        kv.set("idem:old", "inflight")  # a key written before bodies were bound: treated as in flight
        assert await store.begin("idem:old", "ccc") is False
        await store.close()

    asyncio.run(run())


def test_insecure_jwks_is_refused_outside_the_local_rig(monkeypatch):
    base = {"keycloak_issuer": ISSUER, "keycloak_jwks_url": "http://keycloak:8080/realms/yantra/certs"}
    assert GatewaySettings(**base, allow_insecure_jwks=True).env == "local"
    monkeypatch.setenv("YANTRA_ENV", "staging")
    with pytest.raises(ValueError, match="only allowed with YANTRA_ENV=local"):
        GatewaySettings(**base, allow_insecure_jwks=True)
    assert GatewaySettings(keycloak_issuer=ISSUER).env == "staging"


def test_the_address_limit_keys_on_the_peer_not_on_a_forwarded_header(kv):
    app = build_gateway({}, limit=1, address_multiplier=2)
    with TestClient(app, raise_server_exceptions=False) as c:
        codes = [c.get("/v1/x", headers={"X-Forwarded-For": f"10.0.0.{i}"}).status_code for i in range(3)]
    assert codes == [401, 401, 429]  # three "different" clients, one peer: one bucket


def test_metric_labels_stay_bounded_whatever_path_a_caller_picks(gateway):
    from prometheus_client import REGISTRY

    def seen(route: str, status: str) -> float:
        labels = {"process": "gateway", "method": "POST", "route": route, "status": status}
        return REGISTRY.get_sample_value("yantra_http_request_duration_seconds_count", labels) or 0.0

    worker = uuid.uuid4()
    before = seen("other", "422")
    # the gateway refuses it itself (no Idempotency-Key): the caller's made-up word never becomes a series
    assert gateway.post("/v1/scanner-word-1234", headers=auth(worker)).status_code == 422
    assert seen("/v1/scanner-word-1234", "422") == 0.0 and seen("other", "422") == before + 1
    answered = gateway.post("/v1/things", headers={**auth(worker), "Idempotency-Key": "metric-key-1"})
    assert answered.status_code == 200 and seen("/v1/things", "200") >= 1
