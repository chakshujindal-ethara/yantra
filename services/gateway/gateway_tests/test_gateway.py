import io
import json
import time
import uuid

import httpx
import jwt
import pytest
from fastapi.testclient import TestClient
from jwt import PyJWKClientConnectionError
from redis.asyncio import Redis

from yantra_common.errors import Invalid
from yantra_gateway.app import clean_path, create_app, route
from yantra_gateway.auth import Unauthorized, Verifier, bearer_token
from yantra_gateway.store import Store

from .conftest import ISSUER, PRIVATE_PEM, PUBLIC, REDIS_URL, TestVerifier, auth, build_gateway, echo_app, token


def test_routes_by_path_prefix_and_refuses_dot_segments():
    assert route("/v1/payout/statement") == "money"
    assert route("/v1/batches/x/claims") == "work"
    assert clean_path("/v1/units/abc") == "/v1/units/abc"
    for bad in ("/v1/../ready", "/v1//docs", "/v1/./x"):
        with pytest.raises(Invalid):
            clean_path(bad)


def test_a_valid_token_becomes_identity_headers_and_nothing_else_leaks(gateway):
    worker = uuid.uuid4()
    spoof = {"X-Worker-Id": "spoofed", "X-Role": "ops", "X-Request-Id": "rid-1", "X-Forwarded-For": "1.2.3.4"}
    r = gateway.get("/v1/units/abc", headers={**auth(worker), **spoof, "Accept": "application/json"})
    assert r.status_code == 200, r.text
    assert r.json() == {"upstream": "work", "path": "units/abc", "worker": str(worker), "role": "", "n": 1}
    sent = gateway.app.state.work.state.calls[-1]["headers"]
    assert "authorization" not in sent and "x-forwarded-for" not in sent and "cookie" not in sent
    assert sent["x-request-id"] == "rid-1" and sent["x-worker-id"] == str(worker)
    assert sent["accept"] == "application/json"
    assert r.headers["X-Request-Id"] == "rid-1"
    assert gateway.get("/v1/../v2/units", headers=auth(worker)).status_code in (404, 422)


def test_ops_role_is_forwarded_and_payout_goes_to_money(gateway):
    r = gateway.get("/v1/payout/statement", headers=auth(uuid.uuid4(), ("ops",)))
    assert r.json()["upstream"] == "money" and r.json()["role"] == "ops"


def test_missing_expired_wrong_audience_or_bad_subject_tokens_are_401(gateway):
    worker = uuid.uuid4()
    assert gateway.get("/v1/units/x").status_code == 401
    assert gateway.get("/v1/units/x", headers={"Authorization": "Basic abc"}).status_code == 401
    expired = token(worker, exp=int(time.time()) - 100)
    r = gateway.get("/v1/units/x", headers={"Authorization": f"Bearer {expired}"})
    assert r.status_code == 401 and r.json()["code"] == "unauthorized" and "reason" not in r.json()
    bad_tokens = (
        token(worker, aud="other"),
        token(worker, iss="https://evil/realms/x"),
        token(worker, sub="svc-1"),
        token(worker, typ="ID"),
    )
    for bad in bad_tokens:
        assert gateway.get("/v1/units/x", headers={"Authorization": f"Bearer {bad}"}).status_code == 401
    assert gateway.get("/v1/units/x", headers={"Authorization": "Bearer not.a.jwt"}).status_code == 401
    with pytest.raises(Unauthorized):
        bearer_token(None)


def test_a_token_the_jwks_client_cannot_read_is_401(gateway, monkeypatch):
    import jwt

    def unreadable(self, token):
        raise jwt.DecodeError("bad header")

    monkeypatch.setattr(TestVerifier, "signing_key", unreadable)
    r = gateway.get("/v1/units/x", headers=auth(uuid.uuid4()))
    assert r.status_code == 401 and r.json()["code"] == "unauthorized"


def test_an_oversized_response_is_not_kept_for_replay(gateway):
    h = {**auth(uuid.uuid4()), "Idempotency-Key": "big-body-0001"}
    assert gateway.post("/v1/big", headers=h).status_code == 200
    assert gateway.post("/v1/big", headers=h).status_code == 200
    assert len(gateway.app.state.work.state.calls) == 2  # upstream answered both: nothing was stored


def test_a_jwks_outage_is_503_not_401(gateway, monkeypatch):
    def down(self, token):
        raise PyJWKClientConnectionError("keycloak away")

    monkeypatch.setattr(TestVerifier, "signing_key", down)
    r = gateway.get("/v1/units/x", headers=auth(uuid.uuid4()))
    assert r.status_code == 503 and r.json()["code"] == "identity_unavailable"


