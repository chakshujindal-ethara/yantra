"""The operator's side of the market: counts by GROUP BY, the batch lifecycle (pause, resume, cancel), the units
table, the bench, and the project edit with its rubric log."""

import threading
import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest
from sqlalchemy import select

from yantra_common.db import unit_of_work
from yantra_common.errors import Conflict, NotFound
from yantra_market.models import Claim, WorkerProfile, WorkUnit
from yantra_market.schemas import UnitCounts
from yantra_market.service import (
    batch_count_by_project,
    batches_of,
    cancel_batch,
    claim_unit,
    get_worker,
    import_units,
    list_units,
    list_workers,
    live_claims_by_batch,
    manifests_by_batch,
    open_batches,
    patch_project,
    pause_batch,
    publish_batch,
    resume_batch,
    submit,
    sum_counts,
    unit_counts_by_batch,
    unit_counts_by_project,
    upsert_availability,
)
from yantra_market.testing import eligible_worker, good_lines, make_batch, make_org


def published(session, batch, n):
    import_units(session, batch.id, good_lines(n), dry_run=False)
    publish_batch(session, batch.id)
    session.commit()


def test_unit_counts_come_from_one_group_by_and_a_draft_counts_in_the_total_only(session, project, batch):
    import_units(session, batch.id, good_lines(3), dry_run=False)
    session.commit()
    assert unit_counts_by_batch(session, [batch.id])[batch.id] == UnitCounts(total=3)
    publish_batch(session, batch.id)
    worker = eligible_worker(session)
    claim = claim_unit(session, batch.id, worker, "counts-0001")
    submit(session, claim.id, worker, {"t": 1})
    other = eligible_worker(session)
    claim_unit(session, batch.id, other, "counts-0002")
    session.commit()
    expected = UnitCounts(total=3, available=1, claimed=1, submitted=1)
    assert unit_counts_by_batch(session, [batch.id])[batch.id] == expected
    assert unit_counts_by_project(session, [project.id])[project.id] == expected
    empty = make_batch(session, project)
    counts = unit_counts_by_batch(session, [batch.id, empty.id])
    assert counts[empty.id] == UnitCounts() and counts[batch.id] == expected
    assert unit_counts_by_batch(session, []) == {} and unit_counts_by_project(session, []) == {}
    assert (
        batch_count_by_project(session, [project.id]) == {project.id: 2} and batch_count_by_project(session, []) == {}
    )
    assert sum_counts([expected, UnitCounts(total=1, accepted=1)]) == UnitCounts(
        total=4, available=1, claimed=1, submitted=1, accepted=1
    )
    assert [b.id for b in batches_of(session, project.id)] == [batch.id, empty.id]
    assert manifests_by_batch(session, []) == {} and manifests_by_batch(session, [batch.id]) == {}


def test_live_claims_are_the_ones_still_inside_their_ttl(session, batch):
    published(session, batch, 2)
    assert live_claims_by_batch(session, []) == {}
    assert live_claims_by_batch(session, [batch.id]) == {batch.id: 0}
    w1, w2 = eligible_worker(session), eligible_worker(session)
    c1 = claim_unit(session, batch.id, w1, "live-0001")
    claim_unit(session, batch.id, w2, "live-0002")
    session.commit()
    assert live_claims_by_batch(session, [batch.id]) == {batch.id: 2}
    c1.expires_at = datetime.now(UTC) - timedelta(seconds=1)
    session.commit()
    assert live_claims_by_batch(session, [batch.id]) == {batch.id: 1}


