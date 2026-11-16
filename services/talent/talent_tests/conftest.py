"""Tests run against a real PostgreSQL (row locks and partial unique indexes need one).
Start it with: docker compose -f deployment/local/compose.yaml up -d postgres
The test database is created fresh for the session and migrated with Alembic, so the migration is tested too."""

import uuid
from collections.abc import Iterator

import pytest
from sqlalchemy.orm import Session, sessionmaker

from yantra_talent.models import Listing
from yantra_talent.testing import database_fixtures, make_listing, reset_policies

engine, factory, clean_tables = database_fixtures("yantra_talent_test")


@pytest.fixture
def session(factory: sessionmaker[Session]) -> Iterator[Session]:
    s = factory()
    yield s
    s.rollback()
    reset_policies(s)
    s.close()


@pytest.fixture
def listing(session: Session) -> Listing:
    return make_listing(session)


@pytest.fixture
def worker() -> uuid.UUID:
    return uuid.uuid4()
