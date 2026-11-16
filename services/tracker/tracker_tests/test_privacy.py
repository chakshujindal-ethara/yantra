"""Consent withdrawn stops collection; an erasure takes the worker's samples, screenshots and device ids."""

import uuid
from datetime import timedelta

import pytest
from sqlalchemy import func, select

from yantra_common.errors import Forbidden
from yantra_tracker import consumers, service
from yantra_tracker.models import ActivitySample, ActivitySession, AnomalyFlag, Erasure, ScreenshotRef
from yantra_tracker.schemas import SessionIn
from yantra_tracker.testing import FakePresigner, device

from .conftest import NOW
from .helpers import events, samples, send, start
from .test_consumers import env


def refused(fn, *args):
    with pytest.raises(Forbidden) as e:
        fn(*args)
    assert e.value.code == "consent_withdrawn" and e.value.status == 403


def test_a_withdrawal_ends_the_open_session_and_refuses_collection_until_consent_returns(session, worker):
    row = start(session, worker, NOW)
    send(session, row.id, worker, samples(NOW, 2), NOW)
    withdrawn = env("worker.consent.withdrawn.v1", {"worker_id": str(worker)}, NOW + timedelta(minutes=1))
    consumers.on_consent_withdrawn(session, withdrawn)
    consumers.on_consent_withdrawn(session, withdrawn)  # a redelivery: nothing more ends
    session.commit()
    session.refresh(row)
    assert row.end_reason == "consent" and row.ended_at == NOW + timedelta(minutes=1)
    assert [e["session_id"] for e in events(session, "tracking.session.ended.v1")] == [str(row.id)]
    fake = FakePresigner(objects={f"tracker/{worker}/{row.id}/a.png": 1})
    refused(service.start_session, session, worker, SessionIn(device_hash=device()), NOW)
    refused(service.add_samples, session, row.id, worker, samples(NOW, 1), NOW, 300, 40)
    refused(service.presign_screenshot, session, fake, worker, row.id, "image/png", 1)
    refused(
        service.register_screenshot,
        session,
        fake,
        row.id,
        worker,
        f"tracker/{worker}/{row.id}/a.png",
        1,
        NOW,
        NOW,
        30,
        300,
    )
    consumers.on_consent_given(session, env("worker.consent.given.v1", {"worker_id": str(worker)}))
    session.commit()
    assert start(session, worker, NOW + timedelta(minutes=2)).ended_at is None


def test_an_erasure_takes_samples_screenshots_and_device_ids_and_the_purge_takes_the_objects(session, worker):
    other = uuid.uuid4()
    row = start(session, worker, NOW, dev="shared-device-1")
    theirs = start(session, other, NOW, dev="other-device-1")
    send(session, row.id, worker, samples(NOW, 3), NOW)
    send(session, theirs.id, other, samples(NOW, 2), NOW)
    registered = f"tracker/{worker}/{row.id}/a.png"
    fake = FakePresigner(objects={registered: 5, f"tracker/{worker}/{row.id}/orphan.png": 5, f"tracker/{other}/x": 5})
    service.register_screenshot(session, fake, row.id, worker, registered, 5, NOW, NOW, 30, 300)
    session.add(
        AnomalyFlag(
            worker_id=worker,
            kind="duplicate_device",
            detail={"device_hash": "shared-device-1", "worker_ids": [str(worker)]},
            status="open",
            created_at=NOW,
        )
    )
    session.commit()
    erased = env("worker.erasure.completed.v1", {"worker_id": str(worker)}, NOW + timedelta(days=1))
    consumers.on_erasure_completed(session, erased)
    consumers.on_erasure_completed(session, erased)
    session.commit()
    session.refresh(row)
    assert row.device_hash == service.ERASED_DEVICE and row.active_seconds == 90  # the totals stay
    assert session.get(ActivitySession, theirs.id).device_hash == "other-device-1"
    assert session.scalar(select(func.count()).select_from(ActivitySample)) == 2  # only the other worker's
    assert session.scalar(select(func.count()).select_from(ScreenshotRef)) == 0
    assert session.scalar(select(AnomalyFlag.detail)) == {"worker_ids": [str(worker)]}
    assert service.purge_erased(session, NOW, None) == 0  # waits for storage
    assert service.purge_erased(session, NOW, fake) == 1
    assert service.purge_erased(session, NOW, fake) == 0
    session.commit()
    assert list(fake.objects) == [f"tracker/{other}/x"]
    assert session.get(Erasure, worker).objects_purged_at == NOW


def test_an_erasure_with_no_objects_deletes_nothing(session, worker):
    service.erase_worker(session, worker, NOW)
    fake = FakePresigner()
    assert service.purge_erased(session, NOW, fake) == 1 and fake.deleted == []


def test_erased_device_ids_are_never_a_shared_device(session):
    a, b = uuid.uuid4(), uuid.uuid4()
    for w in (a, b):
        service.end_session(session, start(session, w, NOW).id, w, NOW)
        service.erase_worker(session, w, NOW)
    session.commit()
    assert service.find_shared_devices(session, NOW) == []
