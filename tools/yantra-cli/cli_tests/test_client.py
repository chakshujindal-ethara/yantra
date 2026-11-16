import json
import time

import httpx
import pytest

from yantra_cli.auth import AuthError, Session, login, refresh
from yantra_cli.client import MAX_ATTEMPTS, Gateway, GatewayError
from yantra_cli.config import Config
from yantra_cli.render import render

from .conftest import WORKER, fake_jwt


def test_config_defaults_and_token_url():
    c = Config.from_env({})
    assert c.gateway_url == "http://localhost:8090" and c.token_url.endswith(
        "/realms/yantra/protocol/openid-connect/token"
    )
    assert c.session_file.name == "session.json"


def test_login_refresh_and_session_file(backend, cfg):
    s = login(backend.client, cfg, "worker1", "yantra")
    assert s.worker_id == WORKER and s.roles == ["worker"] and not s.expiring()
    s.save(cfg.session_file)
    assert Session.load(cfg.session_file) == s and oct(cfg.session_file.stat().st_mode)[-3:] == "600"
    assert Session.load(cfg.session_file.with_name("missing")) is None
    cfg.session_file.write_text("{not json")
    assert Session.load(cfg.session_file) is None
    cfg.session_file.write_text('{"username": "x"}')
    assert Session.load(cfg.session_file) is None
    s2 = refresh(backend.client, cfg, s)
    assert s2.username == "worker1" and backend.tokens_issued == 2
    with pytest.raises(AuthError, match="Invalid user credentials"):
        login(backend.client, cfg, "worker1", "wrong")


def test_login_errors_name_the_cause(cfg):
    def down(request):
        raise httpx.ConnectError("boom")

    with pytest.raises(AuthError, match="unreachable"):
        login(httpx.Client(transport=httpx.MockTransport(down)), cfg, "w", "p")
    text = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(502, text="bad gateway")))
    with pytest.raises(AuthError, match="bad gateway"):
        login(text, cfg, "w", "p")
    odd = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(400, json=["not", "a", "dict"])))
    with pytest.raises(AuthError, match="400"):
        login(odd, cfg, "w", "p")


def session() -> Session:
    return Session("worker1", fake_jwt(WORKER, ["worker"]), "r" * 20, time.time() + 300)


def test_mutations_carry_a_key_and_reads_do_not(backend, cfg):
    backend.on("POST /v1/x", lambda r: httpx.Response(201, json={"key": r.headers.get("Idempotency-Key")}))
    backend.on(
        "GET /v1/y",
        lambda r: httpx.Response(200, json={"key": r.headers.get("Idempotency-Key"), "q": str(r.url.params)}),
    )
    gw = Gateway(cfg, session(), backend.client, sleep=lambda s: None)
    first, second = gw.post("/v1/x"), gw.post("/v1/x")
    assert len(first["key"]) == 36 and first["key"] != second["key"]
    assert gw.call("POST", "/v1/x", key="fixed-key-1")["key"] == "fixed-key-1"
    assert gw.get("/v1/y", status="paid", skip=None) == {"key": None, "q": "status=paid"}
    assert backend.requests[-1].headers["Authorization"].startswith("Bearer ")


def test_a_401_refreshes_once_and_the_new_session_is_saved(backend, cfg):
    calls = {"n": 0}

    def flaky(r):
        calls["n"] += 1
        return (
            httpx.Response(401, json={"code": "unauthorized"})
            if calls["n"] == 1
            else httpx.Response(200, json={"ok": 1})
        )

    backend.on("GET /v1/z", flaky)
    saved = []
    gw = Gateway(cfg, session(), backend.client, sleep=lambda s: None, on_session=saved.append)
    assert gw.get("/v1/z") == {"ok": 1} and len(saved) == 1 and backend.tokens_issued == 1
    backend.on("GET /v1/never", httpx.Response(401, json={"code": "unauthorized", "message": "no", "request_id": "r1"}))
    with pytest.raises(GatewayError, match="401 unauthorized"):
        gw.get("/v1/never")


def test_an_expiring_session_is_refreshed_before_the_call(backend, cfg):
    backend.on("GET /v1/z", {"ok": 1})
    s = Session("worker1", fake_jwt(WORKER, ["worker"]), "r" * 20, time.time() - 1)
    gw = Gateway(cfg, s, backend.client)
    assert gw.get("/v1/z") == {"ok": 1} and backend.tokens_issued == 1 and not gw.session.expiring()


