"""The delivery gate: a manifest exists only when every unit of the batch is accepted; it is built once."""

import uuid
from datetime import UTC, datetime
from decimal import Decimal

import pytest
from sqlalchemy import select

from yantra_common.errors import Conflict, NotFound
from yantra_market.models import OUTBOX, DeliveryManifest, WorkUnit
from yantra_market.service import (
    active_claim,
    build_manifest,
    claim_unit,
    import_units,
    open_batches,
    publish_batch,
    submit,
)
from yantra_market.testing import eligible_worker, good_lines, make_batch


def _worked(session, batch, n: int, statuses: list[str]) -> list[WorkUnit]:
    import_units(session, batch.id, good_lines(n), dry_run=False)
    publish_batch(session, batch.id)
    units = list(session.scalars(select(WorkUnit).order_by(WorkUnit.external_ref)))
    for status in statuses:
        worker = eligible_worker(session)
        claim = claim_unit(session, batch.id, worker, f"key-{worker}")
        submit(session, claim.id, worker, {"t": 1})
        session.get(WorkUnit, claim.unit_id).status = status
    session.commit()
    return units


def test_a_batch_with_one_unaccepted_unit_is_held(session, batch):
    _worked(session, batch, 3, ["accepted", "accepted", "rejected"])
    with pytest.raises(Conflict) as e:
        build_manifest(session, batch.id)
    assert e.value.code == "batch_held" and e.value.context["held"] == {"rejected": 1}
    session.rollback()
    assert session.scalar(select(DeliveryManifest)) is None


def test_the_manifest_lists_every_accepted_unit_and_is_built_once(session, batch):
    units = _worked(session, batch, 2, ["accepted", "accepted"])
    first = build_manifest(session, batch.id)
    session.commit()
    again = build_manifest(session, batch.id)
    assert again.id == first.id and first.accepted_units == 2 and Decimal(first.total_price) == Decimal("120")
    assert [u["external_ref"] for u in first.units] == ["u0", "u1"] and first.units[0]["unit_id"] == str(units[0].id)
    assert session.get(type(batch), batch.id).status == "completed"
    types = [r.type for r in session.execute(select(OUTBOX.c.type))]
    assert types.count("delivery.manifest.created.v1") == 1


def test_manifest_needs_a_published_batch(session, batch):
    with pytest.raises(Conflict):
        build_manifest(session, batch.id)
    with pytest.raises(NotFound):
        build_manifest(session, uuid.uuid4())


def test_open_batches_count_the_units_a_worker_may_claim(session, batch):
    worker = eligible_worker(session)
    assert open_batches(session, worker) == []
    import_units(session, batch.id, good_lines(3), dry_run=False)
    publish_batch(session, batch.id)
    session.commit()
    [(row, n)] = open_batches(session, worker)
    assert row.id == batch.id and n == 3
    claim_unit(session, batch.id, worker, "key-000001")
    session.commit()
    assert open_batches(session, worker)[0][1] == 2
    mine = active_claim(session, worker)
    assert mine is not None and mine[1].status == "claimed" and mine[0].worker_id == worker
    assert active_claim(session, eligible_worker(session)) is None


def test_a_verdict_hands_the_unit_back_for_rework_and_the_gate_then_passes(session, batch):
    from yantra_common.events import Envelope
    from yantra_market.consumers import on_verdict_accepted, on_verdict_rejected

    import_units(session, batch.id, good_lines(1), dry_run=False)
    publish_batch(session, batch.id)
    author, other = eligible_worker(session), eligible_worker(session)
    claim = claim_unit(session, batch.id, author, "rework-00001")
    submit(session, claim.id, author, {"transcript": "draft"})
    session.commit()

    def verdict(type_: str, **extra):
        data = {
            "unit_id": str(claim.unit_id),
            "batch_id": str(batch.id),
            "submission_id": str(uuid.uuid4()),
            "worker_id": str(author),
            "reviewer_id": str(other),
            "auditor_id": None,
            "rubric_version": "v1",
            **extra,
        }
        return Envelope(uuid.uuid4(), type_, "t", datetime.now(UTC), data)

    on_verdict_rejected(
        session, verdict("quality.verdict.rejected.v1", verdict="needs_edits", reason_code="incomplete", billable=False)
    )
    session.commit()
    unit = session.get(WorkUnit, claim.unit_id)
    assert unit.status == "available" and unit.assigned_worker_id == author and unit.current_claim_id is None
    assert open_batches(session, other) == [] and open_batches(session, author)[0][1] == 1  # the author's to redo
    with pytest.raises(NotFound):
        claim_unit(session, batch.id, other, "rework-other-1")
    again = claim_unit(session, batch.id, author, "rework-00002")
    submit(session, again.id, author, {"transcript": "final"})
    session.commit()
    on_verdict_accepted(session, verdict("quality.verdict.accepted.v1"))
    session.commit()
    manifest = build_manifest(session, batch.id)
    assert manifest.accepted_units == 1 and manifest.units[0]["answer"] == {"transcript": "final"}

    # a reject sends a unit back to the pool for anyone
    batch2 = make_batch(session, _project_of(session, batch))
    import_units(session, batch2.id, good_lines(1), dry_run=False)
    publish_batch(session, batch2.id)
    c2 = claim_unit(session, batch2.id, author, "reject-00001")
    submit(session, c2.id, author, {"transcript": "bad"})
    session.commit()
    data = verdict("quality.verdict.rejected.v1", verdict="reject", reason_code="low_quality", billable=False)
    data.data["unit_id"] = str(c2.unit_id)
    data.data["batch_id"] = str(batch2.id)
    on_verdict_rejected(session, data)
    session.commit()
    u2 = session.get(WorkUnit, c2.unit_id)
    assert u2.status == "available" and u2.assigned_worker_id is None
    assert claim_unit(session, batch2.id, other, "reject-other-1").unit_id == c2.unit_id


