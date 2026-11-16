"""Tests run against a real PostgreSQL (partial unique indexes and ON CONFLICT need one).
The test database is created fresh for the session and migrated with Alembic, so the migration is tested too."""

import uuid
from collections.abc import Iterator
from datetime import UTC, datetime

import pytest
from sqlalchemy.orm import Session, sessionmaker

from yantra_tracker.testing import database_fixtures

engine, factory, clean_tables = database_fixtures("yantra_tracker_test")

# A Wednesday, 10:00 IST: the IST week runs from Monday 2 Nov 00:00 IST.
NOW = datetime(2026, 11, 4, 4, 30, tzinfo=UTC)


@pytest.fixture
def session(factory: sessionmaker[Session]) -> Iterator[Session]:
    s = factory()
    yield s
    s.close()


@pytest.fixture
def worker() -> uuid.UUID:
    return uuid.uuid4()
