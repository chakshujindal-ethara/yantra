import uuid
from datetime import timedelta

import pytest

from yantra_common.errors import Conflict, NotFound
from yantra_tracker import service

from .conftest import NOW
from .helpers import events, samples, send, start


def test_a_session_starts_at_the_server_clock_and_only_one_may_be_open(session, worker):
    row = start(session, worker, NOW)
    assert row.started_at == NOW and row.ended_at is None and row.source == "web"
    with pytest.raises(Conflict) as e:
        start(session, worker, NOW)
    assert e.value.code == "session_open" and e.value.context["session_id"] == str(row.id)
    session.rollback()
    start(session, uuid.uuid4(), NOW)  # another worker is free to start


def test_a_session_on_a_claim_must_find_the_claim_live(session, worker):
    unknown = start(session, worker, NOW, claim_id=uuid.uuid4())  # the claim event may not have arrived yet
    service.end_session(session, unknown.id, worker, NOW)
    session.commit()
    live = uuid.uuid4()
    service.claim_started(
        session, live, uuid.uuid4(), worker, uuid.uuid4(), (project := uuid.uuid4()), NOW, NOW + timedelta(hours=1)
    )
    session.commit()
    row = start(session, worker, NOW, claim_id=live)
    assert row.project_id == project
    service.end_session(session, row.id, worker, NOW)
    session.commit()
    cases = []
    other = uuid.uuid4()
    service.claim_started(session, other, uuid.uuid4(), uuid.uuid4(), None, None, NOW, NOW + timedelta(hours=1))
    cases.append(other)
    lapsed = uuid.uuid4()
    service.claim_started(
        session, lapsed, uuid.uuid4(), worker, None, None, NOW - timedelta(hours=2), NOW - timedelta(hours=1)
    )
    cases.append(lapsed)
    ended = uuid.uuid4()
    service.claim_ended(session, ended, uuid.uuid4(), worker, NOW, "submitted")
    cases.append(ended)
    session.commit()
    for claim in cases:
        with pytest.raises(Conflict) as e:
            start(session, worker, NOW, claim_id=claim)
        assert e.value.code == "claim_not_live"
        session.rollback()


def test_ending_is_idempotent_and_announced_once_with_the_totals(session, worker):
    row = start(session, worker, NOW)
    send(
        session,
        row.id,
        worker,
        samples(NOW, 3) + samples(NOW + timedelta(seconds=90), 1, "idle"),
        NOW + timedelta(minutes=2),
    )
    ended = service.end_session(session, row.id, worker, NOW + timedelta(minutes=3))
    session.commit()
    again = service.end_session(session, row.id, worker, NOW + timedelta(minutes=9))
    session.commit()
    assert ended.end_reason == "client" and again.ended_at == NOW + timedelta(minutes=3)
    [e] = events(session, "tracking.session.ended.v1")
    assert e["session_id"] == str(row.id) and e["active_seconds"] == 90 and e["idle_seconds"] == 30
    assert e["claim_id"] is None and e["source"] == "web"
    with pytest.raises(NotFound):
        service.end_session(session, row.id, uuid.uuid4(), NOW)


def test_my_sessions_lists_this_week_by_default_and_never_404s(session, worker):
    empty = service.my_sessions(session, worker, NOW, 40)
    assert empty.sessions == [] and empty.open_session_id is None and empty.week.cap_source == "default"
    last_week = start(session, worker, NOW - timedelta(days=7))
    service.end_session(session, last_week.id, worker, NOW - timedelta(days=7))
    session.commit()
    current = start(session, worker, NOW)
    send(session, current.id, worker, samples(NOW, 4), NOW + timedelta(minutes=2))
    mine = service.my_sessions(session, worker, NOW + timedelta(minutes=2), 40)
    assert [s.id for s in mine.sessions] == [current.id] and mine.open_session_id == current.id
    assert mine.week.active_seconds == 120 and not mine.week.over_cap
    both = service.my_sessions(session, worker, NOW, 40, from_=NOW - timedelta(days=8), to=NOW + timedelta(days=1))
    assert [s.id for s in both.sessions] == [current.id, last_week.id]
