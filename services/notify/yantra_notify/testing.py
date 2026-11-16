"""Test helpers for the notify module."""

import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from sqlalchemy.orm import Session

from yantra_common.testing import database_fixtures as _database_fixtures
from yantra_notify.models import TABLES, Channel

ALEMBIC_INI = Path(__file__).resolve().parents[1] / "alembic.ini"


def database_fixtures(db_name: str) -> tuple[Any, Any, Any]:
    return _database_fixtures(db_name, [ALEMBIC_INI], TABLES)


class FakeMailer:
    """Records sends; fails while `failing` is set, the way an SMTP relay that is away would."""

    def __init__(self) -> None:
        self.sent: list[tuple[str, str, str]] = []
        self.failing = False

    def send(self, to: str, subject: str, body: str) -> None:
        if self.failing:
            raise ConnectionRefusedError("smtp away")
        self.sent.append((to, subject, body))


def verified_channel(session: Session, worker_id: uuid.UUID, email: str) -> Channel:
    """A channel whose address is already verified (what `PUT` and the mailed code end in)."""
    channel = session.get(Channel, worker_id) or Channel(worker_id=worker_id, verify_attempts=0)
    channel.email, channel.email_verified_at = email, datetime.now(UTC)
    session.add(channel)
    session.flush()
    return channel
