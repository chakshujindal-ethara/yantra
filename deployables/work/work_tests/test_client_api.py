"""The client console over HTTP: a client reads only the orgs they belong to, a project of another org is 404,
prices and invoice totals are shown and pay never is; an operator sees every org."""

import uuid
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from yantra_market.consumers import on_verdict_accepted, on_verdict_rejected
from yantra_market.models import WorkUnit
from yantra_market.testing import SCHEMA_JSON, good_lines, verdict_event
from yantra_work.app import create_app

OPS = {"X-Role": "ops"}


@pytest.fixture
def client(factory):
    return TestClient(
        create_app(factory, rate_limit_per_minute=1000, max_body_bytes=200_000), raise_server_exceptions=False
    )


def as_client(user: str | None = None) -> dict[str, str]:
    return {"X-Role": "client", "X-Worker-Id": user or str(uuid.uuid4())}


def org_with_member(client: TestClient, name: str, user: str) -> str:
    org = client.post("/v1/client-orgs", json={"name": name}, headers=OPS).json()
    assert client.put(f"/v1/client-orgs/{org['id']}/members/{user}", headers=OPS).status_code == 200
    return org["id"]


def make_project(client: TestClient, org_id: str | None, currency: str = "INR") -> str:
    body = {"name": "p", "currency": currency, "payload_schema": SCHEMA_JSON, "cert_gate": "t"}
    p = client.post("/v1/projects", json=body, headers=OPS)
    assert p.status_code == 201, p.text
    if org_id is not None:
        assert (
            client.patch(f"/v1/projects/{p.json()['id']}", json={"client_org_id": org_id}, headers=OPS).status_code
            == 200
        )
    return p.json()["id"]


def make_batch(client: TestClient, project_id: str, price: str = "60") -> str:
    b = client.post(
        f"/v1/projects/{project_id}/batches", json={"title": "b", "unit_pay": "28", "unit_price": price}, headers=OPS
    )
    assert b.status_code == 201, b.text
    return b.json()["id"]


def import_and_publish(client: TestClient, batch_id: str, n: int) -> None:
    r = client.post(
        f"/v1/batches/{batch_id}/units/import", json={"lines": good_lines(n)}, params={"dry_run": "false"}, headers=OPS
    )
    assert r.status_code == 200, r.text
    assert client.post(f"/v1/batches/{batch_id}/publish", json={}, headers=OPS).status_code == 200


def worked(client: TestClient, batch_id: str) -> tuple[str, str]:
    """One unit claimed and submitted by a fresh eligible worker: (worker_id, unit_id)."""
    worker = str(uuid.uuid4())
    assert (
        client.put(f"/v1/workers/{worker}", json={"status": "eligible", "cert_gates": ["t"]}, headers=OPS).status_code
        == 200
    )
    headers = {"X-Role": "worker", "X-Worker-Id": worker, "Idempotency-Key": f"k-{worker}"}
    c = client.post(f"/v1/batches/{batch_id}/claims", headers=headers)
    assert c.status_code == 201, c.text
    s = client.post(f"/v1/claims/{c.json()['id']}/submission", json={"answer": {"t": 1}}, headers=headers)
    assert s.status_code == 201, s.text
    return worker, c.json()["unit_id"]


def no_pay(doc: object) -> bool:
    """Nothing a client receives may carry a pay rate, however deep."""
    if isinstance(doc, dict):
        return all(k not in ("unit_pay", "review_pay") and no_pay(v) for k, v in doc.items())
    if isinstance(doc, list):
        return all(no_pay(v) for v in doc)
    return True


