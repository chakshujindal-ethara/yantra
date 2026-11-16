"""Papers over an engine assessment: linking one built in the Assessment admin or writing a quick one, publishing
behind the engine's launch gates, the stats, releasing and rotating."""

import uuid
from decimal import Decimal

import pytest
from sqlalchemy import select

from yantra_assess.engine import EngineError, Gate, QuickQuestion
from yantra_assess.engine.fake import FakeEngine
from yantra_assess.models import Cohort, Paper
from yantra_assess.service import (
    EngineDown,
    cohorts_of,
    create_paper,
    engine_assessments,
    get_paper,
    launch_problems,
    list_papers,
    paper_sittings,
    publish_paper,
    release,
    rotate,
)
from yantra_assess.testing import QUESTIONS, launched, make_paper, quick_source, sit
from yantra_common.errors import Conflict, Invalid, NotFound


def paper_kwargs(**over):
    base = dict(gate="hindi", title="Hindi", description="", max_attempts=2, source=quick_source())
    base.update(over)
    return base


def test_a_quick_paper_is_written_into_the_engine_and_snapshotted(session, fake):
    paper = create_paper(session, fake, **paper_kwargs(release_policy="auto_objective"), created_by=uuid.uuid4())
    session.commit()
    assert paper.status == "draft" and paper.engine == "fake" and paper.engine_base_id is not None
    snap = paper.snapshot
    assert snap["question_count"] == 2 and snap["question_types"] == ["mcq", "msq"]
    assert snap["duration_minutes"] == 30 and snap["pass_threshold"] == 60.0
    assert "create_quick" in fake.calls


def test_a_paper_links_a_draft_built_in_the_assessment_admin(session, fake):
    aid = fake.add_assessment("SOP paper", types=4)
    paper = create_paper(session, fake, **paper_kwargs(source={"kind": "assessment", "assessment_id": aid}))
    session.commit()
    assert paper.engine_base_id == aid and "transcription" in paper.snapshot["question_types"]
    with pytest.raises(Conflict) as e:
        create_paper(session, fake, **paper_kwargs(source={"kind": "assessment", "assessment_id": aid}))
    assert e.value.code == "assessment_in_use"
    session.rollback()
    launched_id = fake.add_assessment()
    fake._assessments[launched_id].state = "in_progress"
    with pytest.raises(Conflict) as e:
        create_paper(session, fake, **paper_kwargs(source={"kind": "assessment", "assessment_id": launched_id}))
    assert e.value.code == "assessment_not_draft"


@pytest.mark.parametrize(
    "over, code",
    [
        ({"max_attempts": 0}, "invalid_max_attempts"),
        ({"release_policy": "whenever"}, "invalid_policy"),
        ({"assigned_ttl_days": 0}, "invalid_ttl"),
        ({"source": {"kind": "magic"}}, "invalid_source"),
        ({"source": quick_source(duration_minutes=1)}, "invalid_duration"),
        ({"source": quick_source(pass_mark="0")}, "invalid_pass_mark"),
        ({"source": {**quick_source(), "questions": []}}, "invalid_questions"),
        ({"source": {**quick_source(), "questions": [QUESTIONS[0], QUESTIONS[0]]}}, "invalid_question_id"),
        (
            {"source": {**quick_source(), "questions": [QuickQuestion("a", "p", "single", ["x"], "x")]}},
            "invalid_options",
        ),
        (
            {"source": {**quick_source(), "questions": [QuickQuestion("a", "p", "single", ["x", "y"], "z")]}},
            "invalid_answer",
        ),
        (
            {"source": {**quick_source(), "questions": [QuickQuestion("a", "p", "multi", ["x", "y"], [])]}},
            "invalid_answer",
        ),
    ],
)
def test_a_paper_refuses_what_it_cannot_run(session, fake, over, code):
    with pytest.raises(Invalid) as e:
        create_paper(session, fake, **paper_kwargs(**over))
    assert e.value.code == code


def test_an_engine_outage_is_a_503_and_a_refusal_keeps_the_engines_reason(session, fake):
    fake.drop()
    with pytest.raises(EngineDown):
        create_paper(session, fake, **paper_kwargs())
    with pytest.raises(Conflict) as e:
        create_paper(session, fake, **paper_kwargs(source={"kind": "assessment", "assessment_id": 999}))
    assert e.value.code == "engine_refused" and e.value.context["engine_code"] == "not_found"


