"""Logs, traces and error reports: JSON lines carry the request id and the access fields and never the query
string; text stays the default; tracing and Sentry stay off until configured, and Sentry strips personal data."""

import json
import logging

from fastapi import FastAPI
from fastapi.testclient import TestClient
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from sqlalchemy import create_engine, text

from yantra_common import boot as boot_module
from yantra_common.http import CURRENT_REQUEST, JsonFormatter, RequestIdFilter, configure_logging, install_boundary
from yantra_common.sentry import install_sentry, scrub
from yantra_common.testing import ADMIN_URL
from yantra_common.tracing import install_tracing


def record(msg: str = "hello %s", *args: object, exc: bool = False, **extra: object) -> logging.LogRecord:
    r = logging.LogRecord("yantra.test", logging.WARNING, __file__, 1, msg, args or ("there",), None)
    if exc:
        try:
            raise ValueError("bad")
        except ValueError:
            import sys

            r.exc_info = sys.exc_info()
    for k, v in extra.items():
        setattr(r, k, v)
    RequestIdFilter().filter(r)
    return r


def test_a_json_line_has_the_request_id_the_extras_and_the_traceback():
    token = CURRENT_REQUEST.set("rid-1")
    try:
        line = json.loads(JsonFormatter().format(record(status=200, exc=True)))
    finally:
        CURRENT_REQUEST.reset(token)
    assert line["msg"] == "hello there" and line["level"] == "WARNING" and line["logger"] == "yantra.test"
    assert line["request_id"] == "rid-1" and line["status"] == 200 and "ValueError: bad" in line["exc"]
    assert json.loads(JsonFormatter().format(record()))["request_id"] is None


def test_the_format_comes_from_log_format_and_text_is_the_default(monkeypatch):
    monkeypatch.setenv("LOG_FORMAT", "json")
    configure_logging()
    assert isinstance(logging.getLogger().handlers[0].formatter, JsonFormatter)
    monkeypatch.delenv("LOG_FORMAT")
    configure_logging()
    assert not isinstance(logging.getLogger().handlers[0].formatter, JsonFormatter)
    configure_logging(fmt="JSON")
    assert isinstance(logging.getLogger().handlers[0].formatter, JsonFormatter)
    configure_logging(fmt="text")


def test_one_access_line_per_request_without_the_query_and_none_for_health(caplog) -> None:
    app = FastAPI()
    install_boundary(app, 1000)

    @app.get("/v1/x")
    def x() -> dict[str, str]:
        logging.getLogger("yantra.inner").info("inside")
        return {}

    @app.get("/health")
    def health() -> dict[str, str]:
        return {}

    caplog.set_level(logging.INFO)
    caplog.handler.addFilter(RequestIdFilter())
    client = TestClient(app)
    caller = "00000000-0000-4000-8000-000000000001"
    client.get("/v1/x?secret=1", headers={"X-Request-Id": "req-9", "X-Worker-Id": caller})
    client.get("/v1/x", headers={"X-Worker-Id": "not-a-uuid"})
    client.get("/health")
    lines = [r for r in caplog.records if r.name == "yantra.access"]
    assert len(lines) == 2
    first = lines[0]
    assert first.getMessage().startswith("GET /v1/x status=200") and "secret" not in first.getMessage()
    assert first.caller == caller and first.status == 200 and first.path == "/v1/x"
    assert lines[1].caller is None
    inner = next(r for r in caplog.records if r.name == "yantra.inner")
    assert inner.request_id == "req-9"  # a line logged inside the route carries it
    assert first.request_id == "req-9" and CURRENT_REQUEST.get() is None


def test_tracing_is_off_without_an_endpoint_and_spans_requests_and_sql_with_one() -> None:
    assert install_tracing(FastAPI(), "t", env={}) is False
    exporter = InMemorySpanExporter()
    app = FastAPI()
    engine = create_engine(ADMIN_URL, future=True)

    @app.get("/v1/q")
    def q() -> dict[str, int]:
        with engine.connect() as c:
            return {"n": int(c.execute(text("select 1")).scalar_one())}

    @app.get("/health")
    def health() -> dict[str, str]:
        return {}

    import httpx

    client = httpx.Client()
    assert install_tracing(app, "tracetest", engine=engine, clients=[client], exporter=exporter, env={}) is True
    with TestClient(app) as c:
        assert c.get("/v1/q").json() == {"n": 1}
        c.get("/health")
    names = [s.name for s in exporter.get_finished_spans()]
    assert any(n.startswith("GET /v1/q") for n in names) and any("select" in n.lower() or n == "connect" for n in names)
    assert not any("/health" in n for n in names)
    client.close()
    engine.dispose()


def test_tracing_uses_the_otlp_exporter_when_an_endpoint_is_set():
    app = FastAPI()
    assert install_tracing(app, "otlp", env={"OTEL_EXPORTER_OTLP_ENDPOINT": "http://localhost:4318"}) is True
    app.state.tracer_provider.shutdown()


def test_sentry_is_off_without_a_dsn_and_scrubs_personal_data(monkeypatch):
    assert install_sentry("t", env={}) is False
    event = {
        "request": {
            "data": {"pan": "x"},
            "cookies": {"a": "b"},
            "query_string": "q=1",
            "env": {"REMOTE_ADDR": "1.2.3.4"},
            "headers": {"Authorization": "Bearer t", "X-Name": "Asha", "Accept": "application/json"},
        },
        "user": {"id": "u"},
        "message": "boom",
    }
    out = scrub(event)
    assert out["request"] == {"headers": {"Accept": "application/json"}} and "user" not in out
    assert scrub({"message": "no request"}) == {"message": "no request"}
    assert scrub({"request": {"headers": "raw"}})["request"] == {"headers": "raw"}

    calls: dict[str, object] = {}
    import sentry_sdk

    monkeypatch.setattr(sentry_sdk, "init", lambda **kw: calls.update(kw))
    monkeypatch.setattr(sentry_sdk, "set_tag", lambda k, v: calls.update({k: v}))
    env = {"SENTRY_DSN": "https://k@sentry.example/1", "YANTRA_ENV": "staging", "YANTRA_RELEASE": "sha256:x"}
    assert install_sentry("work", env=env) is True
    assert calls["send_default_pii"] is False and calls["environment"] == "staging" and calls["process"] == "work"
    assert calls["before_send"] is scrub and calls["release"] == "sha256:x"


def test_boot_configures_logging_then_sentry(monkeypatch):
    seen: list[str] = []
    monkeypatch.setattr(boot_module, "configure_logging", lambda level: seen.append("logging"))
    monkeypatch.setattr(boot_module, "install_sentry", lambda process: seen.append(process) or False)
    boot_module.boot("money")
    assert seen == ["logging", "money"]