def test_429_and_in_flight_wait_for_retry_after_then_give_up_and_a_503_repeats_reads_only(backend, cfg):
    waits = []
    calls = {"n": 0}

    def limited(r):
        calls["n"] += 1
        if calls["n"] == 1:
            return httpx.Response(429, json={"code": "rate_limited"}, headers={"Retry-After": "7"})
        if calls["n"] == 2:
            return httpx.Response(409, json={"code": "request_in_flight"})
        if calls["n"] == 3:
            return httpx.Response(
                429, json={"code": "rate_limited"}, headers={"Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"}
            )
        return httpx.Response(200, json={"ok": calls["n"]})

    backend.on("POST /v1/x", limited)
    gw = Gateway(cfg, session(), backend.client, sleep=waits.append)
    assert gw.post("/v1/x") == {"ok": 4} and waits == [7.0, 1.0, 1.0]
    reads = {"n": 0}

    def away(r):
        reads["n"] += 1
        if reads["n"] == 1:
            return httpx.Response(503, json={"code": "upstream_unavailable"}, headers={"Retry-After": "2"})
        return httpx.Response(200, json={"ok": True})

    backend.on("GET /v1/r", away)
    assert gw.get("/v1/r") == {"ok": True} and waits[-1] == 2.0
    backend.on(
        "POST /v1/create",
        httpx.Response(503, json={"code": "upstream_unavailable", "message": "away", "request_id": "r"}),
    )
    with pytest.raises(GatewayError, match="503 upstream_unavailable"):
        gw.post("/v1/create")  # never repeated: the service may have committed
    assert sum(1 for q in backend.requests if q.url.path == "/v1/create") == 1
    backend.on(
        "POST /v1/always",
        httpx.Response(429, json={"code": "rate_limited", "message": "slow"}, headers={"Retry-After": "900"}),
    )
    with pytest.raises(GatewayError) as e:
        gw.post("/v1/always")
    assert e.value.status == 429 and waits[-(MAX_ATTEMPTS - 1) :] == [30.0] * (MAX_ATTEMPTS - 1)


def test_errors_keep_the_envelope_and_odd_bodies_do_not_crash(backend, cfg):
    backend.on(
        "GET /v1/a",
        httpx.Response(409, json={"code": "batch_held", "message": "held", "request_id": "r9", "held": {"x": 1}}),
    )
    backend.on("GET /v1/b", httpx.Response(502, text="<html>bad</html>"))
    backend.on("GET /v1/c", httpx.Response(500, json=["not", "a", "dict"]))
    backend.on("GET /v1/csv", httpx.Response(200, text="a,b\n1,2\n", headers={"content-type": "text/plain"}))
    gw = Gateway(cfg, session(), backend.client)
    with pytest.raises(GatewayError) as e:
        gw.get("/v1/a")
    assert e.value.code == "batch_held" and e.value.body["held"] == {"x": 1} and "r9" in str(e.value)
    with pytest.raises(GatewayError, match="http_error"):
        gw.get("/v1/b")
    with pytest.raises(GatewayError, match="http_error"):
        gw.get("/v1/c")
    assert gw.get("/v1/csv") == "a,b\n1,2\n"

    def down(request):
        raise httpx.ConnectTimeout("slow")

    with pytest.raises(GatewayError, match="unreachable"):
        Gateway(cfg, session(), httpx.Client(transport=httpx.MockTransport(down))).get("/v1/a")


def test_render_tables_records_and_json():
    rows = [{"id": "1", "amount": "2.00", "extra": None}, {"id": "22", "nested": {"a": 1}}]
    out = render(rows)
    assert out.splitlines()[0].split() == ["id", "amount", "extra", "nested"] and "-" in out and '{"a":1}' in out
    assert render([]) == "(none)" and render(["a", 1]) == "a\n1" and render("text\n") == "text" and render(3) == "3"
    rec = render({"id": "x", "lines": rows[:1], "meta": {"k": "v"}, "empty": []})
    assert "lines:" in rec and "id     x" in rec and '"k": "v"' in rec
    assert json.loads(render(rows, as_json=True)) == rows and render("raw", as_json=True) == "raw"


def test_a_409_without_a_json_body_is_an_error_not_a_retry(backend, cfg):
    backend.on("POST /v1/x", httpx.Response(409, text="conflict", headers={"content-type": "text/plain"}))
    with pytest.raises(GatewayError, match="409 http_error"):
        Gateway(cfg, session(), backend.client, sleep=lambda s: None).post("/v1/x")
