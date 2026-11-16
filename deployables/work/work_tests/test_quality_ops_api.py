"""The ops side of quality through the work deployable: stats per batch and the review queue list."""

import uuid

import pytest
from fastapi.testclient import TestClient

from yantra_quality.service import claim_review, record_review, sampled_for_audit
from yantra_quality.testing import open_task
from yantra_work.app import create_app

OPS = {"X-Role": "ops"}


def unsampled() -> uuid.UUID:
    while True:
        u = uuid.uuid4()
        if not sampled_for_audit(u):
            return u


@pytest.fixture
def client(factory):
    return TestClient(create_app(factory, rate_limit_per_minute=1000), raise_server_exceptions=False)


def test_stats_are_ops_only_and_filter_by_one_batch_or_a_comma_list(client, factory):
    a, b = uuid.uuid4(), uuid.uuid4()
    with factory() as s:
        reviewer = uuid.uuid4()
        open_task(s, uuid.uuid4(), b, unsampled())
        task = claim_review(s, reviewer)
        s.commit()
        record_review(s, task.id, reviewer, "reject", "low_quality")
        s.commit()
        open_task(s, uuid.uuid4(), a, unsampled())
    assert client.get("/v1/quality/stats").status_code == 403
    assert client.get("/v1/quality/stats", headers={"X-Role": "client,worker"}).status_code == 403
    everything = client.get("/v1/quality/stats", headers={"X-Role": "ops,worker"}).json()
    assert (everything["pending"], everything["canonical"], everything["rejected"]) == (1, 1, 1)
    assert everything["acceptance_rate"] == "0.0000" and everything["oldest_pending_at"]
    only_a = client.get("/v1/quality/stats", params={"batch_id": str(a)}, headers=OPS).json()
    assert only_a["pending"] == 1 and only_a["canonical"] == 0 and only_a["acceptance_rate"] is None
    both = client.get("/v1/quality/stats", params={"batch_ids": f"{a},{b}"}, headers=OPS).json()
    assert both == everything
    assert both["reasons"] == [{"reason_code": "low_quality", "count": 1, "billable": False}]
    bad = client.get("/v1/quality/stats", params={"batch_ids": "nope"}, headers=OPS)
    assert bad.status_code == 422 and bad.json()["code"] == "invalid"
    assert client.get("/v1/quality/stats", params={"batch_id": "nope"}, headers=OPS).status_code == 422


def test_the_queue_list_pages_oldest_first_with_a_capped_limit(client, factory):
    a = uuid.uuid4()
    with factory() as s:
        units = [open_task(s, uuid.uuid4(), a, unsampled()) for _ in range(3)]
    assert client.get("/v1/quality/tasks").status_code == 403
    page = client.get("/v1/quality/tasks", params={"batch_id": str(a), "limit": 2}, headers=OPS).json()
    assert page["total"] == 3 and [t["unit_id"] for t in page["items"]] == [str(u) for u in units[:2]]
    row = page["items"][0]
    assert row["status"] == "pending" and row["reviewer_id"] is None and row["canonical_at"] is None
    assert row["sampled_for_audit"] is False  # ops see the sample; reviewers never do
    assert set(row) == {
        "id",
        "unit_id",
        "batch_id",
        "worker_id",
        "sampled_for_audit",
        "status",
        "reviewer_id",
        "canonical_verdict",
        "created_at",
        "canonical_at",
    }
    rest = client.get("/v1/quality/tasks", params={"limit": 2, "offset": 2}, headers=OPS).json()
    assert rest["total"] == 3 and [t["unit_id"] for t in rest["items"]] == [str(units[2])]
    assert client.get("/v1/quality/tasks", params={"status": "canonical"}, headers=OPS).json() == {
        "total": 0,
        "items": [],
    }
    assert client.get("/v1/quality/tasks", params={"status": "nope"}, headers=OPS).status_code == 422
    assert client.get("/v1/quality/tasks", params={"limit": 201}, headers=OPS).status_code == 422
    assert client.get("/v1/quality/tasks", params={"limit": 0}, headers=OPS).status_code == 422
    assert client.get("/v1/quality/tasks", params={"offset": -1}, headers=OPS).status_code == 422