def test_pause_hides_the_batch_refuses_new_claims_and_lets_an_in_flight_claim_submit(session, batch):
    with pytest.raises(Conflict):
        pause_batch(session, batch.id)  # a draft has nothing to pause
    session.rollback()
    published(session, batch, 2)
    worker, other = eligible_worker(session), eligible_worker(session)
    claim = claim_unit(session, batch.id, worker, "pause-0001")
    session.commit()
    assert pause_batch(session, batch.id).status == "paused"
    session.commit()
    assert open_batches(session, other) == []
    with pytest.raises(Conflict) as e:
        claim_unit(session, batch.id, other, "pause-0002")
    assert e.value.code == "batch_paused"
    session.rollback()
    assert submit(session, claim.id, worker, {"t": 1}).claim_id == claim.id
    session.commit()
    with pytest.raises(Conflict):
        pause_batch(session, batch.id)  # already paused
    session.rollback()
    assert resume_batch(session, batch.id).status == "published"
    session.commit()
    assert len(open_batches(session, other)) == 1
    with pytest.raises(Conflict):
        resume_batch(session, batch.id)  # only a paused batch resumes
    session.rollback()


def test_cancel_needs_zero_live_claims_and_ends_the_batch(session, project, batch):
    published(session, batch, 2)
    worker = eligible_worker(session)
    claim = claim_unit(session, batch.id, worker, "cancel-0001")
    session.commit()
    with pytest.raises(Conflict) as e:
        cancel_batch(session, batch.id)
    assert e.value.code == "batch_has_live_claims" and e.value.context["live_claims"] == 1
    session.rollback()
    claim.expires_at = datetime.now(UTC) - timedelta(seconds=1)  # lapsed: the worker cannot submit on it
    session.commit()
    assert cancel_batch(session, batch.id).status == "cancelled"
    session.commit()
    for move in (pause_batch, resume_batch, cancel_batch):
        with pytest.raises(Conflict):
            move(session, batch.id)
        session.rollback()
    draft = make_batch(session, project)
    assert cancel_batch(session, draft.id).status == "cancelled"
    paused = make_batch(session, project)
    published(session, paused, 1)
    pause_batch(session, paused.id)
    assert cancel_batch(session, paused.id).status == "cancelled"
    with pytest.raises(NotFound):
        cancel_batch(session, uuid.uuid4())


def test_cancel_waits_for_a_claim_in_flight_and_then_sees_it(factory, session, batch):
    """The claim holds the batch row shared until it commits; cancel takes it exclusively, so it either runs
    before the claim (and the claim then finds the batch cancelled) or after it (and counts the live claim)."""
    published(session, batch, 1)
    worker = eligible_worker(session)
    claim_unit(session, batch.id, worker, "race-0001")  # not committed: the shared lock is held
    outcome: dict[str, object] = {}

    def cancel() -> None:
        try:
            with unit_of_work(factory) as s:
                cancel_batch(s, batch.id)
            outcome["status"] = "cancelled"
        except Conflict as e:
            outcome["status"] = e.code

    t = threading.Thread(target=cancel)
    t.start()
    t.join(0.3)
    assert t.is_alive() and outcome == {}, "cancel must block behind the claim"
    session.commit()
    t.join(2)
    assert outcome == {"status": "batch_has_live_claims"}
    session.refresh(batch)
    assert batch.status == "published"


def test_a_claim_arriving_on_a_cancelled_batch_is_refused_and_so_is_its_submission(session, batch):
    published(session, batch, 2)
    worker = eligible_worker(session)
    claim = claim_unit(session, batch.id, worker, "late-0001")
    session.commit()
    batch.status = "cancelled"  # the state a cancel that won the batch lock leaves behind
    session.commit()
    with pytest.raises(Conflict) as e:
        claim_unit(session, batch.id, eligible_worker(session), "late-0002")
    assert e.value.context["status"] == "cancelled"
    session.rollback()
    with pytest.raises(Conflict) as e:
        submit(session, claim.id, worker, {"t": 1})
    assert e.value.code == "batch_cancelled"
    session.rollback()
    assert session.get(Claim, claim.id).status == "active"


