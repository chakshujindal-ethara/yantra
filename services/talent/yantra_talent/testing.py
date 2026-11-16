"""Test helpers for the talent module and for every deployable that mounts it."""

import uuid
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

from sqlalchemy import delete, or_
from sqlalchemy.orm import Session

from yantra_common.testing import database_fixtures as _database_fixtures
from yantra_talent.models import CONSUMED, DEAD, OUTBOX, TABLES, Listing, Policy, WorkerGate
from yantra_talent.policies_seed import POLICIES
from yantra_talent.schemas import listing_steps

__all__ = [
    "ALEMBIC_INI",
    "CONSUMED",
    "DEAD",
    "OUTBOX",
    "TABLES",
    "database_fixtures",
    "grant_gate",
    "make_listing",
    "reset_policies",
]

ALEMBIC_INI = Path(__file__).resolve().parents[1] / "alembic.ini"
QUESTIONS: list[dict[str, Any]] = [
    {"key": "experience", "prompt": "Years of transcription work", "kind": "text", "required": True},
    {"key": "shift", "prompt": "Preferred shift", "kind": "choice", "options": ["day", "night"], "required": False},
]


def database_fixtures(db_name: str, extra_inis: list[Path] | None = None, extra_tables: list[str] | None = None) -> Any:
    return _database_fixtures(db_name, [ALEMBIC_INI, *(extra_inis or [])], [*TABLES, *(extra_tables or [])])


def make_listing(session: Session, **overrides: Any) -> Listing:
    fields: dict[str, Any] = dict(
        title="Hindi transcription",
        domain="transcription",
        summary="Transcribe short Hindi audio clips.",
        description="Clips of 30 to 90 seconds; the glossary is provided.",
        pay_min=Decimal("20"),
        pay_max=Decimal("30"),
        currency="INR",
        commitment="task_based",
        slots_total=5,
        cert_gate="transcription",
        requirements=["Native Hindi"],
        questions=QUESTIONS,
        status="open",
        posted_at=datetime.now(UTC),
    )
    merged = {**fields, **overrides}
    merged.setdefault("steps", listing_steps(None, merged.get("paper_id") is not None))
    listing = Listing(**merged)
    session.add(listing)
    session.commit()
    return listing


def grant_gate(session: Session, worker_id: uuid.UUID, gate: str, source: str = "assess") -> None:
    session.add(WorkerGate(worker_id=worker_id, gate=gate, source=source, at=datetime.now(UTC)))
    session.commit()


def reset_policies(session: Session) -> None:
    """Back to the seeded first versions: drop every version a test added."""
    seeded = [p["slug"] for p in POLICIES]
    session.execute(delete(Policy).where(or_(Policy.revision > 1, Policy.slug.not_in(seeded))))
    session.commit()
