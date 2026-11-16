"""A worker launching a paper: on the engine, on the cohort of their attempt number, with a one-time URL back; the
brief; resuming; the refusals; two workers racing to open a new cohort."""

import threading
import uuid

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from yantra_assess.engine import EngineError, EngineUnavailable
from yantra_assess.engine.fake import FakeEngine
from yantra_assess.models import Cohort, Paper, Sitting, WorkerLink
from yantra_assess.service import EngineDown, admin_launch, brief, launch, launch_by_exam, my_sittings
from yantra_assess.testing import SETTINGS, launched, make_paper, sit
from yantra_common.errors import Conflict, Forbidden, Invalid, NotFound


def test_a_first_launch_puts_the_worker_on_cohort_one_and_returns_a_launch_url(session, fake):
    paper = make_paper(session, fake)
    worker = uuid.uuid4()
    ticket, sitting = launch(session, fake, SETTINGS, paper.id, worker, "w@yantra.local", True, "Asha")
    session.commit()
    assert ticket.launch_url.startswith("http://exam.test/yantra/launch#ticket=")
    assert sitting.status == "assigned" and sitting.attempt_no == 1 and sitting.engine_attempt_id
    cohort = session.get(Cohort, sitting.cohort_id)
    assert cohort.engine_assessment_id == paper.engine_base_id and cohort.state == "open"
    assert fake.calls.count("launch") == 1
    link = session.get(WorkerLink, worker)
    assert link.engine_user_id and link.engine_applicant_id


def test_a_second_worker_joins_the_open_cohort_without_launching_it_again(session, fake):
    paper = make_paper(session, fake)
    a, b = launched(session, fake, paper), launched(session, fake, paper)
    assert a.cohort_id == b.cohort_id and fake.calls.count("launch") == 1


def test_an_open_sitting_is_resumed_and_a_submitted_one_waits(session, fake):
    paper = make_paper(session, fake, release_policy="manual")
    worker = uuid.uuid4()
    first = launched(session, fake, paper, worker)
    again = launched(session, fake, paper, worker)
    assert again.id == first.id
    fake.begin(first.engine_attempt_id)
    fake.submit(first.engine_attempt_id)
    from yantra_assess.service import sync

    sync(session, fake)
    session.commit()
    with pytest.raises(Conflict) as e:
        launch(session, fake, SETTINGS, paper.id, worker)
    assert e.value.code == "result_pending"


def test_a_failed_attempt_opens_attempt_two_on_a_fresh_cohort_and_then_attempts_run_out(session, fake):
    paper = make_paper(session, fake, max_attempts=2)
    worker = uuid.uuid4()
    first = sit(session, fake, paper, worker, result="fail", score=20)
    second = sit(session, fake, paper, worker, result="fail", score=30)
    assert (first.attempt_no, second.attempt_no) == (1, 2) and first.cohort_id != second.cohort_id
    assert "clone" in fake.calls
    with pytest.raises(Conflict) as e:
        launch(session, fake, SETTINGS, paper.id, worker)
    assert e.value.code == "attempts_exhausted"


def test_a_certified_worker_and_the_papers_author_are_refused(session, fake):
    author = uuid.uuid4()
    paper = make_paper(session, fake, created_by=author)
    with pytest.raises(Forbidden) as e:
        launch(session, fake, SETTINGS, paper.id, author)
    assert e.value.code == "paper_author"
    worker = uuid.uuid4()
    sit(session, fake, paper, worker)
    with pytest.raises(Conflict) as e:
        launch(session, fake, SETTINGS, paper.id, worker)
    assert e.value.code == "already_certified"


def test_a_draft_paper_is_absent_and_a_retired_one_says_so(session, fake):
    draft = make_paper(session, fake, published=False)
    with pytest.raises(NotFound):
        launch(session, fake, SETTINGS, draft.id, uuid.uuid4())
    with pytest.raises(NotFound):
        brief(session, draft.id, uuid.uuid4())
    retired = make_paper(session, fake, gate="old")
    retired.status = "retired"
    session.commit()
    with pytest.raises(Conflict) as e:
        launch(session, fake, SETTINGS, retired.id, uuid.uuid4())
    assert e.value.code == "paper_retired"
    with pytest.raises(NotFound):
        launch(session, fake, SETTINGS, uuid.uuid4(), uuid.uuid4())


def test_a_quiz_era_live_sitting_cannot_be_resumed(session, fake):
    paper = make_paper(session, fake)
    worker = uuid.uuid4()
    session.add(Sitting(paper_id=paper.id, worker_id=worker, status="live"))
    session.commit()
    with pytest.raises(Conflict) as e:
        launch(session, fake, SETTINGS, paper.id, worker)
    assert e.value.code == "paper_retired"


