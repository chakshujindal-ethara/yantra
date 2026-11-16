import uuid
from datetime import timedelta
from decimal import Decimal

from sqlalchemy import func, select

from yantra_analytics import service
from yantra_analytics.consumers import AnyGeneration
from yantra_analytics.models import DimBatch, DimUnit, Event
from yantra_common.events import Envelope

from .conftest import NOW, ids


def test_every_event_is_stored_once_with_its_ids_pulled_out(session, wh):
    batch, project, unit, worker, reviewer = ids(5)
    wh.published(NOW, batch, project)
    wh.verdict(NOW, unit, batch, worker, reviewer)
    env = Envelope(
        id=uuid.uuid4(), type="some.future.v9", subject="s", occurred_at=NOW, data={"worker_id": "not-a-uuid", "x": 1}
    )
    service.ingest(session, env)
    service.ingest(session, env)  # a redelivery
    session.commit()
    assert session.scalar(select(func.count()).select_from(Event)) == 3
    future = session.get(Event, env.id)
    assert future.worker_id is None and future.payload == {}  # an unknown type keeps only its well-formed ids
    verdict = session.scalar(select(Event).where(Event.type == "quality.verdict.accepted.v1"))
    assert (verdict.unit_id, verdict.batch_id, verdict.worker_id) == (unit, batch, worker)


def test_a_batch_learns_its_rates_and_its_project_from_publication_or_manifest(session, wh):
    a, b, project = ids(3)
    wh.published(NOW, a, project, pay="20", price="50", review="5")
    wh.published(NOW, b, None)
    row = session.get(DimBatch, a)
    assert (row.project_id, row.unit_pay, row.unit_price, row.review_pay, row.currency, row.unit_count) == (
        project,
        Decimal("20"),
        Decimal("50"),
        Decimal("5"),
        "INR",
        4,
    )
    assert session.get(DimBatch, b).project_id is None
    wh.put("delivery.manifest.created.v1", NOW, {"batch_id": b, "project_id": project, "currency": "INR"})
    assert session.get(DimBatch, b).project_id == project
    other = uuid.uuid4()
    wh.put("delivery.manifest.created.v1", NOW, {"batch_id": other, "project_id": project, "currency": "USD"})
    assert session.get(DimBatch, other).currency == "USD"
    wh.published(NOW + timedelta(hours=1), b, None, pay="25")  # a republication without a project keeps it
    assert session.get(DimBatch, b).project_id == project and session.get(DimBatch, b).unit_pay == Decimal("25")


def test_a_unit_learns_its_batch_from_any_event_naming_both(session, wh):
    unit, batch, worker = ids(3)
    wh.claimed(NOW, unit, worker)
    assert session.get(DimUnit, unit) is None
    wh.submitted(NOW, unit, batch, worker)
    wh.submitted(NOW, unit, uuid.uuid4(), worker)  # the first mapping stands
    assert session.get(DimUnit, unit).batch_id == batch


def test_dead_letters_of_any_generation_replay_through_ingest():
    table = AnyGeneration()
    assert table["analytics-all-g0"] is service.ingest and table.get("analytics-all-g7") is service.ingest
    assert table.get("market-x") is None and list(table) == ["analytics-all-g0"] and len(table) == 1