def test_mutations_need_an_idempotency_key_and_replays_return_the_stored_response(gateway):
    worker = uuid.uuid4()
    h = auth(worker)
    r = gateway.post("/v1/batches/b/claims", headers=h)
    assert r.status_code == 422 and "Idempotency-Key" in r.json()["message"]
    assert gateway.post("/v1/batches/b/claims", headers={**h, "Idempotency-Key": "short"}).status_code == 422
    first = gateway.post("/v1/batches/b/claims", headers={**h, "Idempotency-Key": "claim-0001"}, json={"a": 1})
    assert first.status_code == 200 and first.json()["n"] == 1
    replay = gateway.post("/v1/batches/b/claims", headers={**h, "Idempotency-Key": "claim-0001"}, json={"a": 1})
    assert replay.status_code == 200 and replay.json() == first.json()  # from the store; upstream not called again
    calls = gateway.app.state.work.state.calls
    assert len(calls) == 1
    # the same key on another path is another request
    assert gateway.post("/v1/other", headers={**h, "Idempotency-Key": "claim-0001"}).status_code == 200
    assert len(calls) == 2
    # the key is the worker's own: another worker with the same key reaches upstream
    other = gateway.post("/v1/batches/b/claims", headers={**auth(uuid.uuid4()), "Idempotency-Key": "claim-0001"})
    assert other.status_code == 200 and len(calls) == 3
    assert calls[-1]["headers"]["idempotency-key"] == "claim-0001"


def test_a_stored_4xx_replays_with_its_status_body_and_content_type_and_keys_expire(gateway, kv):
    worker = uuid.uuid4()
    h = {**auth(worker), "Idempotency-Key": "conflict-0001"}
    first = gateway.post("/v1/conflict", headers=h)
    assert first.status_code == 409 and first.headers["content-type"] == "application/problem+json"
    again = gateway.post("/v1/conflict", headers=h)
    assert (again.status_code, again.content, again.headers["content-type"]) == (
        409,
        first.content,
        first.headers["content-type"],
    )
    assert len(gateway.app.state.work.state.calls) == 1
    ttl = kv.ttl(Store.name(str(worker), "POST", "/v1/conflict", "conflict-0001"))
    assert 0 < ttl <= 60


def test_an_upstream_5xx_or_429_is_not_stored_and_frees_the_key(gateway):
    h = {**auth(uuid.uuid4()), "Idempotency-Key": "fail-0001"}
    assert gateway.post("/v1/fail", headers=h).status_code == 500
    assert gateway.post("/v1/fail", headers=h).status_code == 500
    h = {**auth(uuid.uuid4()), "Idempotency-Key": "limited-0001"}
    assert gateway.post("/v1/limited", headers=h).status_code == 429
    assert gateway.post("/v1/limited", headers=h).status_code == 429
    assert len(gateway.app.state.work.state.calls) == 4


def test_the_shared_rate_limit_answers_429_with_retry_after_and_upstream_429_passes_through(gateway):
    worker = uuid.uuid4()
    for _ in range(5):
        assert gateway.get("/v1/units/x", headers=auth(worker)).status_code == 200
    r = gateway.get("/v1/units/x", headers=auth(worker))
    assert r.status_code == 429 and 1 <= int(r.headers["Retry-After"]) <= 60 and r.json()["code"] == "rate_limited"
    assert gateway.get("/v1/units/x", headers=auth(uuid.uuid4())).status_code == 200
    r = gateway.get("/v1/limited", headers=auth(uuid.uuid4()))
    assert r.status_code == 429 and r.headers["Retry-After"] == "7"


def test_unauthenticated_floods_hit_the_address_limit_before_any_verification(kv, monkeypatch):
    calls = {"n": 0}
    real = TestVerifier.verify

    def counting(self, token):
        calls["n"] += 1
        return real(self, token)

    monkeypatch.setattr(TestVerifier, "verify", counting)
    ok = httpx.MockTransport(lambda r: httpx.Response(200))
    upstreams = {n: httpx.AsyncClient(transport=ok, base_url=f"http://{n}") for n in ("work", "money")}
    with TestClient(build_gateway(upstreams, limit=3, address_multiplier=1), raise_server_exceptions=False) as c:
        for _ in range(3):
            c.get("/v1/units/x", headers={"Authorization": "Bearer junk"})
        r = c.get("/v1/units/x", headers={"Authorization": "Bearer junk"})
        assert r.status_code == 429 and r.headers["Retry-After"] == "60"
    assert calls["n"] == 3


