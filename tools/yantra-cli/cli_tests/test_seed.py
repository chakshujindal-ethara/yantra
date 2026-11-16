"""The seed against a scripted rig: every call lands on the right route as the right person, and a second
run (applications already there) completes without error."""

import json
import uuid
from typing import Any

import httpx
import pytest

from yantra_cli.__main__ import main
from yantra_cli.client import GatewayError
from yantra_cli.config import Config
from yantra_cli.seed import BENGALI, CALL_TOPICS, CLIENT1, CONSULT, HINDI, SUBMISSIONS, TAMIL, VERDICTS, Seed

from .conftest import OPS, fake_jwt

SUBS = {
    "ops1": OPS,
    "worker1": "00000000-0000-4000-8000-000000000001",
    "worker2": "00000000-0000-4000-8000-000000000002",
    "worker3": "00000000-0000-4000-8000-000000000003",
    "worker4": "00000000-0000-4000-8000-000000000004",
    "worker5": "00000000-0000-4000-8000-000000000005",
}


class Rig:
    def __init__(self, applied_already: bool = False, no_storage: bool = False, put_status: int = 200) -> None:
        self.applied_already = applied_already
        self.no_storage = no_storage
        self.put_status = put_status
        self.requests: list[httpx.Request] = []

    def handle(self, r: httpx.Request) -> httpx.Response:
        self.requests.append(r)
        path, m = r.url.path, r.method
        if path.endswith("/openid-connect/token"):
            form = dict(x.split("=", 1) for x in r.content.decode().split("&"))
            roles = ["ops"] if form["username"].startswith("ops") else ["worker"]
            return httpx.Response(
                200,
                json={
                    "access_token": fake_jwt(SUBS[form["username"]], roles),
                    "refresh_token": "r" * 20,
                    "expires_in": 300,
                },
            )
        if r.url.host == "minio.test":
            return httpx.Response(self.put_status)
        if m == "POST" and path.endswith("/payload-uploads"):
            if self.no_storage:
                return httpx.Response(503, json={"code": "storage_unconfigured", "message": "no", "request_id": "r"})
            files = json.loads(r.content)["files"]
            ups = [
                {"url": f"http://minio.test/{f['name']}", "headers": {"content-type": "audio/wav"}, "ref": f["name"]}
                for f in files
            ]
            return httpx.Response(200, json={"uploads": ups})
        if m == "POST" and path.endswith("/applications") and self.applied_already:
            return httpx.Response(409, json={"code": "already_applied", "message": "once", "request_id": "r"})
        if m == "POST" and path == "/v1/tracker/sessions" and self.applied_already:
            sid = str(uuid.uuid4())
            return httpx.Response(
                409, json={"code": "session_open", "message": "open", "request_id": "r", "session_id": sid}
            )
        body: dict[str, Any] = {"id": str(uuid.uuid4()), "status": "published"}
        if r.content:
            body.update(json.loads(r.content))
        return httpx.Response(201 if m == "POST" else 200, json=body)


