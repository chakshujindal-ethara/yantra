"""Test helpers for the tracker module and for every deployable that mounts it."""

import uuid
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from yantra_common.testing import database_fixtures as _database_fixtures
from yantra_tracker.models import CONSUMED, DEAD, JOB_LEASE, OUTBOX, TABLES

__all__ = [
    "ALEMBIC_INI",
    "CONSUMED",
    "DEAD",
    "JOB_LEASE",
    "OUTBOX",
    "TABLES",
    "FakePresigner",
    "database_fixtures",
]

ALEMBIC_INI = Path(__file__).resolve().parents[1] / "alembic.ini"


def database_fixtures(db_name: str, extra_inis: list[Path] | None = None, extra_tables: list[str] | None = None) -> Any:
    return _database_fixtures(db_name, [ALEMBIC_INI, *(extra_inis or [])], [*TABLES, *(extra_tables or [])])


@dataclass(frozen=True)
class FakePresigned:
    url: str
    headers: dict[str, str]
    expires_at: datetime


@dataclass(frozen=True)
class FakeStored:
    size: int


@dataclass
class FakePresigner:
    """Records what it was asked to sign and to delete; signs nothing. `objects` maps a key to its size."""

    puts: list[tuple[str, str, int, int | None]] = field(default_factory=list)
    deleted: list[str] = field(default_factory=list)
    objects: dict[str, int] = field(default_factory=dict)

    def presign_put(
        self, key: str, content_type: str, max_bytes: int, *, size_bytes: int | None = None
    ) -> FakePresigned:
        self.puts.append((key, content_type, max_bytes, size_bytes))
        return FakePresigned(
            url=f"fake://bucket/{key}?method=PUT",
            headers={"content-type": content_type},
            expires_at=datetime.now(UTC) + timedelta(minutes=5),
        )

    def head(self, key: str) -> FakeStored | None:
        size = self.objects.get(key)
        return None if size is None else FakeStored(size)

    def delete(self, keys: Sequence[str]) -> int:
        self.deleted.extend(keys)
        for k in keys:
            self.objects.pop(k, None)
        return len(keys)

    def list_keys(self, prefix: str) -> list[str]:
        return sorted(k for k in self.objects if k.startswith(prefix))


def device() -> str:
    return uuid.uuid4().hex