def test_a_request_in_flight_with_the_same_key_is_409(gateway, kv):
    worker = uuid.uuid4()
    name = Store.name(str(worker), "POST", "/v1/batches/b/claims", "inflight-0001")
    kv.set(name, "inflight")
    r = gateway.post("/v1/batches/b/claims", headers={**auth(worker), "Idempotency-Key": "inflight-0001"})
    assert r.status_code == 409 and r.json()["code"] == "request_in_flight"
    kv.delete(name)
    r = gateway.post("/v1/batches/b/claims", headers={**auth(worker), "Idempotency-Key": "inflight-0002"})
    assert r.status_code == 200


def test_an_unreachable_upstream_is_503_with_retry_after_and_the_key_is_released(kv):
    attempts = {"n": 0}

    def down(request: httpx.Request) -> httpx.Response:
        attempts["n"] += 1
        raise httpx.ConnectError("down")

    upstreams = {
        name: httpx.AsyncClient(transport=httpx.MockTransport(down), base_url=f"http://{name}")
        for name in ("work", "money")
    }
    worker = uuid.uuid4()
    with TestClient(build_gateway(upstreams, limit=100), raise_server_exceptions=False) as c:
        r = c.post("/v1/batches/b/claims", headers={**auth(worker), "Idempotency-Key": "down-0001"})
        assert r.status_code == 503 and r.headers["Retry-After"] == "2" and r.json()["code"] == "upstream_unavailable"
        assert kv.get(Store.name(str(worker), "POST", "/v1/batches/b/claims", "down-0001")) is None
        assert attempts["n"] == 2  # one retry with jitter
        assert c.get("/v1/units/x", headers=auth(worker)).status_code == 503
        assert attempts["n"] == 4


def test_redis_down_is_503_not_500():
    from redis.asyncio import Redis

    upstreams = {n: httpx.AsyncClient(base_url=f"http://{n}") for n in ("work", "money")}
    dead = Redis.from_url("redis://127.0.0.1:1/0", socket_connect_timeout=0.2, socket_timeout=0.2)
    with TestClient(create_app(TestVerifier(), Store(dead, 5, 60), upstreams), raise_server_exceptions=False) as c:
        r = c.get("/v1/units/x", headers=auth(uuid.uuid4()))
        assert r.status_code == 503 and r.json()["code"] == "gateway_unavailable"


def test_body_cap_and_health(gateway):
    r = gateway.post("/v1/x", headers={**auth(uuid.uuid4()), "Idempotency-Key": "big-00001"}, content=b"x" * 2000)
    assert r.status_code == 413
    assert gateway.get("/health").json() == {"status": "ok"}


def test_default_app_wires_keycloak_redis_and_upstreams_from_the_environment(monkeypatch):
    from yantra_gateway.app import default_app
    from yantra_gateway.config import gateway_settings

    monkeypatch.setenv("YANTRA_GATEWAY_KEYCLOAK_ISSUER", ISSUER + "/")
    monkeypatch.setenv("YANTRA_GATEWAY_REDIS_URL", "redis://localhost:6390/9")
    monkeypatch.setenv("YANTRA_GATEWAY_WORK_URL", "http://127.0.0.1:1")
    gateway_settings.cache_clear()
    try:
        assert gateway_settings().jwks_url == ISSUER + "/protocol/openid-connect/certs"
        monkeypatch.setattr(Verifier, "signing_key", lambda self, t: PUBLIC)
        with TestClient(default_app(), raise_server_exceptions=False) as c:
            assert c.get("/health").json() == {"status": "ok"}
            r = c.get("/v1/units/x", headers=auth(uuid.uuid4()))
            assert r.status_code == 503 and r.json()["code"] == "upstream_unavailable"  # verified; nothing on port 1
    finally:
        gateway_settings.cache_clear()


def test_the_verifier_fetches_keys_from_the_configured_url():
    v = Verifier(ISSUER, "yantra", "https://keys.example/realms/yantra/protocol/openid-connect/certs")
    assert v._jwks.uri == "https://keys.example/realms/yantra/protocol/openid-connect/certs"


