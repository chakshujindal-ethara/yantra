import uuid
from decimal import Decimal

import pytest
from sqlalchemy import func, select

from yantra_common.errors import Conflict, Invalid
from yantra_market.models import OUTBOX, WorkUnit
from yantra_market.service import import_units, publish_batch
from yantra_market.testing import good_lines


def count_units(session):
    return session.scalar(select(func.count()).select_from(WorkUnit))


def test_dry_run_reports_every_bad_line_and_writes_nothing(session, batch):
    lines = good_lines(3) + [
        {"external_ref": "bad1", "payload": {"text": "", "language": "hi"}},
        {"external_ref": "bad2", "payload": {"text": "x", "language": "fr"}},
        {"external_ref": "u0", "payload": {"text": "dup", "language": "ta"}},
    ]
    report = import_units(session, batch.id, lines, dry_run=True)
    session.commit()
    assert report.total == 6 and report.accepted == 3
    assert [(e.line, e.reason.split(":")[0]) for e in report.errors] == [
        (4, "payload"),
        (5, "payload"),
        (6, "duplicate external_ref"),
    ]
    assert count_units(session) == 0


def test_import_with_a_bad_line_writes_nothing(session, batch):
    lines = good_lines(2) + [{"external_ref": "bad", "payload": {}}]
    with pytest.raises(Invalid) as e:
        import_units(session, batch.id, lines, dry_run=False)
    assert e.value.context["errors"][0]["line"] == 3
    session.rollback()
    assert count_units(session) == 0


def test_import_writes_draft_units_and_a_second_import_cannot_reuse_a_ref(session, batch):
    worker = uuid.uuid4()
    lines = good_lines(5)
    lines[0]["assigned_worker_id"] = str(worker)
    report = import_units(session, batch.id, lines, dry_run=False)
    session.commit()
    assert report.accepted == 5
    units = session.scalars(select(WorkUnit).order_by(WorkUnit.external_ref)).all()
    assert {u.status for u in units} == {"draft"} and all(u.unit_pay is None for u in units)
    assert units[0].assigned_worker_id == worker and units[1].assigned_worker_id is None
    with pytest.raises(Invalid) as e:
        import_units(session, batch.id, good_lines(1), dry_run=False)
    assert e.value.context["errors"][0]["reason"] == "duplicate external_ref"


def test_publish_freezes_pay_and_price_on_every_unit_and_emits_one_event(session, batch):
    import_units(session, batch.id, good_lines(4), dry_run=False)
    publish_batch(session, batch.id)
    session.commit()
    units = session.scalars(select(WorkUnit)).all()
    assert all(u.status == "available" and u.unit_pay == Decimal("28") and u.unit_price == Decimal("60") for u in units)
    assert all(u.rubric_version == "v1" for u in units)
    events = session.execute(select(OUTBOX.c.type, OUTBOX.c.subject, OUTBOX.c.payload)).all()
    assert [(e.type, e.subject) for e in events] == [("work.unit.published.v1", f"batch/{batch.id}")]
    assert events[0].payload == {
        "batch_id": str(batch.id),
        "unit_count": 4,
        "unit_pay": "28",
        "unit_price": "60",
        "review_pay": "6",
        "currency": "INR",
        "mode": "open",
        "project_id": str(batch.project_id),
    }


def test_publish_twice_is_a_conflict(session, batch):
    import_units(session, batch.id, good_lines(1), dry_run=False)
    publish_batch(session, batch.id)
    with pytest.raises(Conflict):
        publish_batch(session, batch.id)


def test_publish_empty_batch_is_invalid(session, batch):
    with pytest.raises(Invalid):
        publish_batch(session, batch.id)


def test_batch_below_margin_floor_needs_a_recorded_approval(session, batch):
    # price 60, pay 28, review 6: margin 0.433 >= floor 0.30, publishes. Raise pay: margin 0.10 < 0.30.
    batch.unit_pay = Decimal("48")
    session.commit()
    import_units(session, batch.id, good_lines(1), dry_run=False)
    session.commit()
    with pytest.raises(Conflict) as e:
        publish_batch(session, batch.id)
    assert e.value.code == "below_margin_floor" and e.value.context["margin"] == "0.1000"
    session.rollback()
    publish_batch(session, batch.id, approved_by="finance lead", approval_note="pilot batch, cost history pending")
    session.commit()
    session.refresh(batch)
    assert batch.status == "published" and batch.floor_approved_by == "finance lead"


def test_a_batch_exactly_on_the_floor_publishes_without_approval(session, batch):
    # price 60, review 6, floor 0.30: pay 36 gives margin exactly 0.3000
    batch.unit_pay = Decimal("36")
    session.commit()
    import_units(session, batch.id, good_lines(1), dry_run=False)
    publish_batch(session, batch.id)
    session.commit()
    session.refresh(batch)
    assert batch.status == "published" and batch.floor_approved_by is None