def test_the_units_table_filters_by_status_and_pages(session, batch):
    published(session, batch, 5)
    worker = eligible_worker(session)
    claim = claim_unit(session, batch.id, worker, "units-0001")
    session.commit()
    total, items = list_units(session, batch.id, None, 2, 0)
    assert total == 5 and [u.external_ref for u in items] == ["u0", "u1"]
    total, items = list_units(session, batch.id, None, 2, 4)
    assert total == 5 and [u.external_ref for u in items] == ["u4"]
    total, items = list_units(session, batch.id, "claimed", 50, 0)
    assert total == 1 and items[0].id == claim.unit_id and items[0].current_claim_id == claim.id
    assert list_units(session, batch.id, "accepted", 50, 0) == (0, [])
    with pytest.raises(NotFound):
        list_units(session, uuid.uuid4(), None, 50, 0)


def test_the_bench_filters_by_status_gate_and_id_prefix_and_joins_availability(session):
    a = eligible_worker(session, gates=["transcription", "captioning"])
    b = eligible_worker(session, gates=["captioning"])
    session.add(WorkerProfile(id=uuid.uuid4(), status="suspended", cert_gates=[]))
    session.commit()
    upsert_availability(session, a, weekly_hours=12, paused_until=None)
    session.commit()
    total, rows = list_workers(session, None, None, None, 50, 0)
    assert total == 3 and {w.id for w, _ in rows} == {a, b, *[w.id for w, _ in rows]}
    total, rows = list_workers(session, "eligible", None, None, 50, 0)
    assert total == 2 and {w.id for w, _ in rows} == {a, b}
    total, rows = list_workers(session, None, "transcription", None, 50, 0)
    assert total == 1 and rows[0][0].id == a and rows[0][1] is not None and rows[0][1].weekly_hours == 12
    total, rows = list_workers(session, None, None, str(a)[:8].upper(), 50, 0)
    assert total == 1 and rows[0][0].id == a
    assert list_workers(session, None, "nope", None, 50, 0) == (0, [])
    total, rows = list_workers(session, None, None, None, 1, 2)
    assert total == 3 and len(rows) == 1
    worker, availability = get_worker(session, b)
    assert worker.id == b and availability is None
    with pytest.raises(NotFound):
        get_worker(session, uuid.uuid4())


def test_patch_sets_the_fields_sent_and_a_rubric_bump_appends_to_the_log(session, project):
    org = make_org(session)
    before = datetime.now(UTC)
    patched = patch_project(
        session,
        project.id,
        {
            "name": "Renamed",
            "status": "closed",
            "margin_floor": Decimal("0.25"),
            "cert_gate": None,
            "brief": "Do the thing",
            "llm_policy": "no LLMs",
            "sensitive": True,
            "client_org_id": org.id,
            "answer_schema": {"type": "object"},
            "rubric_version": "v2",
            "rubric_note": "tightened the glossary",
        },
    )
    session.commit()
    assert (patched.name, patched.status, patched.margin_floor) == ("Renamed", "closed", Decimal("0.25"))
    assert (patched.cert_gate, patched.brief, patched.llm_policy, patched.sensitive) == (
        None,
        "Do the thing",
        "no LLMs",
        True,
    )
    assert patched.client_org_id == org.id and patched.answer_schema == {"type": "object"}
    assert patched.rubric_version == "v2" and len(patched.rubric_log) == 1
    entry = patched.rubric_log[0]
    assert entry["version"] == "v2" and entry["note"] == "tightened the glossary"
    assert datetime.fromisoformat(entry["at"]) >= before
    patch_project(session, project.id, {"rubric_version": "v2"})  # the same version again: no new entry
    patch_project(session, project.id, {"rubric_version": "v3"})  # a bump without a note still logs
    session.commit()
    assert [e["version"] for e in patched.rubric_log] == ["v2", "v3"] and patched.rubric_log[1]["note"] is None
    with pytest.raises(NotFound):
        patch_project(session, project.id, {"client_org_id": uuid.uuid4()})
    session.rollback()
    with pytest.raises(NotFound):
        patch_project(session, uuid.uuid4(), {"name": "x"})


def test_a_cancelled_batch_keeps_its_units_and_claims_as_they_were(session, batch):
    published(session, batch, 1)
    assert cancel_batch(session, batch.id).status == "cancelled"
    session.commit()
    assert session.scalar(select(WorkUnit)).status == "available"
    assert session.scalar(select(Claim)) is None
