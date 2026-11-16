"""Test helpers for the assess module and for every deployable that mounts it: a fake engine, a published paper over
it, and a worker who has launched it (and, when asked, finished it)."""

import uuid
from pathlib import Path
from typing import Any

from sqlalchemy.orm import Session

from yantra_assess.config import AssessSettings
from yantra_assess.engine import QuickQuestion
from yantra_assess.engine.fake import FakeEngine
from yantra_assess.models import TABLES, Paper, Sitting
from yantra_assess.service import create_paper, launch, publish_paper, sync
from yantra_common.testing import database_fixtures as _database_fixtures

ALEMBIC_INI = Path(__file__).resolve().parents[1] / "alembic.ini"
SETTINGS = AssessSettings(engine="fake", return_url="http://app.test")

QUESTIONS = [
    QuickQuestion(id="q1", prompt="2 + 2?", kind="single", options=["3", "4"], answer="4"),
    QuickQuestion(id="q2", prompt="Even numbers?", kind="multi", options=["1", "2", "4"], answer=["2", "4"]),
]


def database_fixtures(db_name: str) -> tuple[Any, Any, Any]:
    return _database_fixtures(db_name, [ALEMBIC_INI], TABLES)


def quick_source(duration_minutes: int = 30, pass_mark: str = "0.6") -> dict[str, Any]:
    return {"kind": "quick", "duration_minutes": duration_minutes, "pass_mark": pass_mark, "questions": QUESTIONS}


def make_paper(
    session: Session,
    engine: FakeEngine,
    gate: str = "hindi-translation",
    max_attempts: int = 2,
    release_policy: str = "auto_objective",
    published: bool = True,
    created_by: uuid.UUID | None = None,
) -> Paper:
    paper = create_paper(
        session,
        engine,
        gate=gate,
        title=f"{gate} paper",
        description="two questions",
        max_attempts=max_attempts,
        source=quick_source(),
        release_policy=release_policy,
        created_by=created_by,
    )
    if published:
        publish_paper(session, engine, paper.id)
    session.commit()
    return paper


def launched(session: Session, engine: FakeEngine, paper: Paper, worker_id: uuid.UUID | None = None) -> Sitting:
    """A worker on the paper's cohort, their exam not started yet."""
    _, sitting = launch(session, engine, SETTINGS, paper.id, worker_id or uuid.uuid4(), "w@yantra.local", True, "W")
    session.commit()
    return sitting


def sit(
    session: Session,
    engine: FakeEngine,
    paper: Paper,
    worker_id: uuid.UUID,
    result: str = "pass",
    score: float = 100.0,
    **submitted: Any,
) -> Sitting:
    """Launches, sits and submits in the fake engine, then runs one sync pass."""
    sitting = launched(session, engine, paper, worker_id)
    assert sitting.engine_attempt_id is not None
    engine.begin(sitting.engine_attempt_id)
    engine.submit(sitting.engine_attempt_id, result=result, score=score, **submitted)
    sync(session, engine)
    session.commit()
    session.refresh(sitting)
    return sitting
