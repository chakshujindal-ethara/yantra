"""Test helpers for the quality module."""

import uuid
from pathlib import Path
from typing import Any

from sqlalchemy.orm import Session

from yantra_common.events import Envelope
from yantra_common.testing import database_fixtures as _database_fixtures
from yantra_quality.models import TABLES
from yantra_quality.service import on_unit_submitted, sampled_for_audit

ALEMBIC_INI = Path(__file__).resolve().parents[1] / "alembic.ini"


def database_fixtures(db_name: str) -> tuple[Any, Any, Any]:
    return _database_fixtures(db_name, [ALEMBIC_INI], TABLES)


def submitted_envelope(author: uuid.UUID, batch_id: uuid.UUID, unit_id: uuid.UUID | None = None) -> Envelope:
    from datetime import UTC, datetime

    unit_id = unit_id or uuid.uuid4()
    return Envelope(
        id=uuid.uuid4(),
        type="work.unit.submitted.v1",
        subject=f"unit/{unit_id}",
        occurred_at=datetime.now(UTC),
        data={
            "unit_id": str(unit_id),
            "batch_id": str(batch_id),
            "claim_id": str(uuid.uuid4()),
            "submission_id": str(uuid.uuid4()),
            "worker_id": str(author),
            "rubric_version": "v1",
            "payload": {"text": "namaste", "language": "hi"},
            "answer": {"transcript": "namaste"},
        },
    )


def open_task(session: Session, author: uuid.UUID, batch_id: uuid.UUID, unit_id: uuid.UUID | None = None) -> uuid.UUID:
    env = submitted_envelope(author, batch_id, unit_id)
    on_unit_submitted(session, env)
    session.commit()
    return uuid.UUID(env.data["unit_id"])


def unit_sampled_for_audit(sampled: bool, key: str | None = None) -> uuid.UUID:
    """A unit id the audit sample takes (`sampled`) or leaves, under `key` (default: the process's audit key, the
    rig's in tests). Ids are tried in order from 1, so the answer is the same on every run."""
    i = 1
    while sampled_for_audit(uuid.UUID(int=i), key=key) != sampled:
        i += 1
    return uuid.UUID(int=i)
