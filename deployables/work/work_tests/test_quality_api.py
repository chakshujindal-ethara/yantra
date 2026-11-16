"""The quality routes through the work deployable."""

import uuid

from fastapi.testclient import TestClient

from yantra_quality.service import sampled_for_audit
from yantra_quality.testing import open_task
from yantra_work.app import create_app

OPS = {"X-Role": "ops"}


def unsampled() -> uuid.UUID:
    while True:
        u = uuid.uuid4()
        if not sampled_for_audit(u):
            return u


def test_review_claim_record_flag_and_release_over_http(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000))
    author, reviewer = uuid.uuid4(), uuid.uuid4()
    with factory() as s:
        open_task(s, author, uuid.uuid4(), unsampled())
    h = {"X-Role": "worker,reviewer", "X-Worker-Id": str(reviewer)}
    assert (
        client.post(
            "/v1/quality/reviews/claim", headers={"X-Role": "worker,reviewer", "X-Worker-Id": str(author)}
        ).status_code
        == 404
    )
    assert client.get("/v1/quality/reviews/active", headers=h).status_code == 404
    task = client.post("/v1/quality/reviews/claim", headers=h)
    assert task.status_code == 201 and task.json()["status"] == "claimed"
    held = client.get("/v1/quality/reviews/active", headers=h)
    assert (
        held.status_code == 200
        and held.json()["id"] == task.json()["id"]
        and held.json()["answer"] == {"transcript": "namaste"}
    )
    assert (
        client.get(
            "/v1/quality/reviews/active", headers={"X-Role": "worker,reviewer", "X-Worker-Id": str(author)}
        ).status_code
        == 404
    )
    detail = client.get(f"/v1/quality/tasks/{task.json()['id']}", headers=h)
    assert detail.status_code == 200 and detail.json()["payload"] == {"text": "namaste", "language": "hi"}
    assert detail.json()["answer"] == {"transcript": "namaste"}
    assert "worker_id" not in detail.json() and "sampled_for_audit" not in detail.json()
    assert (
        client.get(
            f"/v1/quality/tasks/{task.json()['id']}", headers={"X-Role": "worker,reviewer", "X-Worker-Id": str(author)}
        ).status_code
        == 404
    )
    assert client.get(f"/v1/quality/tasks/{uuid.uuid4()}", headers=h).status_code == 404
    r = client.post(f"/v1/quality/tasks/{task.json()['id']}/review", json={"verdict": "reject"}, headers=h)
    assert r.status_code == 422 and r.json()["code"] == "invalid" and "codes" in r.json()
    r = client.post(
        f"/v1/quality/tasks/{task.json()['id']}/review",
        json={"verdict": "accept", "rubric_unclear": True, "note": "ambiguous glossary"},
        headers=h,
    )
    assert r.status_code == 200 and r.json()["canonical_verdict"] == "accept"
    assert client.get("/v1/quality/reviews/active", headers=h).status_code == 404  # recorded: nothing held
    assert client.get("/v1/quality/flags").status_code == 403
    flags = client.get("/v1/quality/flags", headers=OPS).json()
    assert len(flags) == 1 and flags[0]["note"] == "ambiguous glossary"
    answered = client.post(f"/v1/quality/flags/{flags[0]['id']}/answer", json={"answer": "use v2"}, headers=OPS)
    assert answered.status_code == 200 and answered.json()["answered_at"]
    assert client.get("/v1/quality/flags", headers=OPS).json() == []
    assert client.post("/v1/quality/reviews/release-expired", headers=OPS).json() == {"released": 0}
    assert client.post("/v1/quality/reviews/claim", headers=h, params={"kind": "nope"}).status_code == 422


