from collections.abc import Iterator

import pytest
from sqlalchemy.orm import Session, sessionmaker

from yantra_quality.testing import database_fixtures

engine, factory, clean_tables = database_fixtures("yantra_quality_test")


@pytest.fixture
def session(factory: sessionmaker[Session]) -> Iterator[Session]:
    s = factory()
    yield s
    s.close()