def test_an_unknown_kid_refreshes_the_keys_at_most_once_a_minute(monkeypatch):
    from jwt import PyJWKClientError
    from jwt.algorithms import RSAAlgorithm

    jwk = {**json.loads(RSAAlgorithm.to_jwk(PUBLIC)), "kid": "k1", "use": "sig", "alg": "RS256"}
    now = [1000.0]
    v = Verifier(ISSUER, "yantra", "https://keycloak.test/certs", clock=lambda: now[0])
    fetches: list[int] = []

    class Response(io.BytesIO):
        def __enter__(self) -> "Response":
            return self

        def __exit__(self, *_: object) -> None:
            return None

    def urlopen(request: object, timeout: float, context: object) -> Response:
        fetches.append(1)
        return Response(json.dumps({"keys": [jwk]}).encode())

    monkeypatch.setattr("jwt.jwks_client.urllib.request.urlopen", urlopen)

    def signed(kid: str) -> str:
        return jwt.encode({"sub": "x"}, PRIVATE_PEM, algorithm="RS256", headers={"kid": kid})

    assert v.signing_key(signed("k1")) is not None and len(fetches) == 1  # the first fetch fills the cache
    assert v.signing_key(signed("k1")) is not None and len(fetches) == 1  # a known kid is served from it
    with pytest.raises(PyJWKClientError):
        v.signing_key(signed("forged-1"))  # an unknown kid refreshes once
    assert len(fetches) == 2
    for i in range(20):  # a stream of made-up kids inside the minute fetches nothing more
        with pytest.raises(PyJWKClientError):
            v.signing_key(signed(f"forged-{i + 2}"))
    assert len(fetches) == 2
    now[0] += 61
    jwk["kid"] = "k2"  # the realm rotated: after the minute a new kid is fetched and served
    assert v.signing_key(signed("k2")) is not None and len(fetches) == 3


def test_browser_origins_are_allowed_only_from_the_configured_list(kv):
    work = echo_app("work")
    upstreams = {"work": httpx.AsyncClient(transport=httpx.ASGITransport(app=work), base_url="http://work")}
    store = Store(Redis.from_url(REDIS_URL), limit_per_minute=5, idempotency_ttl=60)
    app = create_app(TestVerifier(), store, upstreams, allowed_origins=["http://localhost:8095"])
    with TestClient(app, raise_server_exceptions=False) as c:
        preflight = c.options(
            "/v1/batches",
            headers={
                "Origin": "http://localhost:8095",
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "authorization,idempotency-key",
            },
        )
        assert preflight.status_code == 200
        assert preflight.headers["access-control-allow-origin"] == "http://localhost:8095"
        assert "idempotency-key" in preflight.headers["access-control-allow-headers"].lower()
        r = c.get("/v1/batches", headers={**auth(uuid.uuid4()), "Origin": "http://localhost:8095"})
        assert r.status_code == 200 and r.headers["access-control-allow-origin"] == "http://localhost:8095"
        exposed = {h.strip() for h in r.headers["access-control-expose-headers"].lower().split(",")}
        assert {"retry-after", "x-request-id", "date"} <= exposed  # the app reads Date for its server-clock offset
        other = c.get("/v1/batches", headers={**auth(uuid.uuid4()), "Origin": "http://evil.test"})
        assert "access-control-allow-origin" not in other.headers
        spoof = c.options(
            "/v1/batches",
            headers={
                "Origin": "http://localhost:8095",
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "x-role",
            },
        )
        assert spoof.status_code == 400  # a header outside the list is refused at preflight
        big = c.post(
            "/v1/x",
            headers={**auth(uuid.uuid4()), "Idempotency-Key": "big-00002", "Origin": "http://localhost:8095"},
            content=b"x" * (9 << 20),
        )
        assert big.status_code == 413 and big.headers["access-control-allow-origin"] == "http://localhost:8095"
    closed = build_gateway(upstreams)
    with TestClient(closed) as c:
        r = c.options(
            "/v1/batches", headers={"Origin": "http://localhost:8095", "Access-Control-Request-Method": "GET"}
        )
        assert "access-control-allow-origin" not in r.headers


def test_the_jwks_url_can_point_inside_the_cluster(monkeypatch):
    from yantra_gateway.config import gateway_settings

    monkeypatch.setenv("YANTRA_GATEWAY_KEYCLOAK_ISSUER", ISSUER)
    monkeypatch.setenv(
        "YANTRA_GATEWAY_KEYCLOAK_JWKS_URL", "http://keycloak:8080/realms/yantra/protocol/openid-connect/certs"
    )
    monkeypatch.setenv("YANTRA_GATEWAY_ALLOWED_ORIGINS", '["http://localhost:8095"]')
    monkeypatch.setenv("YANTRA_GATEWAY_ALLOW_INSECURE_JWKS", "true")
    gateway_settings.cache_clear()
    try:
        s = gateway_settings()
        assert s.jwks_url == "http://keycloak:8080/realms/yantra/protocol/openid-connect/certs"
        assert s.allowed_origins == ["http://localhost:8095"]
    finally:
        gateway_settings.cache_clear()


