"""Dead letters and job schedules of every work module, over HTTP: listed for admin and ops, replayed through the
module's own consumer."""

import uuid
from datetime import UTC, datetime

from fastapi.testclient import TestClient
from sqlalchemy import insert

from yantra_common.events import encode
from yantra_common.scheduler import register
from yantra_quality.models import DEAD as QUALITY_DEAD
from yantra_quality.models import ReviewTask
from yantra_quality.testing import submitted_envelope
from yantra_work.app import create_app
from yantra_work.events import jobs

ADMIN = {"X-Role": "admin"}


def test_every_module_lists_its_dead_letters_and_jobs(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000))
    register(factory, jobs(factory))
    for module in ("market", "talent", "assess", "quality", "notify"):
        assert client.get(f"/v1/{module}/dead-letters", headers=ADMIN).json() == []
        names = [j["name"] for j in client.get(f"/v1/{module}/jobs", headers={"X-Role": "ops"}).json()]
        assert f"{module}_prune" in names
    assert client.get("/v1/market/dead-letters", headers={"X-Role": "worker"}).status_code == 403
    assert client.get("/v1/quality/jobs", headers={"X-Role": "finance"}).status_code == 403


def test_a_dead_submission_is_replayed_into_a_review_task(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000))
    env = submitted_envelope(uuid.uuid4(), uuid.uuid4())
    raw = encode(env.id, env.type, env.subject, env.occurred_at, env.data)
    with factory() as s:
        s.execute(
            insert(QUALITY_DEAD).values(
                id=env.id,
                consumer="quality-work-unit-submitted-v1",
                deliveries=20,
                reason="RuntimeError: db away",
                raw=raw,
                dead_at=datetime.now(UTC),
            )
        )
        s.commit()
    [listed] = client.get("/v1/quality/dead-letters", headers=ADMIN).json()
    assert listed["type"] == "work.unit.submitted.v1" and listed["consumer"] == "quality-work-unit-submitted-v1"
    r = client.post(f"/v1/quality/dead-letters/{env.id}/replay", headers=ADMIN)
    assert r.json() == {"replayed": True, "fresh": True}
    with factory() as s:
        assert s.query(ReviewTask).filter_by(unit_id=uuid.UUID(env.data["unit_id"])).count() == 1
    assert client.get("/v1/quality/dead-letters", headers=ADMIN).json() == []