def test_publishing_checks_every_launch_gate_but_the_roster(session, fake):
    paper = create_paper(session, fake, **paper_kwargs())
    fake._assessments[paper.engine_base_id].duration_minutes = 1
    with pytest.raises(Invalid) as e:
        publish_paper(session, fake, paper.id)
    assert e.value.code == "launch_blocked"
    assert [g["code"] for g in e.value.context["gates"]] == ["duration"]
    fake._assessments[paper.engine_base_id].duration_minutes = 30
    by = uuid.uuid4()
    published = publish_paper(session, fake, paper.id, by)
    assert published.status == "published" and published.published_by == by and published.published_at
    with pytest.raises(Conflict) as e:
        publish_paper(session, fake, paper.id)
    assert e.value.code == "already_published"


def test_launch_problems_ignore_the_roster_gate():
    gates = [
        Gate("candidates", "At least one candidate assigned", False, "nobody"),
        Gate("answer_keys", "Answer keys", False),
        Gate("duration", "Duration", True),
    ]
    assert [g.code for g in launch_problems(gates)] == ["answer_keys"]


def test_listing_and_reading_papers_carry_stats(session, fake):
    paper = make_paper(session, fake)
    worker = uuid.uuid4()
    sit(session, fake, paper, worker, result="fail", score=10)
    sit(session, fake, paper, worker, result="pass", score=100)
    other = make_paper(session, fake, gate="tamil")
    rows = dict((p.id, s) for p, s in list_papers(session))
    assert rows[paper.id] == {
        "total": 2,
        "passed": 1,
        "pass_rate": Decimal("0.5000"),
        "awaiting_result": 0,
        "held": 0,
    }
    assert rows[other.id]["pass_rate"] is None
    assert len(paper_sittings(session, paper.id)) == 2
    assert [c.attempt_no for c in cohorts_of(session, paper.id)] == [1, 2]
    with pytest.raises(NotFound):
        get_paper(session, uuid.uuid4())
    with pytest.raises(NotFound):
        paper_sittings(session, uuid.uuid4())


def test_engine_assessments_lists_the_engines_drafts(fake):
    fake.add_assessment("one")
    assert [a.name for a in engine_assessments(fake)] == ["one"]


def test_manual_release_releases_in_the_engine_and_the_sync_certifies(session, fake):
    from yantra_assess.service import sync

    paper = make_paper(session, fake, release_policy="manual")
    worker = uuid.uuid4()
    sitting = sit(session, fake, paper, worker)
    assert sitting.status == "awaiting_result" and sitting.held_reason == "needs_release"
    assert release(session, fake, paper.id, [sitting.id]) == 1
    sync(session, fake)
    session.commit()
    session.refresh(sitting)
    assert sitting.status == "passed" and sitting.released
    with pytest.raises(Conflict) as e:
        release(session, fake, paper.id)
    assert e.value.code == "nothing_to_release"


def test_release_without_ids_takes_every_decided_sitting_of_the_paper(session, fake):
    paper = make_paper(session, fake, release_policy="manual")
    sit(session, fake, paper, uuid.uuid4())
    sit(session, fake, paper, uuid.uuid4(), result="fail", score=0)
    assert release(session, fake, paper.id) == 2


def test_rotate_closes_running_cohorts_and_the_next_launch_opens_a_fresh_copy(session, fake):
    paper = make_paper(session, fake)
    first = launched(session, fake, paper)
    rotated = rotate(session, fake, paper.id)
    session.commit()
    assert rotated.generation == 2 and "close" in fake.calls
    assert {c.state for c in cohorts_of(session, paper.id)} == {"closed"}
    second = launched(session, fake, paper)
    cohorts = cohorts_of(session, paper.id)
    assert [(c.generation, c.state) for c in cohorts] == [(1, "closed"), (2, "open")]
    assert cohorts[1].engine_assessment_id != paper.engine_base_id
    assert first.cohort_id != second.cohort_id
    with pytest.raises(NotFound):
        rotate(session, fake, uuid.uuid4())


def test_rotate_closes_a_draft_cohort_without_asking_the_engine(session, fake):
    paper = make_paper(session, fake)
    session.add(Cohort(paper_id=paper.id, attempt_no=1, generation=1, engine_assessment_id=12345, state="draft"))
    session.commit()
    rotate(session, fake, paper.id)
    assert "close" not in fake.calls


def test_an_engine_refusal_on_rotate_rolls_nothing_forward(session, fake: FakeEngine):
    paper = make_paper(session, fake)
    launched(session, fake, paper)
    fake.fail_next = EngineError("assessment_closed", "closed already")
    with pytest.raises(Conflict):
        rotate(session, fake, paper.id)
    session.rollback()
    assert session.scalar(select(Paper.generation).where(Paper.id == paper.id)) == 1