def test_a_client_sees_their_orgs_projects_with_prices_and_never_pay(client, factory):
    user = str(uuid.uuid4())
    org_id = org_with_member(client, "Acme", user)
    project_id = make_project(client, org_id)
    other_project = make_project(client, org_with_member(client, "Other", str(uuid.uuid4())))
    batch_id = make_batch(client, project_id)
    import_and_publish(client, batch_id, 2)
    w1, u1 = worked(client, batch_id)
    w2, u2 = worked(client, batch_id)
    with factory() as s:
        on_verdict_accepted(s, verdict_event(uuid.UUID(u1), uuid.UUID(batch_id), uuid.UUID(w1)))
        on_verdict_rejected(
            s,
            verdict_event(
                uuid.UUID(u2),
                uuid.UUID(batch_id),
                uuid.UUID(w2),
                "needs_edits",
                "client_glossary_change",
                billable=True,
            ),
        )
        s.commit()
    rows = client.get("/v1/client/projects", headers=as_client(user))
    assert rows.status_code == 200 and [r["id"] for r in rows.json()] == [project_id]
    [row] = rows.json()
    assert row["units"]["accepted"] == 1 and row["units"]["available"] == 1 and row["units"]["total"] == 2
    assert (
        Decimal(row["acceptance_rate"]) == Decimal("0.5") and Decimal(row["invoice_total"]) == 60
    )  # one billable rework
    assert no_pay(row) and row["currency"] == "INR" and row["rubric_version"] == "v1"
    detail = client.get(f"/v1/client/projects/{project_id}", headers=as_client(user))
    assert detail.status_code == 200
    d = detail.json()
    assert no_pay(d) and d["reasons"] == [{"reason_code": "client_glossary_change", "count": 1, "billable": True}]
    [b] = d["batches"]
    assert (
        b["id"] == batch_id and Decimal(b["unit_price"]) == 60 and b["manifest"] is None and b["units"]["accepted"] == 1
    )
    assert d["deliveries"] == [] and d["feedback"] == [] and d["rubric_log"] == []
    assert client.get(f"/v1/client/projects/{other_project}", headers=as_client(user)).status_code == 404
    assert client.get(f"/v1/client/projects/{uuid.uuid4()}", headers=as_client(user)).status_code == 404
    assert client.get("/v1/client/projects", headers=as_client()).json() == []  # a client in no org
    assert client.get("/v1/client/projects").status_code == 403
    assert client.get("/v1/client/projects", headers={"X-Role": "worker", "X-Worker-Id": user}).status_code == 403
    assert client.get("/v1/client/projects", headers={"X-Role": "client"}).status_code == 403  # no subject, no orgs
    every = client.get("/v1/client/projects", headers=OPS).json()
    assert {r["id"] for r in every} >= {project_id, other_project}
    assert client.get(f"/v1/client/projects/{other_project}", headers=OPS).status_code == 200


def test_deliveries_invoice_totals_and_the_manifest_route(client, factory):
    user = str(uuid.uuid4())
    org_id = org_with_member(client, "Acme", user)
    project_id = make_project(client, org_id)
    batch_id = make_batch(client, project_id, price="50")
    import_and_publish(client, batch_id, 2)
    w1, u1 = worked(client, batch_id)
    w2, u2 = worked(client, batch_id)
    headers = as_client(user)
    assert (
        client.get(f"/v1/client/batches/{batch_id}/manifest", headers=headers).status_code == 404
    )  # not delivered yet
    with factory() as s:
        on_verdict_accepted(s, verdict_event(uuid.UUID(u1), uuid.UUID(batch_id), uuid.UUID(w1)))
        on_verdict_accepted(s, verdict_event(uuid.UUID(u2), uuid.UUID(batch_id), uuid.UUID(w2)))
        s.commit()
    assert client.get(f"/v1/batches/{batch_id}/manifest", headers=OPS).status_code == 200
    m = client.get(f"/v1/client/batches/{batch_id}/manifest", headers=headers)
    assert m.status_code == 200 and m.json()["accepted_units"] == 2 and Decimal(m.json()["total_price"]) == 100
    assert len(m.json()["units"]) == 2 and no_pay(m.json())
    assert client.get(f"/v1/client/batches/{batch_id}/manifest", headers=as_client()).status_code == 404
    assert client.get(f"/v1/client/batches/{uuid.uuid4()}/manifest", headers=headers).status_code == 404
    assert client.get(f"/v1/client/batches/{batch_id}/manifest", headers=OPS).status_code == 200
    assert client.get(f"/v1/client/batches/{batch_id}/manifest").status_code == 403
    d = client.get(f"/v1/client/projects/{project_id}", headers=headers).json()
    assert Decimal(d["invoice_total"]) == 100 and Decimal(d["acceptance_rate"]) == 1
    [delivery] = d["deliveries"]
    assert delivery["id"] == m.json()["id"] and delivery["digest"] == m.json()["digest"] and "units" not in delivery
    assert d["batches"][0]["manifest"]["id"] == m.json()["id"] and d["batches"][0]["status"] == "completed"


