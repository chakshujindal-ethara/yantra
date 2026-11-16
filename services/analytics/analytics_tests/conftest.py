"""Tests run against a real PostgreSQL; the database is created fresh and migrated with Alembic."""

import uuid
from collections.abc import Iterator
from datetime import UTC, datetime

import pytest
from sqlalchemy.orm import Session, sessionmaker

from yantra_analytics.testing import Warehouse, database_fixtures

engine, factory, clean_tables = database_fixtures("yantra_analytics_test")

# Wednesday 4 Nov 2026, 10:00 IST
NOW = datetime(2026, 11, 4, 4, 30, tzinfo=UTC)


@pytest.fixture
def session(factory: sessionmaker[Session]) -> Iterator[Session]:
    s = factory()
    yield s
    s.close()


@pytest.fixture
def wh(session: Session) -> Warehouse:
    return Warehouse(session)


def ids(n: int) -> list[uuid.UUID]:
    return [uuid.uuid4() for _ in range(n)]
