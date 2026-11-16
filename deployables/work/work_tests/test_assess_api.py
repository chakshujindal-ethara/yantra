"""The assess routes through the work deployable, on the fake engine: ops link, write and publish papers; a worker
launches one into the Assessment app; the sync turns the engine's result into a certification, which the talent and
market consumers turn into a screening application and a claimable gate."""

import uuid
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from yantra_assess.engine.fake import FakeEngine
from yantra_assess.models import OUTBOX, Sitting
from yantra_assess.testing import SETTINGS
from yantra_common.events import Envelope
from yantra_work.app import create_app

OPS_ID = str(uuid.uuid4())
OPS = {"X-Role": "ops", "X-Worker-Id": OPS_ID}
QUICK = {
    "gate": "transcription",
    "title": "Hindi transcription",
    "description": "two questions",
    "max_attempts": 2,
    "release_policy": "auto_objective",
    "source": {
        "kind": "quick",
        "duration_minutes": 30,
        "pass_mark": "0.6",
        "questions": [
            {"id": "q1", "prompt": "2 + 2?", "kind": "single", "options": ["3", "4"], "answer": "4"},
            {"id": "q2", "prompt": "Even?", "kind": "multi", "options": ["1", "2", "4"], "answer": ["2", "4"]},
        ],
    },
}


