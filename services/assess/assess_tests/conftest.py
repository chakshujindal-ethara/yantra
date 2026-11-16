from collections.abc import Iterator

import pytest
from sqlalchemy.orm import Session, sessionmaker

from yantra_assess.engine.fake import FakeEngine
from yantra_assess.testing import database_fixtures

engine, factory, clean_tables = database_fixtures("yantra_assess_test")


@pytest.fixture
def session(factory: sessionmaker[Session]) -> Iterator[Session]:
    s = factory()
    yield s
    s.close()


@pytest.fixture
def fake() -> FakeEngine:
    return FakeEngine(app_url="http://exam.test")