def test_seed_walks_every_surface_as_the_right_person(env, capsys):
    rig = Rig()
    assert main(["seed"], http=httpx.Client(transport=httpx.MockTransport(rig.handle)), env=env) == 0
    out = capsys.readouterr().out
    assert "SEEDED" in out
    calls = [(r.method, r.url.path) for r in rig.requests if "openid" not in r.url.path]
    paths = [p for _, p in calls]
    assert ("POST", "/v1/client-orgs") in calls
    assert any(p.endswith(f"/members/{CLIENT1}") for p in paths)
    assert calls.count(("POST", "/v1/projects")) == 4 and paths.count("/v1/talent/listings") == 2
    assert calls[0] == ("GET", "/v1/projects")  # the already-seeded check comes first
    names = [json.loads(r.content)["name"] for r in rig.requests if r.url.path == "/v1/projects" and r.method == "POST"]
    assert names == [HINDI, TAMIL, CONSULT, BENGALI]  # plain names a client would recognise, no random suffix
    assert ("POST", "/v1/assess/papers") in calls
    paper = json.loads(next(r for r in rig.requests if r.url.path == "/v1/assess/papers").content)
    assert paper["release_policy"] == "auto_objective" and paper["source"]["kind"] == "quick"
    assert {q["kind"] for q in paper["source"]["questions"]} == {"single", "multi"}  # what the engine takes
    assert (
        sum(1 for m, p in calls if m == "PATCH" and p.startswith("/v1/projects/")) == 3
    )  # the Bengali project is created, nothing more yet
    assert any(p.endswith("/publish") for p in paths)
    assert any(p.endswith("/decide") for p in paths)  # worker5's offer
    assert ("POST", "/v1/notify/tickets") in calls
    assert ("PUT", "/v1/analytics/baselines") in calls
    starts = [r for r in rig.requests if r.url.path == "/v1/tracker/sessions"]
    assert len(starts) == 2 and len({json.loads(r.content)["device_hash"] for r in starts}) == 1
    assert sum(1 for p in paths if p.endswith("/samples")) == 2 and sum(1 for p in paths if p.endswith("/end")) == 2
    workers = [r for r in rig.requests if r.url.path.endswith("/applications") and r.method == "POST"]
    assert len(workers) == 2
    # work under way: four submissions, three verdicts, one claim left in progress
    assert sum(1 for p in paths if p.endswith("/submission")) == len(SUBMISSIONS)
    reviews = [json.loads(r.content) for r in rig.requests if r.url.path.endswith("/review")]
    assert reviews == VERDICTS
    assert sum(1 for m, p in calls if m == "POST" and p.endswith("/claims")) == len(SUBMISSIONS) + 1
    accounts = [r for r in rig.requests if r.url.path == "/v1/payout/accounts/me" and r.method == "PUT"]
    assert len(accounts) == 5 and all("account_number" in json.loads(r.content) for r in accounts)


def test_seed_runs_again_when_the_applications_already_exist(env):
    rig = Rig(applied_already=True)
    client = httpx.Client(transport=httpx.MockTransport(rig.handle))
    report = Seed(Config.from_env(env), "yantra", client, say=lambda s: None).run()
    assert report["result"] == "SEEDED"
    assert not any(r.url.path.endswith("/decide") for r in rig.requests)
    # the open session the 409 names is the one the samples go to
    assert sum(1 for r in rig.requests if r.url.path.endswith("/samples")) == 2


def test_an_unexpected_tracker_error_stops_the_seed(env):
    def handle(r: httpx.Request) -> httpx.Response:
        if r.url.path.endswith("/openid-connect/token"):
            return httpx.Response(
                200, json={"access_token": fake_jwt(OPS, ["ops"]), "refresh_token": "r" * 20, "expires_in": 300}
            )
        if r.url.path.endswith("/payload-uploads"):
            return httpx.Response(503, json={"code": "storage_unconfigured", "message": "no", "request_id": "r"})
        if r.url.path == "/v1/tracker/sessions":
            return httpx.Response(409, json={"code": "claim_not_live", "message": "no", "request_id": "r"})
        return httpx.Response(201, json={"id": str(uuid.uuid4())})

    client = httpx.Client(transport=httpx.MockTransport(handle))
    with pytest.raises(GatewayError):
        Seed(Config.from_env(env), "yantra", client, say=lambda s: None).run()


def test_an_unexpected_apply_error_stops_the_seed(env):
    def handle(r: httpx.Request) -> httpx.Response:
        if r.url.path.endswith("/openid-connect/token"):
            return httpx.Response(
                200, json={"access_token": fake_jwt(OPS, ["ops"]), "refresh_token": "r" * 20, "expires_in": 300}
            )
        if r.url.path.endswith("/payload-uploads"):
            return httpx.Response(503, json={"code": "storage_unconfigured", "message": "no", "request_id": "r"})
        if r.url.path.endswith("/applications"):
            return httpx.Response(503, json={"code": "unavailable", "message": "down", "request_id": "r"})
        return httpx.Response(201, json={"id": str(uuid.uuid4())})

    client = httpx.Client(transport=httpx.MockTransport(handle))
    with pytest.raises(GatewayError):
        Seed(Config.from_env(env), "yantra", client, say=lambda s: None).run()


