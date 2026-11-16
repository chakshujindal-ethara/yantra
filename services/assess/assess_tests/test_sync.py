"""The sync: the engine's attempts become Yantra's sittings, a released result becomes a certification (or a fail),
`auto_objective` papers release their clean objective attempts, stale assignments are withdrawn, snapshots refresh."""

import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest
from sqlalchemy import select

from yantra_assess.engine import EngineError, EngineUnavailable
from yantra_assess.models import OUTBOX, Certification, Cohort, EngineCursor, Sitting, WorkerLink
from yantra_assess.service import OVERLAP, sync
from yantra_assess.testing import launched, make_paper, sit


def events(session):
    return session.execute(select(OUTBOX.c.type, OUTBOX.c.payload).order_by(OUTBOX.c.occurred_at)).all()


def test_a_clean_objective_pass_is_released_by_the_adapter_and_certifies(session, fake):
    paper = make_paper(session, fake, release_policy="auto_objective")
    worker = uuid.uuid4()
    sitting = sit(session, fake, paper, worker, score=87.5)
    assert sitting.status == "passed" and sitting.released and sitting.score == Decimal("0.8750")
    assert fake.attempt(sitting.engine_attempt_id).released
    cert = session.get(Certification, (worker, paper.gate))
    assert cert.paper_id == paper.id and cert.score == Decimal("0.8750")
    ((kind, payload),) = events(session)
    assert kind == "assess.certified.v1" and payload["gate"] == paper.gate and payload["score"] == "0.8750"


def test_a_released_fail_counts_down_the_attempts(session, fake):
    paper = make_paper(session, fake, max_attempts=2)
    sitting = sit(session, fake, paper, uuid.uuid4(), result="fail", score=25)
    assert sitting.status == "failed" and sitting.score == Decimal("0.2500")
    ((kind, payload),) = events(session)
    assert kind == "assess.failed.v1" and payload["attempts_left"] == 1


def test_the_states_before_the_result_follow_the_engine(session, fake):
    paper = make_paper(session, fake)
    sitting = launched(session, fake, paper)
    sync(session, fake)
    assert session.get(Sitting, sitting.id).status == "assigned"
    fake.begin(sitting.engine_attempt_id)
    assert sync(session, fake) == 1
    s = session.get(Sitting, sitting.id)
    assert s.status == "in_progress" and s.deadline and s.started_at and s.engine_state == "in_progress"
    fake.submit(sitting.engine_attempt_id, result="pending")
    sync(session, fake)
    s = session.get(Sitting, sitting.id)
    assert (s.status, s.held_reason) == ("awaiting_result", "llm_scoring")
    assert events(session) == []


@pytest.mark.parametrize(
    "submitted, reason",
    [
        ({"integrity_alert": True}, "integrity_review"),
        ({"violation_limit_breached": True}, "violation_limit"),
        ({"subjective_max": 10}, "subjective_answers"),
    ],
)
def test_auto_objective_holds_what_a_person_must_look_at(session, fake, submitted, reason):
    paper = make_paper(session, fake, release_policy="auto_objective")
    sitting = sit(session, fake, paper, uuid.uuid4(), **submitted)
    assert (sitting.status, sitting.held_reason, sitting.released) == ("awaiting_result", reason, False)
    assert not fake.attempt(sitting.engine_attempt_id).released and events(session) == []


def test_a_manual_paper_waits_for_release_and_never_certifies_before_it(session, fake):
    paper = make_paper(session, fake, release_policy="manual")
    sitting = sit(session, fake, paper, uuid.uuid4())
    assert (sitting.status, sitting.held_reason) == ("awaiting_result", "needs_release")
    assert session.scalar(select(Certification)) is None


