import uuid
from datetime import timedelta
from decimal import Decimal

import pytest
from pydantic import ValidationError
from sqlalchemy import select

from yantra_common.errors import Conflict, Invalid, NotFound
from yantra_common.pii import pii_hash
from yantra_tracker import service
from yantra_tracker.models import ActivitySample, AnomalyFlag
from yantra_tracker.schemas import SampleIn, SamplesIn

from .conftest import NOW
from .helpers import events, samples, send, start


def test_a_batch_sent_twice_counts_once(session, worker):
    row = start(session, worker, NOW)
    batch = samples(NOW, 3)
    first = send(session, row.id, worker, batch, NOW + timedelta(minutes=2))
    again = send(session, row.id, worker, batch, NOW + timedelta(minutes=2))
    assert (first.accepted, first.duplicates, first.active_seconds) == (3, 0, 90)
    assert (again.accepted, again.duplicates, again.active_seconds) == (0, 3, 90)
    assert session.get(type(row), row.id).last_sample_at == NOW + timedelta(seconds=60)


def test_two_samples_in_one_bucket_are_one_row_and_idle_kinds_count_as_idle(session, worker):
    row = start(session, worker, NOW)
    out = send(
        session,
        row.id,
        worker,
        [
            SampleIn(at=NOW + timedelta(seconds=1), kind="active"),
            SampleIn(at=NOW + timedelta(seconds=11), kind="idle"),
            SampleIn(at=NOW + timedelta(seconds=31), kind="focus_lost"),
            SampleIn(at=NOW + timedelta(seconds=61), kind="idle"),
        ],
        NOW + timedelta(minutes=2),
    )
    assert (out.accepted, out.duplicates, out.active_seconds, out.idle_seconds) == (3, 1, 30, 60)
    rows = session.scalars(select(ActivitySample).order_by(ActivitySample.at)).all()
    assert [r.at for r in rows] == [NOW, NOW + timedelta(seconds=30), NOW + timedelta(seconds=60)]


def test_samples_outside_the_session_or_far_in_the_future_are_refused(session, worker):
    row = start(session, worker, NOW)
    for at in (NOW - timedelta(minutes=6), NOW + timedelta(minutes=8)):
        with pytest.raises(Invalid) as e:
            send(
                session,
                row.id,
                worker,
                [SampleIn(at=NOW, kind="active"), SampleIn(at=at, kind="active")],
                NOW + timedelta(minutes=2),
            )
        assert e.value.code == "sample_out_of_range" and e.value.context["index"] == 1
        session.rollback()
    # within the skew either side is fine
    out = send(session, row.id, worker, [SampleIn(at=NOW - timedelta(minutes=4), kind="active")], NOW)
    assert out.accepted == 1


def test_labels_are_kept_only_for_the_web_client(session, worker):
    row = start(session, worker, NOW)
    send(
        session,
        row.id,
        worker,
        samples(NOW, 1, label="yantra-web") + samples(NOW + timedelta(seconds=30), 1, label="Chrome"),
        NOW + timedelta(minutes=1),
    )
    labels = session.scalars(select(ActivitySample.label).order_by(ActivitySample.at)).all()
    assert labels == ["yantra-web", pii_hash("Chrome")]
    with pytest.raises(ValidationError):
        SampleIn(at=NOW, kind="active", label="x" * 81)
    with pytest.raises(ValidationError):
        SamplesIn(samples=[SampleIn(at=NOW, kind="active")] * 501)


def test_samples_go_only_to_the_owners_open_session(session, worker):
    row = start(session, worker, NOW)
    with pytest.raises(NotFound):
        send(session, row.id, uuid.uuid4(), samples(NOW, 1), NOW)
    session.rollback()
    service.end_session(session, row.id, worker, NOW)
    session.commit()
    with pytest.raises(Conflict) as e:
        send(session, row.id, worker, samples(NOW, 1), NOW)
    assert e.value.code == "session_ended"


def test_going_over_the_cap_is_flagged_once_a_week_and_samples_keep_being_recorded(session, worker):
    service.set_cap(session, "worker", worker, Decimal("1"), uuid.uuid4(), NOW)
    session.commit()
    row = start(session, worker, NOW)
    under = send(session, row.id, worker, samples(NOW, 120), NOW + timedelta(hours=1))
    assert under.active_seconds == 3600 and not under.over_cap and under.week.cap_source == "worker"
    over = send(session, row.id, worker, samples(NOW + timedelta(hours=1), 2), NOW + timedelta(hours=1, minutes=1))
    assert over.over_cap and over.accepted == 2
    more = send(
        session, row.id, worker, samples(NOW + timedelta(hours=1, minutes=1), 2), NOW + timedelta(hours=1, minutes=2)
    )
    assert more.over_cap and more.accepted == 2
    flagged = session.scalars(select(ActivitySample.at).where(ActivitySample.over_cap)).all()
    assert len(flagged) == 4
    [flag] = session.scalars(select(AnomalyFlag)).all()
    assert (
        flag.kind == "over_cap" and flag.week_start.isoformat() == "2026-11-02" and flag.detail["cap_hours"] == "1.00"
    )
    [e] = events(session, "tracking.cap.exceeded.v1")
    assert e["worker_id"] == str(worker) and e["active_seconds"] == 3660 and e["week_start"] == "2026-11-02"
    assert session.get(type(row), row.id).over_cap_at == NOW + timedelta(hours=1, minutes=1)


def test_the_cap_comes_from_the_worker_then_the_project_then_the_default(session, worker):
    project = uuid.uuid4()
    assert service.resolve_cap(session, worker, project, 40) == (Decimal(40), "default")
    service.set_cap(session, "project", project, Decimal("12.5"), uuid.uuid4(), NOW)
    assert service.resolve_cap(session, worker, project, 40) == (Decimal("12.50"), "project")
    assert service.resolve_cap(session, worker, None, 40) == (Decimal(40), "default")
    cap = service.set_cap(session, "worker", worker, Decimal("20"), uuid.uuid4(), NOW)
    again = service.set_cap(session, "worker", worker, Decimal("25"), uuid.uuid4(), NOW + timedelta(minutes=1))
    assert again.weekly_cap_hours == Decimal("25.00") and cap is again
    assert service.resolve_cap(session, worker, project, 40) == (Decimal("25.00"), "worker")
    assert [c.scope for c in service.list_caps(session)] == ["project", "worker"]
