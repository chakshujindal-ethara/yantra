import uuid
from datetime import timedelta

from yantra_common.events import Envelope
from yantra_tracker import consumers
from yantra_tracker.models import LiveClaim

from .conftest import NOW


def env(type_: str, data: dict, at=NOW) -> Envelope:
    return Envelope(id=uuid.uuid4(), type=type_, subject="s", occurred_at=at, data=data)


def ids() -> dict[str, str]:
    return {"unit_id": str(uuid.uuid4()), "claim_id": str(uuid.uuid4()), "worker_id": str(uuid.uuid4())}


def test_a_claim_becomes_live_and_ends_by_expiry_submission_or_release(session):
    for kind, handler in (
        ("expired", consumers.on_claim_expired),
        ("released", consumers.on_claim_released),
    ):
        d = ids()
        batch = uuid.uuid4()
        claimed = {**d, "expires_at": (NOW + timedelta(hours=1)).isoformat(), "batch_id": str(batch)}
        consumers.on_unit_claimed(session, env("work.unit.claimed.v1", claimed))
        consumers.on_unit_claimed(session, env("work.unit.claimed.v1", claimed))  # redelivery
        row = session.get(LiveClaim, uuid.UUID(d["claim_id"]))
        assert row.batch_id == batch and row.ended_at is None and row.expires_at == NOW + timedelta(hours=1)
        handler(session, env("x", d, NOW + timedelta(minutes=5)))
        handler(session, env("x", d, NOW + timedelta(minutes=9)))  # a second end keeps the first
        session.refresh(row)
        assert (row.end_kind, row.ended_at) == (kind, NOW + timedelta(minutes=5))


def test_a_submission_for_an_unseen_claim_still_records_its_end(session):
    d = ids()
    submitted = {
        **d,
        "batch_id": str(uuid.uuid4()),
        "submission_id": str(uuid.uuid4()),
        "rubric_version": "v1",
    }
    consumers.on_unit_submitted(session, env("work.unit.submitted.v1", submitted))
    row = session.get(LiveClaim, uuid.UUID(d["claim_id"]))
    assert row.end_kind == "submitted" and row.claimed_at is None
