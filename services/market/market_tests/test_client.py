"""Client organisations and the client console's numbers: who may read which project (404 outside the scope, so
nothing leaks), the invoice total formula, the acceptance rate and the reason distribution off the verdict log."""

import uuid
from datetime import UTC, datetime
from decimal import Decimal

import pytest

from yantra_common.errors import NotFound
from yantra_market.models import VerdictLog
from yantra_market.schemas import ReasonRow
from yantra_market.service import (
    acceptance_rate,
    add_feedback,
    add_member,
    billable_rework,
    build_manifest,
    claim_unit,
    client_manifest,
    create_org,
    deliveries_of,
    feedback_of,
    get_org,
    import_units,
    invoice_total,
    list_orgs,
    list_projects,
    orgs_of_user,
    publish_batch,
    reasons_for,
    remove_member,
    scoped_project,
    submit,
)
from yantra_market.testing import eligible_worker, good_lines, make_batch, make_org, make_project


def test_orgs_and_membership_are_idempotent_and_listed_with_their_members(session):
    org = create_org(session, "Acme Labs")
    session.commit()
    assert org.created_at is not None and get_org(session, org.id).name == "Acme Labs"
    user = uuid.uuid4()
    add_member(session, org.id, user)
    add_member(session, org.id, user)  # twice is once
    session.commit()
    assert list_orgs(session) == [(org, [user])]
    assert orgs_of_user(session, user) == frozenset({org.id}) and orgs_of_user(session, uuid.uuid4()) == frozenset()
    remove_member(session, org.id, user)
    remove_member(session, org.id, user)  # gone is gone
    session.commit()
    assert list_orgs(session) == [(org, [])]
    other = make_org(session, "Other")
    assert [o.id for o, _ in list_orgs(session, frozenset({other.id}))] == [other.id]
    assert list_orgs(session, frozenset()) == []
    with pytest.raises(NotFound):
        get_org(session, uuid.uuid4())
    with pytest.raises(NotFound):
        add_member(session, uuid.uuid4(), user)
    with pytest.raises(NotFound):
        remove_member(session, uuid.uuid4(), user)


def test_a_project_outside_the_callers_orgs_is_404_and_an_operator_sees_every_org(session):
    mine, theirs = make_org(session, "Mine"), make_org(session, "Theirs")
    p_mine = make_project(session, client_org_id=mine.id)
    p_theirs = make_project(session, client_org_id=theirs.id)
    p_none = make_project(session)  # no org yet: an operator's draft, visible to no client
    scope = frozenset({mine.id})
    assert scoped_project(session, p_mine.id, scope).id == p_mine.id
    for hidden in (p_theirs.id, p_none.id, uuid.uuid4()):
        with pytest.raises(NotFound):
            scoped_project(session, hidden, scope)
    assert scoped_project(session, p_theirs.id, None).id == p_theirs.id
    assert [p.id for p in list_projects(session, scope)] == [p_mine.id]
    assert {p.id for p in list_projects(session)} == {p_mine.id, p_theirs.id, p_none.id}
    assert list_projects(session, frozenset()) == []


def _log(session, batch, verdict, reason_code=None, billable=False):
    session.add(
        VerdictLog(
            event_id=uuid.uuid4(),
            unit_id=uuid.uuid4(),
            batch_id=batch.id,
            project_id=batch.project_id,
            worker_id=uuid.uuid4(),
            verdict=verdict,
            reason_code=reason_code,
            billable=billable,
            at=datetime.now(UTC),
        )
    )
    session.commit()


def test_invoice_total_is_delivered_units_at_price_plus_billable_rework_at_the_batchs_price(session, project):
    assert invoice_total(session, project) == Decimal("0")
    batch = make_batch(session, project)  # price 60
    import_units(session, batch.id, good_lines(2), dry_run=False)
    publish_batch(session, batch.id)
    for _ in range(2):
        worker = eligible_worker(session)
        claim = claim_unit(session, batch.id, worker, f"inv-{worker}")
        submit(session, claim.id, worker, {"t": 1})
        session.get(type(claim), claim.id)
    from yantra_market.models import WorkUnit

    for unit in session.query(WorkUnit).all():
        unit.status = "accepted"
    session.commit()
    build_manifest(session, batch.id)
    session.commit()
    assert invoice_total(session, project) == Decimal("120")  # 2 x 60 delivered
    dearer = make_batch(session, project, unit_price=Decimal("100"))
    _log(session, dearer, "needs_edits", "client_glossary_change", billable=True)
    _log(session, dearer, "reject", "low_quality", billable=False)
    _log(session, batch, "needs_edits", "client_ambiguous_instruction", billable=True)
    assert invoice_total(session, project) == Decimal(
        "280"
    )  # 120 + 100 + 60: each billable rework at its batch's price
    assert billable_rework(session, [project.id]) == 2 and billable_rework(session, []) == 0
    assert [m.batch_id for m in deliveries_of(session, [project.id])] == [batch.id] and deliveries_of(session, []) == []


def test_acceptance_rate_and_reasons_read_the_verdict_log(session, project, batch):
    assert acceptance_rate(session, [project.id]) is None and acceptance_rate(session, []) is None
    assert reasons_for(session, [project.id]) == [] and reasons_for(session, []) == []
    _log(session, batch, "accept")
    _log(session, batch, "accept")
    _log(session, batch, "reject", "low_quality")
    _log(session, batch, "needs_edits", "incomplete")
    _log(session, batch, "needs_edits", "incomplete")
    _log(session, batch, "needs_edits", "client_glossary_change", billable=True)
    assert acceptance_rate(session, [project.id]) == Decimal("0.3333")  # 2 of 6
    assert reasons_for(session, [project.id]) == [
        ReasonRow(reason_code="incomplete", count=2, billable=False),
        ReasonRow(reason_code="client_glossary_change", count=1, billable=True),
        ReasonRow(reason_code="low_quality", count=1, billable=False),
    ]


def test_the_client_manifest_is_404_for_another_org_or_before_delivery(session):
    org = make_org(session)
    project = make_project(session, client_org_id=org.id)
    batch = make_batch(session, project)
    scope = frozenset({org.id})
    with pytest.raises(NotFound):
        client_manifest(session, batch.id, scope)  # nothing delivered yet
    with pytest.raises(NotFound):
        client_manifest(session, uuid.uuid4(), scope)
    import_units(session, batch.id, good_lines(1), dry_run=False)
    publish_batch(session, batch.id)
    worker = eligible_worker(session)
    claim = claim_unit(session, batch.id, worker, "manifest-01")
    submit(session, claim.id, worker, {"t": 1})
    from yantra_market.models import WorkUnit

    session.get(WorkUnit, claim.unit_id).status = "accepted"
    session.commit()
    manifest = build_manifest(session, batch.id)
    session.commit()
    assert client_manifest(session, batch.id, scope).id == manifest.id
    assert client_manifest(session, batch.id, None).id == manifest.id
    with pytest.raises(NotFound):
        client_manifest(session, batch.id, frozenset({uuid.uuid4()}))


def test_feedback_is_appended_in_order(session, project):
    author = uuid.uuid4()
    first = add_feedback(session, project, author, "first")
    second = add_feedback(session, project, author, "second")
    session.commit()
    assert first.created_at is not None and [f.body for f in feedback_of(session, project.id)] == ["first", "second"]
    assert second.author_id == author and feedback_of(session, uuid.uuid4()) == []
