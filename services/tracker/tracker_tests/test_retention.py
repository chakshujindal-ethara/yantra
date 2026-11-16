import uuid
from datetime import timedelta

from sqlalchemy import func, select

from yantra_tracker import service
from yantra_tracker.models import ActivitySample, ScreenshotRef
from yantra_tracker.testing import FakePresigner

from .conftest import NOW
from .helpers import events, samples, send, start


def register(session, worker, sid, key, taken_at):
    fake = FakePresigner(objects={key: 10})
    return service.register_screenshot(session, fake, sid, worker, key, 10, taken_at, NOW, 30, 300)


def test_old_samples_and_screenshots_past_their_retention_are_purged(session, worker):
    old = start(session, worker, NOW - timedelta(days=40))
    send(session, old.id, worker, samples(NOW - timedelta(days=40), 3), NOW - timedelta(days=40))
    register(session, worker, old.id, f"tracker/{worker}/{old.id}/a.png", NOW - timedelta(days=40))
    service.end_session(session, old.id, worker, NOW - timedelta(days=40))
    session.commit()
    new = start(session, worker, NOW)
    send(session, new.id, worker, samples(NOW, 2), NOW)
    register(session, worker, new.id, f"tracker/{worker}/{new.id}/b.png", NOW)
    session.commit()
    fake = FakePresigner()
    assert service.purge_expired(session, NOW, 30, fake, limit=2) == 3  # two samples and one screenshot this pass
    assert service.purge_expired(session, NOW, 30, fake) == 1
    assert service.purge_expired(session, NOW, 30) == 0
    session.commit()
    assert session.scalar(select(func.count()).select_from(ActivitySample)) == 2
    assert session.scalars(select(ScreenshotRef.object_key)).all() == [f"tracker/{worker}/{new.id}/b.png"]
    assert fake.deleted == [f"tracker/{worker}/{old.id}/a.png"]


def test_a_purge_without_storage_still_drops_the_reference(session, worker):
    row = start(session, worker, NOW - timedelta(days=40))
    register(session, worker, row.id, f"tracker/{worker}/{row.id}/a.png", NOW - timedelta(days=40))
    session.commit()
    assert service.purge_expired(session, NOW, 30) == 1


def test_stale_sessions_are_ended_by_the_system(session, worker):
    quiet = start(session, worker, NOW - timedelta(minutes=20))
    busy_worker = uuid.uuid4()
    busy = start(session, busy_worker, NOW - timedelta(minutes=20))
    send(session, busy.id, busy_worker, samples(NOW - timedelta(minutes=5), 1), NOW)
    assert service.end_stale_sessions(session, NOW, 15) == 1
    session.commit()
    session.refresh(quiet)
    session.refresh(busy)
    assert quiet.end_reason == "stale" and busy.ended_at is None
    [e] = events(session, "tracking.session.ended.v1")
    assert e["session_id"] == str(quiet.id)
