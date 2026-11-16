import uuid
from datetime import timedelta

import pytest
from sqlalchemy import select

from yantra_common.errors import Conflict, Forbidden, NotFound
from yantra_tracker import service
from yantra_tracker.models import ActivitySession, AnomalyFlag

from .conftest import NOW
from .helpers import events, samples, send, start


def open_flags(session, kind):
    return session.scalars(select(AnomalyFlag).where(AnomalyFlag.kind == kind, AnomalyFlag.status == "open")).all()


def test_more_than_twenty_active_hours_in_a_day_is_flagged_once_while_open(session, worker):
    row = start(session, worker, NOW - timedelta(hours=21))
    base = NOW - timedelta(hours=21)
    batch = samples(base, 2401)  # 20 h + 30 s
    for i in range(0, len(batch), 500):
        send(session, row.id, worker, batch[i : i + 500], NOW, cap=168)
    assert service.scan_anomalies(session, NOW) == 1
    session.commit()
    assert service.scan_anomalies(session, NOW) == 0
    [flag] = open_flags(session, "impossible_activity")
    assert flag.detail == {"active_seconds": 72030, "window_hours": 24}
    [e] = events(session, "tracking.anomaly.flagged.v1")
    assert e["kind"] == "impossible_activity" and e["anomaly_id"] == str(flag.id)
    service.decide_anomaly(session, flag.id, uuid.uuid4(), "dismissed", "known shift", NOW)
    session.commit()
    assert service.scan_anomalies(session, NOW) == 1  # a dismissed flag does not hide a new one


def test_activity_long_after_the_claim_ended_is_flagged(session, worker):
    claim = uuid.uuid4()
    service.claim_started(session, claim, uuid.uuid4(), worker, None, None, NOW, NOW + timedelta(hours=1))
    session.commit()
    row = start(session, worker, NOW, claim_id=claim)
    service.claim_ended(session, claim, uuid.uuid4(), worker, NOW + timedelta(minutes=5), "submitted")
    session.commit()
    send(session, row.id, worker, samples(NOW + timedelta(minutes=10), 1), NOW + timedelta(minutes=10))
    assert service.scan_anomalies(session, NOW + timedelta(minutes=12)) == 0  # inside the ten-minute grace
    send(session, row.id, worker, samples(NOW + timedelta(minutes=16), 1), NOW + timedelta(minutes=16))
    assert service.scan_anomalies(session, NOW + timedelta(minutes=17)) == 1
    [flag] = open_flags(session, "no_live_claim")
    assert flag.session_id == row.id and flag.detail == {"claim_id": str(claim), "minutes_after": 11}


def test_one_device_on_several_workers_flags_each_of_them(session):
    a, b, c = sorted([uuid.uuid4() for _ in range(3)])
    for w in (a, b):
        r = start(session, w, NOW, dev="shared-device-1")
        service.end_session(session, r.id, w, NOW)
        session.commit()
    start(session, c, NOW, dev="alone-device-1")
    assert service.scan_anomalies(session, NOW) == 2
    flags = sorted(open_flags(session, "duplicate_device"), key=lambda f: str(f.worker_id))
    assert [f.worker_id for f in flags] == [a, b]
    assert flags[0].detail == {"device_hash": "shared-device-1", "worker_ids": [str(a), str(b)]}
    old = start(session, uuid.uuid4(), NOW - timedelta(days=8), dev="shared-device-1")
    session.commit()
    assert old.started_at < NOW - service.DEVICE_WINDOW and service.scan_anomalies(session, NOW) == 0


def test_an_operator_dismisses_or_upholds_once_and_upholding_is_announced(session, worker):
    session.add(AnomalyFlag(worker_id=worker, kind="duplicate_device", detail={}, status="open", created_at=NOW))
    session.add(AnomalyFlag(worker_id=worker, kind="impossible_activity", detail={}, status="open", created_at=NOW))
    session.commit()
    first, second = service.list_anomalies(session, "open", 10)
    ops = uuid.uuid4()
    upheld = service.decide_anomaly(session, first.id, ops, "upheld", "same household", NOW)
    assert (upheld.status, upheld.decided_by, upheld.note) == ("upheld", ops, "same household")
    service.decide_anomaly(session, second.id, ops, "dismissed", None, NOW)
    session.commit()
    [e] = events(session, "tracking.anomaly.upheld.v1")
    assert e["anomaly_id"] == str(first.id) and e["decided_by"] == str(ops) and e["kind"] == first.kind
    with pytest.raises(Conflict) as err:
        service.decide_anomaly(session, first.id, ops, "dismissed", None, NOW)
    assert err.value.code == "anomaly_decided"
    with pytest.raises(NotFound):
        service.decide_anomaly(session, uuid.uuid4(), ops, "dismissed", None, NOW)
    assert len(service.list_anomalies(session, None, 10)) == 2 and service.list_anomalies(session, "open", 10) == []


def test_operators_list_sessions_by_worker_and_range(session, worker):
    a = start(session, worker, NOW - timedelta(days=2))
    service.end_session(session, a.id, worker, NOW - timedelta(days=2))
    b = start(session, worker, NOW)
    start(session, uuid.uuid4(), NOW)
    assert [s.id for s in service.list_sessions(session, worker, None, None, 10)] == [b.id, a.id]
    assert [
        s.id for s in service.list_sessions(session, worker, NOW - timedelta(days=1), NOW + timedelta(days=1), 10)
    ] == [b.id]
    assert len(service.list_sessions(session, None, None, NOW - timedelta(days=1), 10)) == 1
    assert session.scalar(select(ActivitySession).where(ActivitySession.id == b.id)) is not None


def test_an_operator_never_decides_an_anomaly_about_themselves(session, worker):
    flag = AnomalyFlag(worker_id=worker, kind="pattern", detail={}, status="open", created_at=NOW)
    session.add(flag)
    session.commit()
    for outcome in ("dismissed", "upheld"):
        with pytest.raises(Forbidden) as e:
            service.decide_anomaly(session, flag.id, worker, outcome, None, NOW)
        assert e.value.code == "self_action"
    assert session.scalar(select(AnomalyFlag.status).where(AnomalyFlag.id == flag.id)) == "open"
