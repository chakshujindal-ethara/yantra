"""Tests run against a real PostgreSQL (SKIP LOCKED and partial unique indexes need one).
Start it with: docker compose -f deployment/local/compose.yaml up -d postgres
The test database is created fresh for the session and migrated with Alembic, so the migrations are tested too."""

from collections.abc import Iterator

import pytest
from sqlalchemy.orm import Session, sessionmaker

from yantra_market.models import ClientProject, WorkBatch
from yantra_market.testing import database_fixtures, make_batch, make_project

engine, factory, clean_tables = database_fixtures("yantra_market_test")


@pytest.fixture
def session(factory: sessionmaker[Session]) -> Iterator[Session]:
    s = factory()
    yield s
    s.close()


@pytest.fixture
def project(session: Session) -> ClientProject:
    return make_project(session)


@pytest.fixture
def batch(session: Session, project: ClientProject) -> WorkBatch:
    return make_batch(session, project)
