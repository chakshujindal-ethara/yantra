from yantra_common.http import loggable


def test_loggable_keeps_ids_and_counts_and_drops_client_data():
    ctx = {"batch_id": "b1", "status": "draft", "errors": [1, 2, 3], "message": "client text", "note": "x"}
    assert loggable(ctx) == "batch_id=b1 status=draft errors_count=3"


def test_emit_refuses_a_model_without_a_type():
    import pytest
    from pydantic import BaseModel

    from yantra_common.outbox import emit

    class NotAnEvent(BaseModel):
        x: int = 1

    with pytest.raises(TypeError):
        emit(None, None, "s", NotAnEvent())


def test_migrated_engine_refuses_an_unsafe_database_name():
    from pathlib import Path

    import pytest

    from yantra_common.testing import migrated_engine

    with pytest.raises(ValueError):
        next(migrated_engine(Path("x"), "bad name; drop"))


def test_a_chunked_body_without_a_length_is_refused_before_it_is_read():
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from yantra_common.http import install_boundary

    app = FastAPI()
    install_boundary(app, 100)

    @app.post("/v1/x")  # type: ignore[misc]
    async def x() -> dict[str, int]:
        return {"ok": 1}

    client = TestClient(app)

    def chunks():
        yield b"x" * 50
        yield b"x" * 50

    r = client.post("/v1/x", content=chunks())
    assert r.status_code == 411 and r.json()["code"] == "length_required"
    assert client.post("/v1/x", content=b"x" * 50).status_code == 200


def test_security_headers_on_every_answer_a_route_may_override_and_docs_keep_theirs():
    from fastapi import FastAPI
    from fastapi.responses import PlainTextResponse
    from fastapi.testclient import TestClient

    from yantra_common.http import install_boundary, install_security_headers

    app = FastAPI()
    install_boundary(app, 100)
    install_security_headers(app, hsts=True)

    @app.get("/x")  # type: ignore[misc]
    def x() -> dict[str, int]:
        return {"x": 1}

    @app.get("/csv")  # type: ignore[misc]
    def csv() -> PlainTextResponse:
        return PlainTextResponse("a,b", headers={"Cache-Control": "private, max-age=60"})

    client = TestClient(app)
    r = client.get("/x")
    assert r.headers["X-Content-Type-Options"] == "nosniff" and r.headers["X-Frame-Options"] == "DENY"
    assert r.headers["Content-Security-Policy"].startswith("default-src 'none'")
    assert r.headers["Strict-Transport-Security"].startswith("max-age=")
    assert client.get("/csv").headers["Cache-Control"] == "private, max-age=60"
    assert client.post("/x", content=b"x" * 200).headers["X-Frame-Options"] == "DENY"  # a 413 from the boundary
    assert "Content-Security-Policy" not in client.get("/docs").headers
