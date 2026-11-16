"""Test helpers for the market module and for every deployable that mounts it."""

import uuid
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

from sqlalchemy.orm import Session

from yantra_common.events import Envelope
from yantra_common.testing import database_fixtures as _database_fixtures
from yantra_market.models import TABLES, ClientMember, ClientOrg, ClientProject, WorkBatch, WorkerProfile

ALEMBIC_INI = Path(__file__).resolve().parents[1] / "alembic.ini"
SCHEMA_JSON: dict[str, Any] = {
    "type": "object",
    "required": ["text", "language"],
    "properties": {"text": {"type": "string", "minLength": 1}, "language": {"type": "string", "enum": ["hi", "ta"]}},
}


def database_fixtures(
    db_name: str, extra_inis: list[Path] | None = None, extra_tables: list[str] | None = None
) -> tuple[Any, Any, Any]:
    return _database_fixtures(db_name, [ALEMBIC_INI, *(extra_inis or [])], [*TABLES, *(extra_tables or [])])


def good_lines(n: int) -> list[dict[str, Any]]:
    return [{"external_ref": f"u{i}", "payload": {"text": f"line {i}", "language": "hi"}} for i in range(n)]


def make_project(session: Session, **overrides: Any) -> ClientProject:
    fields: dict[str, Any] = dict(
        name="Indic transcription",
        currency="INR",
        payload_schema=SCHEMA_JSON,
        rubric_version="v1",
        margin_floor=Decimal("0.30"),
        cert_gate="transcription",
    )
    p = ClientProject(**{**fields, **overrides})
    session.add(p)
    session.commit()
    return p


def make_batch(session: Session, project: ClientProject, **overrides: Any) -> WorkBatch:
    fields: dict[str, Any] = dict(
        project_id=project.id,
        title="Batch 1",
        unit_pay=Decimal("28"),
        unit_price=Decimal("60"),
        review_pay=Decimal("6"),
        currency="INR",
        claim_ttl_minutes=240,
        rubric_version=project.rubric_version,
    )
    b = WorkBatch(**{**fields, **overrides})
    session.add(b)
    session.commit()
    return b


def eligible_worker(session: Session, gates: list[str] | None = None) -> uuid.UUID:
    w = WorkerProfile(id=uuid.uuid4(), partner_ref=None, status="eligible", cert_gates=gates or ["transcription"])
    session.add(w)
    session.commit()
    return w.id


def make_org(session: Session, name: str = "Acme Labs", members: list[uuid.UUID] | None = None) -> ClientOrg:
    org = ClientOrg(name=name)
    session.add(org)
    session.flush()
    session.add_all(ClientMember(org_id=org.id, user_id=m) for m in members or [])
    session.commit()
    return org


def verdict_event(
    unit_id: uuid.UUID,
    batch_id: uuid.UUID,
    worker_id: uuid.UUID,
    verdict: str = "accept",
    reason_code: str | None = None,
    billable: bool = False,
    event_id: uuid.UUID | None = None,
) -> Envelope:
    """A canonical verdict as the consumer receives it: accepted for `accept`, rejected otherwise."""
    accepted = verdict == "accept"
    data: dict[str, Any] = {
        "unit_id": str(unit_id),
        "batch_id": str(batch_id),
        "submission_id": str(uuid.uuid4()),
        "worker_id": str(worker_id),
        "reviewer_id": str(uuid.uuid4()),
        "auditor_id": None,
        "rubric_version": "v1",
    }
    if not accepted:
        data.update(verdict=verdict, reason_code=reason_code or "incomplete", billable=billable)
    type_ = "quality.verdict.accepted.v1" if accepted else "quality.verdict.rejected.v1"
    return Envelope(event_id or uuid.uuid4(), type_, f"unit/{unit_id}", datetime.now(UTC), data)