def test_a_token_without_a_type_and_a_key_from_another_realm_are_401(gateway, monkeypatch, caplog):
    from jwt import PyJWKClientError

    worker = uuid.uuid4()
    claims = {"realm_access": {"roles": []}}
    untyped = jwt.encode(
        {
            "iss": ISSUER,
            "aud": "yantra",
            "sub": str(worker),
            "iat": int(time.time()),
            "exp": int(time.time()) + 60,
            **claims,
        },
        PRIVATE_PEM,
        algorithm="RS256",
    )
    r = gateway.get("/v1/units/x", headers={"Authorization": f"Bearer {untyped}"})
    assert r.status_code == 401 and r.json()["message"] == "not an access token"

    def other_realm(self, token):
        raise PyJWKClientError("Unable to find a signing key that matches")

    monkeypatch.setattr(TestVerifier, "signing_key", other_realm)
    with caplog.at_level("WARNING", logger="yantra.gateway"):
        r = gateway.get("/v1/units/x", headers=auth(worker))
    assert r.status_code == 401 and "no signing key" in caplog.text


def test_the_idempotency_scope_includes_the_query_string(gateway):
    worker = uuid.uuid4()
    h = {**auth(worker), "Idempotency-Key": "import-0001"}
    dry = gateway.post("/v1/batches/b/units/import?dry_run=true", headers=h)
    real = gateway.post("/v1/batches/b/units/import?dry_run=false", headers=h)
    assert dry.json()["n"] == 1 and real.json()["n"] == 2  # two calls reached the service, not one replay
    assert gateway.post("/v1/batches/b/units/import?dry_run=false", headers=h).json()["n"] == 2  # same scope: replayed


def test_a_timeout_after_sending_is_503_without_a_retry(kv):
    attempts = {"n": 0}

    def slow(request: httpx.Request) -> httpx.Response:
        attempts["n"] += 1
        raise httpx.ReadTimeout("slow")

    upstreams = {
        name: httpx.AsyncClient(transport=httpx.MockTransport(slow), base_url=f"http://{name}")
        for name in ("work", "money")
    }
    with TestClient(build_gateway(upstreams, limit=100), raise_server_exceptions=False) as c:
        r = c.post("/v1/projects", headers={**auth(uuid.uuid4()), "Idempotency-Key": "slow-0001"})
        assert r.status_code == 503 and attempts["n"] == 1  # the create may have committed: never sent twice


def test_jwks_settings_must_match_the_issuer_realm_and_use_tls(monkeypatch):
    from yantra_gateway.config import GatewaySettings

    base = {"keycloak_issuer": "https://kc.example/realms/yantra"}
    with pytest.raises(ValueError, match="not the issuer's realm"):
        GatewaySettings(**base, keycloak_jwks_url="https://kc.example/realms/other/protocol/openid-connect/certs")
    with pytest.raises(ValueError, match="https"):
        GatewaySettings(**base, keycloak_jwks_url="http://kc:8080/realms/yantra/protocol/openid-connect/certs")
    ok = GatewaySettings(
        **base, keycloak_jwks_url="http://kc:8080/realms/yantra/protocol/openid-connect/certs", allow_insecure_jwks=True
    )
    assert ok.jwks_url.startswith("http://kc:8080/")


def test_every_known_role_is_forwarded_in_a_fixed_order_and_none_means_an_empty_header(gateway):
    r = gateway.get("/v1/units/x", headers=auth(uuid.uuid4(), ("worker", "client")))
    assert r.status_code == 200 and r.json()["role"] == "client,worker"
    r = gateway.get("/v1/units/x", headers=auth(uuid.uuid4(), ("ops",)))
    assert r.json()["role"] == "ops"
    r = gateway.get("/v1/units/x", headers=auth(uuid.uuid4(), ("offline_access", "worker", "ops")))
    assert r.json()["role"] == "ops,worker"
    six = ("worker", "client", "reviewer", "finance", "ops", "admin", "mfa-required")
    r = gateway.get("/v1/units/x", headers=auth(uuid.uuid4(), six))
    assert r.json()["role"] == "admin,ops,finance,reviewer,client,worker"
    r = gateway.get("/v1/units/x", headers=auth(uuid.uuid4(), ()))
    assert r.json()["role"] == ""
    assert gateway.app.state.work.state.calls[-1]["headers"]["x-role"] == ""