def test_a_refused_auto_release_holds_and_an_already_released_one_counts(session, fake):
    paper = make_paper(session, fake, release_policy="auto_objective")
    sitting = launched(session, fake, paper)
    fake.begin(sitting.engine_attempt_id)
    fake.submit(sitting.engine_attempt_id)
    original = fake.release

    def refuse(*a, **k):
        raise EngineError("forbidden", "no")

    fake.release = refuse
    sync(session, fake)
    assert session.get(Sitting, sitting.id).held_reason == "release_refused"

    def already(*a, **k):
        raise EngineError("nothing_to_release", "done")

    fake.release = already
    session.get(EngineCursor, "attempts").since = None
    sync(session, fake)
    assert session.get(Sitting, sitting.id).status == "passed"
    fake.release = original


def test_resyncing_is_idempotent_and_unknown_attempts_are_ignored(session, fake):
    paper = make_paper(session, fake)
    sitting = sit(session, fake, paper, uuid.uuid4())
    stranger = fake.add_assessment()
    fake.assign(stranger, [999])
    fake.launch(stranger)
    session.get(EngineCursor, "attempts").since = None
    assert sync(session, fake) == 0
    assert len(events(session)) == 1 and session.get(Sitting, sitting.id).status == "passed"


def test_the_cursor_reads_a_little_behind_the_engines_clock(session, fake):
    now = datetime(2026, 11, 12, 10, 0, tzinfo=UTC)
    fake.now = lambda: now
    sync(session, fake)
    assert session.get(EngineCursor, "attempts").since == now - OVERLAP


def test_an_engine_outage_raises_for_the_scheduler(session, fake):
    fake.fail_next = EngineUnavailable("down")
    with pytest.raises(EngineUnavailable):
        sync(session, fake)


def test_an_assignment_never_started_is_withdrawn_after_its_ttl(session, fake):
    paper = make_paper(session, fake)
    sitting = launched(session, fake, paper)
    later = datetime.now(UTC) + timedelta(days=paper.assigned_ttl_days + 1)
    sync(session, fake, now=later)
    assert session.get(Sitting, sitting.id).status == "void" and "unassign" in fake.calls
    sync(session, fake, now=datetime.now(UTC))  # a void sitting is not an attempt and is not moved again
    assert session.get(Sitting, sitting.id).status == "void"


def test_a_refused_withdrawal_leaves_the_sitting_and_an_unknown_link_still_voids(session, fake):
    paper = make_paper(session, fake)
    kept = launched(session, fake, paper)
    later = datetime.now(UTC) + timedelta(days=paper.assigned_ttl_days + 1)

    def refuse(*a, **k):
        raise EngineError("blocked", "started")

    fake.unassign = refuse
    sync(session, fake, now=later)
    assert session.get(Sitting, kept.id).status == "assigned"
    session.delete(session.get(WorkerLink, kept.worker_id))
    session.flush()
    sync(session, fake, now=later)
    assert session.get(Sitting, kept.id).status == "void"


def test_snapshots_refresh_and_a_cohort_the_engine_closed_voids_its_unstarted_sittings(session, fake):
    paper = make_paper(session, fake)
    sitting = launched(session, fake, paper)
    fake._assessments[paper.engine_base_id].duration_minutes = 45
    cohort = session.get(Cohort, sitting.cohort_id)
    fake._assessments[cohort.engine_assessment_id].state = "done"
    later = datetime.now(UTC) + timedelta(minutes=6)
    sync(session, fake, now=later)
    assert session.get(type(paper), paper.id).snapshot["duration_minutes"] == 45
    assert session.get(Cohort, cohort.id).state == "closed"
    assert session.get(Sitting, sitting.id).status == "void"


def test_the_first_pass_of_a_gate_keeps_its_certification(session, fake):
    first = make_paper(session, fake, gate="g")
    second = make_paper(session, fake, gate="g")
    worker = uuid.uuid4()
    a, b = launched(session, fake, first, worker), launched(session, fake, second, worker)  # both before a result
    for s in (a, b):
        fake.begin(s.engine_attempt_id)
        fake.submit(s.engine_attempt_id, score=80)
    sync(session, fake)
    session.commit()
    certs = session.scalars(select(Certification).where(Certification.worker_id == worker)).all()
    assert len(certs) == 1
    assert [k for k, _ in events(session)] == ["assess.certified.v1", "assess.certified.v1"]