def test_overview_sums_across_the_callers_orgs_per_currency(client, factory):
    user = str(uuid.uuid4())
    acme = org_with_member(client, "Acme", user)
    beta = org_with_member(client, "Beta", user)
    org_with_member(client, "Not mine", str(uuid.uuid4()))
    p_inr = make_project(client, acme)
    p_usd = make_project(client, beta, currency="USD")
    make_project(client, None)
    b_inr = make_batch(client, p_inr, price="60")
    b_usd = make_batch(client, p_usd, price="2")
    import_and_publish(client, b_inr, 1)
    import_and_publish(client, b_usd, 1)
    w1, u1 = worked(client, b_inr)
    w2, u2 = worked(client, b_usd)
    with factory() as s:
        on_verdict_accepted(s, verdict_event(uuid.UUID(u1), uuid.UUID(b_inr), uuid.UUID(w1)))
        on_verdict_rejected(
            s,
            verdict_event(
                uuid.UUID(u2), uuid.UUID(b_usd), uuid.UUID(w2), "reject", "client_ambiguous_instruction", billable=True
            ),
        )
        s.commit()
    assert client.get(f"/v1/batches/{b_inr}/manifest", headers=OPS).status_code == 200
    o = client.get("/v1/client/overview", headers=as_client(user))
    assert o.status_code == 200, o.text
    d = o.json()
    assert [x["name"] for x in d["orgs"]] == ["Acme", "Beta"]
    assert d["units"] == {
        "total": 2,
        "available": 1,
        "claimed": 0,
        "submitted": 0,
        "in_review": 0,
        "accepted": 1,
        "rejected": 0,
        "needs_edits": 0,
    }
    assert Decimal(d["acceptance_rate"]) == Decimal("0.5") and d["billable_rework"] == 1 and d["deliveries"] == 1
    assert {k: Decimal(v) for k, v in d["invoice_total"].items()} == {"INR": Decimal("60"), "USD": Decimal("2")}
    assert no_pay(d)
    empty = client.get("/v1/client/overview", headers=as_client()).json()
    assert empty == {
        "orgs": [],
        "units": {k: 0 for k in d["units"]},
        "acceptance_rate": None,
        "billable_rework": 0,
        "deliveries": 0,
        "invoice_total": {},
        "next_delivery": None,
    }
    assert len(client.get("/v1/client/overview", headers=OPS).json()["orgs"]) == 3
    assert client.get("/v1/client/overview").status_code == 403


def test_feedback_is_posted_by_members_and_read_by_ops(client):
    user = str(uuid.uuid4())
    org_id = org_with_member(client, "Acme", user)
    project_id = make_project(client, org_id)
    r = client.post(
        f"/v1/client/projects/{project_id}/feedback", json={"body": "Glossary v2 please"}, headers=as_client(user)
    )
    assert r.status_code == 201, r.text
    assert r.json()["author_id"] == user and r.json()["body"] == "Glossary v2 please" and r.json()["created_at"]
    mine = client.get(f"/v1/client/projects/{project_id}", headers=as_client(user)).json()["feedback"]
    assert [f["id"] for f in mine] == [r.json()["id"]]
    assert client.get(f"/v1/projects/{project_id}", headers=OPS).json()["feedback"] == mine
    assert (
        client.post(
            f"/v1/client/projects/{project_id}/feedback", json={"body": "x" * 4001}, headers=as_client(user)
        ).status_code
        == 422
    )
    assert (
        client.post(
            f"/v1/client/projects/{project_id}/feedback", json={"body": ""}, headers=as_client(user)
        ).status_code
        == 422
    )
    assert (
        client.post(
            f"/v1/client/projects/{project_id}/feedback", json={"body": "x" * 4000}, headers=as_client(user)
        ).status_code
        == 201
    )
    assert (
        client.post(f"/v1/client/projects/{project_id}/feedback", json={"body": "hi"}, headers=as_client()).status_code
        == 404
    )
    assert (
        client.post(
            f"/v1/client/projects/{project_id}/feedback", json={"body": "hi"}, headers={"X-Role": "client"}
        ).status_code
        == 403
    )
    assert client.post(f"/v1/client/projects/{project_id}/feedback", json={"body": "hi"}).status_code == 403
    ops_note = client.post(
        f"/v1/client/projects/{project_id}/feedback", json={"body": "noted"}, headers={**OPS, "X-Worker-Id": user}
    )
    assert ops_note.status_code == 201
    assert (
        client.post(f"/v1/client/projects/{project_id}/feedback", json={"body": "noted"}, headers=OPS).status_code
        == 422
    )  # ops still need a subject to sign


def test_a_rejected_unit_is_counted_and_nothing_is_invoiced_for_it(client, factory):
    user = str(uuid.uuid4())
    project_id = make_project(client, org_with_member(client, "Acme", user))
    batch_id = make_batch(client, project_id)
    import_and_publish(client, batch_id, 1)
    with factory() as s:
        s.query(WorkUnit).first().status = "rejected"
        s.commit()
    d = client.get(f"/v1/client/projects/{project_id}", headers=as_client(user)).json()
    assert d["units"]["rejected"] == 1 and d["acceptance_rate"] is None and Decimal(d["invoice_total"]) == 0