def test_my_work_and_the_dispute_flow_over_http(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000))
    author, reviewer = uuid.uuid4(), uuid.uuid4()
    with factory() as s:
        unit = open_task(s, author, uuid.uuid4(), unsampled())
    me, rev = (
        {"X-Role": "worker", "X-Worker-Id": str(author)},
        {"X-Role": "worker,reviewer", "X-Worker-Id": str(reviewer)},
    )
    work = client.get("/v1/quality/my-work", headers=me).json()
    assert len(work) == 1 and work[0]["unit_id"] == str(unit) and work[0]["stage"] == "in_review"
    assert work[0]["decided_at"] is None and work[0]["dispute"] is None and work[0]["billable"] is False
    assert not {k for k in work[0] if "reviewer_id" in k or "auditor_id" in k}  # the author never learns who
    task = client.post("/v1/quality/reviews/claim", headers=rev).json()
    verdict = {
        "verdict": "needs_edits",
        "reason_code": "client_glossary_change",
        "note": "term x",
        "feedback": {"q": 2},
    }
    assert client.post(f"/v1/quality/tasks/{task['id']}/review", json=verdict, headers=rev).status_code == 200
    row = client.get("/v1/quality/my-work", headers=me).json()[0]
    assert (row["stage"], row["canonical_verdict"], row["reason_code"], row["billable"]) == (
        "decided",
        "needs_edits",
        "client_glossary_change",
        True,
    )
    assert (
        row["reviewer_note"] == "term x"
        and row["feedback"] == {"q": 2}
        and row["decided_at"]
        and row["task_id"] == task["id"]
    )
    assert client.get("/v1/quality/my-work", headers=rev).json() == []
    path = f"/v1/quality/tasks/{task['id']}/dispute"
    assert client.post(path, json={"reason": "short"}, headers=me).status_code == 422
    assert client.post(path, json={"reason": "the glossary changed after I submitted"}, headers=rev).status_code == 404
    opened = client.post(path, json={"reason": "the glossary changed after I submitted"}, headers=me)
    assert opened.status_code == 201 and opened.json()["status"] == "open" and opened.json()["created_at"]
    again = client.post(path, json={"reason": "the glossary changed after I submitted"}, headers=me)
    assert again.status_code == 409 and again.json()["code"] == "dispute_exists"
    assert again.json()["dispute_id"] == opened.json()["id"]
    assert client.get("/v1/quality/my-work", headers=me).json()[0]["dispute"]["id"] == opened.json()["id"]
    assert client.get("/v1/quality/disputes", headers=me).status_code == 403
    queue = client.get("/v1/quality/disputes", headers=OPS).json()
    assert len(queue) == 1 and queue[0]["id"] == opened.json()["id"] and queue[0]["unit_id"] == str(unit)
    assert (queue[0]["verdict"], queue[0]["reason_code"], queue[0]["worker_id"]) == (
        "needs_edits",
        "client_glossary_change",
        str(author),
    )
    assert queue[0]["reason"] == "the glossary changed after I submitted" and queue[0]["task_id"] == task["id"]
    resolve = f"/v1/quality/disputes/{opened.json()['id']}/resolve"
    ops = {**OPS, "X-Worker-Id": str(uuid.uuid4())}
    assert client.post(resolve, json={"outcome": "maybe", "answer": "x"}, headers=ops).status_code == 422
    assert client.post(resolve, json={"outcome": "upheld", "answer": "x"}, headers=OPS).status_code == 422  # unsigned
    done = client.post(resolve, json={"outcome": "upheld", "answer": "the client did change it"}, headers=ops)
    assert done.status_code == 200 and done.json()["status"] == "upheld" and done.json()["resolved_at"]
    assert done.json()["resolved_by"] == ops["X-Worker-Id"]
    twice = client.post(resolve, json={"outcome": "dismissed", "answer": "no"}, headers=ops)
    assert twice.status_code == 409 and twice.json()["code"] == "dispute_resolved"
    assert client.get("/v1/quality/disputes", headers=OPS).json() == []
    dispute = client.get("/v1/quality/my-work", headers=me).json()[0]["dispute"]
    assert dispute["answer"] == "the client did change it" and "resolved_by" not in dispute


def test_a_note_written_with_a_rubric_flag_is_for_the_tpm_and_never_reaches_the_author(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000))
    author, reviewer = uuid.uuid4(), uuid.uuid4()
    with factory() as s:
        open_task(s, author, uuid.uuid4(), unsampled())
    me, rev = (
        {"X-Role": "worker", "X-Worker-Id": str(author)},
        {"X-Role": "worker,reviewer", "X-Worker-Id": str(reviewer)},
    )
    task = client.post("/v1/quality/reviews/claim", headers=rev).json()
    verdict = {
        "verdict": "accept",
        "rubric_unclear": True,
        "note": "glossary contradicts sample 3",
        "feedback": {"q": 4},
    }
    assert client.post(f"/v1/quality/tasks/{task['id']}/review", json=verdict, headers=rev).status_code == 200
    [row] = client.get("/v1/quality/my-work", headers=me).json()
    assert (row["stage"], row["canonical_verdict"], row["reviewer_note"], row["feedback"]) == (
        "decided",
        "accept",
        None,
        {"q": 4},
    )


def test_a_client_only_caller_is_refused_the_review_and_author_surfaces(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000))
    client_only = {"X-Role": "client", "X-Worker-Id": str(uuid.uuid4())}
    plain_worker = {"X-Role": "worker", "X-Worker-Id": str(uuid.uuid4())}
    for method, path in (
        ("POST", "/v1/quality/reviews/claim"),
        ("GET", "/v1/quality/reviews/active"),
        ("GET", f"/v1/quality/tasks/{uuid.uuid4()}"),
        ("POST", f"/v1/quality/tasks/{uuid.uuid4()}/review"),
    ):
        for caller in (client_only, plain_worker):  # reviewing takes the reviewer role, being a worker is not enough
            r = client.request(method, path, headers=caller, json={})
            assert (r.status_code, r.json()["message"]) == (403, "reviewer role required"), (method, path, r.text)
    for method, path in (("GET", "/v1/quality/my-work"), ("POST", f"/v1/quality/tasks/{uuid.uuid4()}/dispute")):
        r = client.request(method, path, headers=client_only, json={})
        assert (r.status_code, r.json()["message"]) == (403, "worker role required"), (method, path, r.text)