def test_seed_uploads_a_real_clip_per_unit_and_imports_its_ref(env):
    rig = Rig()
    assert main(["seed"], http=httpx.Client(transport=httpx.MockTransport(rig.handle)), env=env) == 0
    puts = [r for r in rig.requests if r.url.host == "minio.test"]
    assert len(puts) == len(CALL_TOPICS) + 6 and puts[0].content[:4] == b"RIFF"  # support calls + six episodes
    imported = next(r for r in rig.requests if r.url.path.endswith("/units/import"))
    lines = json.loads(imported.content)["lines"]
    refs = [line["payload"]["audio_ref"] for line in lines]
    assert refs == [r.url.path.lstrip("/") for r in puts[: len(CALL_TOPICS)]]
    assert [line["payload"]["topic"] for line in lines] == CALL_TOPICS


def test_seed_keeps_plain_clip_names_without_object_storage(env, capsys):
    rig = Rig(no_storage=True)
    assert main(["seed"], http=httpx.Client(transport=httpx.MockTransport(rig.handle)), env=env) == 0
    assert "no object storage" in capsys.readouterr().out
    assert not [r for r in rig.requests if r.url.host == "minio.test"]


def test_seed_stops_when_object_storage_refuses_a_clip(env):
    rig = Rig(put_status=403)
    assert main(["seed"], http=httpx.Client(transport=httpx.MockTransport(rig.handle)), env=env) == 1


def test_seed_lets_other_upload_errors_through(env):
    class Down(Rig):
        def handle(self, r: httpx.Request) -> httpx.Response:
            if r.url.path.endswith("/payload-uploads"):
                return httpx.Response(409, json={"code": "batch_not_draft", "message": "no", "request_id": "r"})
            return super().handle(r)

    assert main(["seed"], http=httpx.Client(transport=httpx.MockTransport(Down().handle)), env=env) == 1


def test_a_second_seed_finds_the_world_in_place_and_stops(env, capsys):
    class Seeded(Rig):
        def handle(self, r: httpx.Request) -> httpx.Response:
            if r.method == "GET" and r.url.path == "/v1/projects":
                self.requests.append(r)
                return httpx.Response(200, json=[{"id": "p1", "name": HINDI}])
            return super().handle(r)

    rig = Seeded()
    assert main(["seed"], http=httpx.Client(transport=httpx.MockTransport(rig.handle)), env=env) == 0
    assert "already seeded" in capsys.readouterr().out
    assert not [r for r in rig.requests if r.method == "POST" and "openid" not in r.url.path]


def test_the_reviewer_waits_for_the_submission_to_reach_quality(env):
    class Slow(Rig):
        misses = 2

        def handle(self, r: httpx.Request) -> httpx.Response:
            if r.url.path == "/v1/quality/reviews/claim" and self.misses:
                self.misses -= 1
                self.requests.append(r)
                return httpx.Response(404, json={"code": "nothing_to_review", "message": "none", "request_id": "r"})
            return super().handle(r)

    slept: list[float] = []
    rig = Slow()
    client = httpx.Client(transport=httpx.MockTransport(rig.handle))
    Seed(Config.from_env(env), "yantra", client, sleep=slept.append, say=lambda s: None).run()
    assert slept == [1.0, 1.0]
    assert sum(1 for r in rig.requests if r.url.path.endswith("/review")) == len(VERDICTS)


def test_review_waiting_gives_up_and_other_errors_stop_at_once(env):
    def refusing(status: int) -> httpx.MockTransport:
        rig = Rig()

        def handle(r: httpx.Request) -> httpx.Response:
            if r.url.path == "/v1/quality/reviews/claim":
                return httpx.Response(status, json={"code": "x", "message": "no", "request_id": "r"})
            return rig.handle(r)

        return httpx.MockTransport(handle)

    for status, expected_sleeps in ((404, 2), (403, 0)):
        slept: list[float] = []
        seed = Seed(
            Config.from_env(env), "yantra", httpx.Client(transport=refusing(status)), sleep=slept.append, say=print
        )
        with pytest.raises(GatewayError):
            seed._review_task(seed.as_user("worker2"), "b1", tries=3)
        assert len(slept) == expected_sleeps