def _project_of(session, batch):
    from yantra_market.models import ClientProject

    return session.get(ClientProject, batch.project_id)


def test_assigned_mode_browsing_matches_what_a_claim_will_give(session, project):
    batch = make_batch(session, project, mode="assigned")
    w1, w2 = eligible_worker(session), eligible_worker(session)
    lines = good_lines(2)
    lines[0]["assigned_worker_id"] = str(w1)
    import_units(session, batch.id, lines, dry_run=False)
    publish_batch(session, batch.id)
    session.commit()
    assert open_batches(session, w1)[0][1] == 1  # only the unit assigned to them; the unassigned one is nobody's
    assert open_batches(session, w2) == []
    with pytest.raises(NotFound):
        claim_unit(session, batch.id, w2, "assigned-w2-01")
    assert claim_unit(session, batch.id, w1, "assigned-w1-01").unit_id is not None


def test_an_oversized_answer_or_payload_is_refused(session, batch):
    from yantra_common.errors import Invalid
    from yantra_market.rules import MAX_JSON_BYTES, json_size

    big = {"text": "x" * (MAX_JSON_BYTES + 1), "language": "hi"}
    report = import_units(session, batch.id, [{"external_ref": "big", "payload": big}], dry_run=True)
    assert report.accepted == 0 and report.errors[0].reason == "payload: over 256 KB"
    assert json_size({"a": 1}) == 7
    with pytest.raises(Invalid):
        import_units(session, batch.id, [{"external_ref": "big", "payload": big}], dry_run=False)


def test_an_expired_claim_is_not_live_and_a_paused_batch_is_not_browsable(session, batch):
    from datetime import timedelta

    import_units(session, batch.id, good_lines(1), dry_run=False)
    publish_batch(session, batch.id)
    worker = eligible_worker(session)
    claim = claim_unit(session, batch.id, worker, "ttl-000001")
    session.commit()
    assert active_claim(session, worker) is not None
    claim.expires_at = datetime.now(UTC) - timedelta(seconds=1)
    session.commit()
    assert active_claim(session, worker) is None
    batch.status = "paused"
    session.commit()
    assert open_batches(session, eligible_worker(session)) == []


def test_the_manifest_digest_is_the_hash_of_its_units(session, batch):
    import hashlib
    import json

    _worked(session, batch, 2, ["accepted", "accepted"])
    manifest = build_manifest(session, batch.id)
    expected = hashlib.sha256(json.dumps(manifest.units, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    assert manifest.digest == expected


def test_open_batches_show_only_the_pools_the_worker_is_certified_for(session, batch, project):
    import_units(session, batch.id, good_lines(2), dry_run=False)
    publish_batch(session, batch.id)
    session.commit()
    certified = eligible_worker(session, gates=["transcription"])
    other_gate = eligible_worker(session, gates=["captioning"])
    stranger = uuid.uuid4()  # no profile row at all
    assert len(open_batches(session, certified)) == 1
    assert open_batches(session, other_gate) == []
    assert open_batches(session, stranger) == []
    project.cert_gate = None  # an ungated project is open to everyone
    session.flush()
    assert len(open_batches(session, other_gate)) == 1
