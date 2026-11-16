import uuid
from datetime import timedelta

import pytest

from yantra_common.errors import Conflict, Invalid, NotFound
from yantra_tracker import service
from yantra_tracker.schemas import SCREENSHOT_MAX_BYTES
from yantra_tracker.testing import FakePresigner

from .conftest import NOW
from .helpers import start


def test_presign_builds_a_key_under_the_session_signed_for_the_declared_size(session, worker):
    row = start(session, worker, NOW)
    with pytest.raises(service.StorageUnconfigured):
        service.presign_screenshot(session, None, worker, row.id, "image/png", 100)
    fake = FakePresigner()
    key, signed = service.presign_screenshot(session, fake, worker, row.id, "image/png", 1234)
    assert key.startswith(f"tracker/{worker}/{row.id}/") and key.endswith(".png")
    assert fake.puts == [(key, "image/png", 1234, 1234)] and signed.url.startswith("fake://")
    jpg, _ = service.presign_screenshot(session, fake, worker, row.id, "image/jpeg", SCREENSHOT_MAX_BYTES)
    assert jpg.endswith(".jpg")
    for size in (0, SCREENSHOT_MAX_BYTES + 1):
        with pytest.raises(Invalid) as e:
            service.presign_screenshot(session, fake, worker, row.id, "image/png", size)
        assert e.value.code == "too_large"
    with pytest.raises(NotFound):
        service.presign_screenshot(session, fake, uuid.uuid4(), row.id, "image/png", 10)
    service.end_session(session, row.id, worker, NOW)
    with pytest.raises(Conflict):
        service.presign_screenshot(session, fake, worker, row.id, "image/png", 10)


def register(session, fake, worker, sid, key, size=10, at=NOW):
    return service.register_screenshot(session, fake, sid, worker, key, size, at, NOW, 30, 300)


def test_a_screenshot_registers_only_under_its_prefix_during_its_session_at_its_size(session, worker):
    row = start(session, worker, NOW)
    key = f"tracker/{worker}/{row.id}/a.png"
    fake = FakePresigner(objects={key: 10, f"tracker/{worker}/{row.id}/c.jpg": 10})
    with pytest.raises(service.StorageUnconfigured):
        register(session, None, worker, row.id, key)
    ref = register(session, fake, worker, row.id, key, at=NOW + timedelta(minutes=1))
    assert ref.content_type == "image/png" and ref.retention_until == NOW + timedelta(days=30, minutes=1)
    for bad in (f"tracker/{uuid.uuid4()}/{row.id}/a.png", f"tracker/{worker}/{row.id}/../x.png"):
        with pytest.raises(Invalid) as e:
            register(session, fake, worker, row.id, bad)
        assert e.value.code == "key_not_yours"
    with pytest.raises(Invalid) as e:
        register(session, fake, worker, row.id, f"tracker/{worker}/{row.id}/b.jpg", at=NOW + timedelta(hours=1))
    assert e.value.code == "taken_outside_session"
    with pytest.raises(Conflict):
        register(session, fake, worker, row.id, key)
    jpg = register(session, fake, worker, row.id, f"tracker/{worker}/{row.id}/c.jpg")
    assert jpg.content_type == "image/jpeg"


def test_storage_must_hold_the_object_at_the_size_declared(session, worker):
    row = start(session, worker, NOW)
    big = f"tracker/{worker}/{row.id}/big.png"
    fake = FakePresigner(objects={big: SCREENSHOT_MAX_BYTES + 1})
    with pytest.raises(Invalid) as e:
        register(session, fake, worker, row.id, f"tracker/{worker}/{row.id}/none.png")
    assert e.value.code == "object_missing"
    with pytest.raises(Invalid) as e:
        register(session, fake, worker, row.id, big, size=SCREENSHOT_MAX_BYTES + 1)
    assert e.value.code == "size_mismatch" and fake.deleted == [big] and fake.objects == {}
    other = f"tracker/{worker}/{row.id}/other.png"
    fake.objects[other] = 99
    with pytest.raises(Invalid) as e:
        register(session, fake, worker, row.id, other, size=10)
    assert e.value.code == "size_mismatch" and other in fake.deleted