def test_a_resumed_sitting_learns_its_engine_attempt_when_it_had_none(session, fake):
    paper = make_paper(session, fake)
    worker = uuid.uuid4()
    sitting = launched(session, fake, paper, worker)
    sitting.engine_attempt_id = None
    session.commit()
    _, again = launch(session, fake, SETTINGS, paper.id, worker)
    assert again.id == sitting.id and again.engine_attempt_id is not None


def test_the_brief_shows_the_snapshot_attempts_and_the_current_sitting(session, fake):
    paper = make_paper(session, fake)
    worker = uuid.uuid4()
    b = brief(session, paper.id, worker)
    assert (b.attempts_used, b.attempts_left, b.certified, b.current) == (0, 2, False, None)
    sitting = sit(session, fake, paper, worker, result="fail", score=10)
    b = brief(session, paper.id, worker)
    assert (b.attempts_used, b.attempts_left, b.current.id) == (1, 1, sitting.id)
    open_one = launched(session, fake, paper, worker)
    assert brief(session, paper.id, worker).current.id == open_one.id
    assert [s.id for s, _ in my_sittings(session, worker)] == [open_one.id, sitting.id]


def test_launch_by_exam_and_admin_launch_mint_tickets(session, fake):
    worker = uuid.uuid4()
    ticket = launch_by_exam(fake, SETTINGS, worker, "exam-token-1", "w@yantra.local", True, "W")
    assert ticket.launch_url.startswith("http://exam.test") and ticket.evaluator_id is None
    with pytest.raises(Invalid):
        launch_by_exam(fake, SETTINGS, worker, "")
    staff = admin_launch(fake, SETTINGS, uuid.uuid4(), "ops@yantra.local", True, "Ops", "/assessments/4")
    assert staff.launch_url
    for bad in ("assessments", "//evil.example/x"):
        with pytest.raises(Invalid):
            admin_launch(fake, SETTINGS, uuid.uuid4(), "", False, "", bad)


def test_two_workers_needing_a_new_cohort_at_once_make_one(factory: sessionmaker[Session]):
    fake = FakeEngine()
    with factory() as s:
        paper = make_paper(s, fake, max_attempts=3)
        workers = [uuid.uuid4(), uuid.uuid4()]
        for w in workers:  # each fails attempt one, so both need attempt two
            sit(s, fake, paper, w, result="fail", score=0)
        paper_id = paper.id
    barrier = threading.Barrier(2)
    errors: list[BaseException] = []

    def go(worker: uuid.UUID) -> None:
        try:
            with factory() as s:
                barrier.wait()
                launch(s, fake, SETTINGS, paper_id, worker)
                s.commit()
        except BaseException as e:  # noqa: BLE001 - the test reports any thread failure
            errors.append(e)

    threads = [threading.Thread(target=go, args=(w,)) for w in workers]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert not errors
    with factory() as s:
        cohorts = s.scalars(select(Cohort).where(Cohort.paper_id == paper_id, Cohort.attempt_no == 2)).all()
        assert len(cohorts) == 1
        same = s.get(Paper, paper_id)
        assert same is not None and same.generation == 1


def test_a_cohort_the_engine_closed_after_releasing_everyone_is_followed_by_a_new_one(session, fake):
    paper = make_paper(session, fake)  # auto_objective: the sync releases, and v2 then closes the whole cohort
    first = sit(session, fake, paper, uuid.uuid4())
    closed = session.get(Cohort, first.cohort_id)
    assert fake._assessments[closed.engine_assessment_id].state == "done"
    _, second = launch(session, fake, SETTINGS, paper.id, uuid.uuid4())
    session.commit()
    assert second.attempt_no == 1 and second.cohort_id != first.cohort_id
    assert session.get(Cohort, first.cohort_id).state == "closed" and "clone" in fake.calls


def test_an_engine_refusal_or_outage_on_assign_is_said_as_yantras(session, fake, monkeypatch):
    paper = make_paper(session, fake)
    for error, code in (
        (EngineError("nothing_assigned", "a portal account", status=422), "engine_refused"),
        (EngineUnavailable("down"), "engine_unavailable"),
    ):

        def refuse(assessment_id: int, user_ids: list[int], error: Exception = error) -> None:
            raise error

        monkeypatch.setattr(fake, "assign", refuse)
        with pytest.raises((Conflict, EngineDown)) as e:
            launch(session, fake, SETTINGS, paper.id, uuid.uuid4())
        assert e.value.code == code
        session.rollback()
