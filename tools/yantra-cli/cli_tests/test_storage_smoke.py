"""The storage leg of the smoke against a scripted gateway and store."""

from typing import Any

import httpx
import pytest

from yantra_cli.__main__ import main
from yantra_cli.client import GatewayError
from yantra_cli.smoke import SmokeFailed
from yantra_cli.storage_smoke import BODY, StorageSmoke

KEY = "projects/p/units/u/clip.wav"


class FakeGateway:
    """Answers the routes the storage smoke calls; `fail` names a route to raise on."""

    def __init__(self, fail: dict[str, GatewayError] | None = None, link_after_release: bool = False) -> None:
        self.fail = fail or {}
        self.released = False
        self.link_after_release = link_after_release
        self.calls: list[str] = []

    def _route(self, method: str, path: str) -> str:
        self.calls.append(f"{method} {path}")
        for key, err in self.fail.items():
            if key in f"{method} {path}":
                raise err
        return path

    def post(self, path: str, json: Any = None, **params: Any) -> Any:
        self._route("POST", path)
        if path == "/v1/projects":
            return {"id": "p1"}
        if path.endswith("/batches"):
            return {"id": "b1"}
        if path.endswith("/payload-uploads"):
            return {
                "uploads": [
                    {
                        "key": KEY,
                        "ref": f"s3://yantra/{KEY}",
                        "url": "http://store/put",
                        "headers": {"content-type": "audio/wav"},
                    }
                ]
            }
        if path.endswith("/claims"):
            return {"id": "c1", "unit_id": "u1"}
        if path.endswith("/release"):
            self.released = True
            return {"status": "released"}
        return {}

    def get(self, path: str, **params: Any) -> Any:
        self._route("GET", path)
        if path.endswith("/payload-url"):
            if self.released and not self.link_after_release:
                raise GatewayError(404, "not_found", "gone", "r")
            return {"url": "http://store/get"}
        if path == "/v1/claims/expired":
            return []
        return {"dead_letters": {}}


def store(body: bytes = BODY, put_status: int = 200) -> httpx.Client:
    def handle(r: httpx.Request) -> httpx.Response:
        if r.method == "PUT":
            return httpx.Response(put_status)
        return httpx.Response(200, content=body)

    return httpx.Client(transport=httpx.MockTransport(handle))


def test_the_storage_leg_passes():
    ops, worker = FakeGateway(), FakeGateway()
    out = StorageSmoke(ops, worker, store()).run()
    assert out == {"storage": "ok", "object": KEY, "bytes": len(BODY)}
    assert "POST /v1/claims/c1/release" in worker.calls


def test_no_storage_is_skipped():
    ops = FakeGateway(fail={"payload-uploads": GatewayError(503, "storage_unconfigured", "no", "r")})
    assert StorageSmoke(ops, FakeGateway(), store()).run() == {"storage": "skipped: the rig has no object storage"}


def test_another_upload_error_is_raised():
    ops = FakeGateway(fail={"payload-uploads": GatewayError(500, "internal_error", "x", "r")})
    with pytest.raises(GatewayError):
        StorageSmoke(ops, FakeGateway(), store()).run()


@pytest.mark.parametrize(
    "client,worker,what",
    [
        (store(put_status=403), FakeGateway(), "presigned upload was refused"),
        (store(body=b"other"), FakeGateway(), "did not return the uploaded bytes"),
        (store(), FakeGateway(link_after_release=True), "kept its payload link"),
        (store(), FakeGateway(fail={"GET /v1/units/u1/payload-url": GatewayError(500, "x", "x", "r")}), None),
    ],
)
def test_each_check_fails_loudly(client, worker, what):
    if what is None:
        with pytest.raises(GatewayError):
            StorageSmoke(FakeGateway(), worker, client).run()
        return
    with pytest.raises(SmokeFailed, match=what):
        StorageSmoke(FakeGateway(), worker, client).run()


def test_a_released_link_must_be_404():
    class Odd(FakeGateway):
        def get(self, path: str, **params: Any) -> Any:
            if self.released and path.endswith("/payload-url"):
                raise GatewayError(403, "forbidden", "x", "r")
            return super().get(path, **params)

    with pytest.raises(SmokeFailed, match="kept its link"):
        StorageSmoke(FakeGateway(), Odd(), store()).run()


def test_the_command_line_runs_the_storage_leg_after_the_smoke(env, capsys, monkeypatch):
    import yantra_cli.__main__ as cli

    class StubSmoke:
        def __init__(self, *a: Any, **k: Any) -> None:
            pass

        def run(self) -> dict[str, Any]:
            return {"result": "PASS"}

        def as_user(self, name: str) -> str:
            return name

    seen: list[tuple[str, str]] = []

    class StubStorage:
        def __init__(self, ops: str, worker: str, http: Any) -> None:
            seen.append((ops, worker))

        def run(self) -> dict[str, Any]:
            return {"storage": "ok"}

    monkeypatch.setattr(cli, "Smoke", StubSmoke)
    monkeypatch.setattr(cli, "StorageSmoke", StubStorage)
    code = main(["--json", "smoke", "--with-storage"], http=httpx.Client(), env=env)
    out, _ = capsys.readouterr()
    assert code == 0 and '"storage": {' in out and seen == [("ops1", "worker1")]