def worker(email: str = "w@yantra.local") -> dict[str, str]:
    return {"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4()), "X-Email": email, "X-Email-Verified": "true"}


@pytest.fixture
def fake() -> FakeEngine:
    return FakeEngine(app_url="http://exam.test")


@pytest.fixture
def client(factory, fake):
    app = create_app(factory, rate_limit_per_minute=1000, assess_engine=fake, assess_config=SETTINGS)
    return TestClient(app, raise_server_exceptions=False)


def published(client: TestClient, body: dict = QUICK) -> dict:
    paper = client.post("/v1/assess/papers", json=body, headers=OPS)
    assert paper.status_code == 201, paper.text
    done = client.post(f"/v1/assess/papers/{paper.json()['id']}/publish", headers=OPS)
    assert done.status_code == 200, done.text
    return done.json()


def test_ops_write_link_publish_and_read_papers(client, fake):
    assert client.post("/v1/assess/papers", json=QUICK, headers=worker()).status_code == 403
    assert client.get("/v1/assess/papers").status_code == 403
    created = client.post("/v1/assess/papers", json=QUICK, headers=OPS)
    assert created.status_code == 201, created.text
    paper = created.json()
    assert (paper["status"], paper["engine"], paper["release_policy"]) == ("draft", "fake", "auto_objective")
    assert paper["snapshot"]["question_types"] == ["mcq", "msq"] and paper["created_by"] == OPS_ID
    assert paper["stats"] == {"total": 0, "passed": 0, "pass_rate": None, "awaiting_result": 0, "held": 0}
    bad = {**QUICK, "source": {**QUICK["source"], "pass_mark": "1.5"}}
    assert client.post("/v1/assess/papers", json=bad, headers=OPS).json()["code"] == "invalid_pass_mark"
    bad = {**QUICK, "source": {"kind": "essay"}}
    assert client.post("/v1/assess/papers", json=bad, headers=OPS).status_code == 422
    aid = fake.add_assessment("Built in the Assessment admin", types=4)
    drafts = client.get("/v1/assess/engine/assessments", headers=OPS).json()
    assert {"id": aid, "name": "Built in the Assessment admin"}.items() <= next(
        d for d in drafts if d["id"] == aid
    ).items()
    everything = client.get("/v1/assess/engine/assessments", params={"state": ""}, headers=OPS)
    assert len(everything.json()) >= len(drafts)
    linked = client.post(
        "/v1/assess/papers", json={**QUICK, "source": {"kind": "assessment", "assessment_id": aid}}, headers=OPS
    )
    assert linked.status_code == 201 and linked.json()["engine_assessment_id"] == aid
    assert client.get(f"/v1/assess/papers/{paper['id']}/brief", headers=worker()).status_code == 404  # a draft
    done = client.post(f"/v1/assess/papers/{paper['id']}/publish", headers=OPS).json()
    assert done["status"] == "published" and done["published_by"] == OPS_ID
    assert client.get(f"/v1/assess/papers/{paper['id']}", headers=OPS).json()["id"] == paper["id"]
    assert len(client.get("/v1/assess/papers", headers=OPS).json()) == 2
    assert client.get(f"/v1/assess/papers/{uuid.uuid4()}", headers=OPS).status_code == 404


def test_a_worker_launches_into_the_assessment_app_and_is_certified(client, fake, factory):
    paper = published(client)
    me = worker()
    brief = client.get(f"/v1/assess/papers/{paper['id']}/brief", headers=me).json()
    assert (brief["attempts_left"], brief["certified"], brief["current"]) == (2, False, None)
    assert brief["question_count"] == 2 and brief["pass_mark"] == "0.6000" and brief["proctoring"]["tab_switch"]
    launched = client.post(f"/v1/assess/papers/{paper['id']}/launch", headers=me)
    assert launched.status_code == 200, launched.text
    body = launched.json()
    assert body["launch_url"].startswith("http://exam.test/yantra/launch#ticket=")
    assert body["sitting"]["status"] == "assigned" and body["sitting"]["attempt_no"] == 1
    with factory() as s:
        attempt = s.scalar(select(Sitting.engine_attempt_id).where(Sitting.id == uuid.UUID(body["sitting"]["id"])))
    fake.begin(attempt)
    fake.submit(attempt, score=90)
    assert client.post("/v1/assess/sync", headers=me).status_code == 403
    assert client.post("/v1/assess/sync", headers=OPS).json() == {"changed": 1}
    mine = client.get("/v1/assess/sittings/me", headers=me).json()
    assert mine[0]["status"] == "passed" and mine[0]["score"] == "0.9000" and mine[0]["gate"] == "transcription"
    assert client.get(f"/v1/assess/papers/{paper['id']}/brief", headers=me).json()["certified"] is True
    again = client.post(f"/v1/assess/papers/{paper['id']}/launch", headers=me)
    assert again.status_code == 409 and again.json()["code"] == "already_certified"
    sittings = client.get(f"/v1/assess/papers/{paper['id']}/sittings", headers=OPS).json()
    assert [s["status"] for s in sittings] == ["passed"]


def test_the_certification_reaches_talent_and_market(client, fake, factory):
    from yantra_market.consumers import on_assess_certified as market_certified
    from yantra_market.models import WorkerProfile
    from yantra_talent.consumers import on_assess_certified as talent_certified
    from yantra_talent.models import Application
    from yantra_talent.service import apply
    from yantra_talent.testing import make_listing

    paper = published(client)
    me = worker()
    wid = uuid.UUID(me["X-Worker-Id"])
    with factory() as s:
        listing = make_listing(s, cert_gate="transcription", paper_id=uuid.UUID(paper["id"]))
        application = apply(s, listing.id, wid, {"experience": "2 years"}, datetime.now(UTC))
        s.commit()
        assert application.status == "assessment"
        app_id = application.id
    body = client.post(f"/v1/assess/papers/{paper['id']}/launch", headers=me).json()
    with factory() as s:
        attempt = s.scalar(select(Sitting.engine_attempt_id).where(Sitting.id == uuid.UUID(body["sitting"]["id"])))
    fake.begin(attempt)
    fake.submit(attempt)
    client.post("/v1/assess/sync", headers=OPS)
    with factory() as s:
        row = s.execute(select(OUTBOX).where(OUTBOX.c.type == "assess.certified.v1")).mappings().one()
        env = Envelope(row["id"], row["type"], row["subject"], row["occurred_at"], row["payload"])
        talent_certified(s, env)
        market_certified(s, env)
        s.commit()
        assert s.get(Application, app_id).status == "screening"
        assert "transcription" in s.get(WorkerProfile, wid).cert_gates


def test_manual_release_rotate_and_the_refusals_over_http(client, fake, factory):
    paper = published(client, {**QUICK, "release_policy": "manual"})
    me = worker()
    body = client.post(f"/v1/assess/papers/{paper['id']}/launch", headers=me).json()
    with factory() as s:
        attempt = s.scalar(select(Sitting.engine_attempt_id).where(Sitting.id == uuid.UUID(body["sitting"]["id"])))
    fake.begin(attempt)
    fake.submit(attempt, result="fail", score=20)
    client.post("/v1/assess/sync", headers=OPS)
    pending = client.post(f"/v1/assess/papers/{paper['id']}/launch", headers=me)
    assert pending.status_code == 409 and pending.json()["code"] == "result_pending"
    current = client.get(f"/v1/assess/papers/{paper['id']}/brief", headers=me).json()["current"]
    assert (current["status"], current["held_reason"]) == ("awaiting_result", "needs_release")
    released = client.post(f"/v1/assess/papers/{paper['id']}/release", json={}, headers=OPS)
    assert released.json() == {"released": 1}
    client.post("/v1/assess/sync", headers=OPS)
    assert client.get(f"/v1/assess/papers/{paper['id']}/brief", headers=me).json()["attempts_left"] == 1
    none_left = client.post(f"/v1/assess/papers/{paper['id']}/release", json={"sitting_ids": []}, headers=OPS)
    assert none_left.status_code == 409 and none_left.json()["code"] == "nothing_to_release"
    rotated = client.post(f"/v1/assess/papers/{paper['id']}/rotate", headers=OPS).json()
    assert rotated["generation"] == 2 and {c["state"] for c in rotated["cohorts"]} == {"closed"}
    fake.drop()
    down = client.post(f"/v1/assess/papers/{paper['id']}/launch", headers=me)
    assert down.status_code == 503 and down.json()["code"] == "engine_unavailable"


def test_continue_with_yantra_and_the_admin_launch(client, fake):
    me = worker()
    ticket = client.post("/v1/assess/launch-by-exam", json={"exam_token": "tok-1"}, headers=me)
    assert ticket.status_code == 200 and ticket.json()["sitting"] is None
    assert client.post("/v1/assess/launch-by-exam", json={"exam_token": ""}, headers=me).status_code == 422
    assert client.post("/v1/assess/admin-launch", json={"next": "/assessments/3"}, headers=me).status_code == 403
    admin = {"X-Role": "admin", "X-Worker-Id": str(uuid.uuid4())}
    staff = client.post("/v1/assess/admin-launch", json={"next": "/assessments/3"}, headers=admin)
    assert staff.status_code == 200 and staff.json()["launch_url"].startswith("http://exam.test")
    assert client.post("/v1/assess/admin-launch", json={"next": "x"}, headers=OPS).json()["code"] == "invalid_next"


def test_the_default_app_builds_the_engine_its_settings_name(factory, monkeypatch):
    monkeypatch.delenv("YANTRA_ASSESS_ENGINE", raising=False)
    app = create_app(factory, rate_limit_per_minute=10)
    assert isinstance(app.state.assess_engine, FakeEngine) and app.state.assess_settings.engine == "fake"
