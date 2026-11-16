import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from yantra_common.errors import Conflict, Forbidden, Invalid, NotFound
from yantra_quality.models import OUTBOX, Review, ReviewTask, RubricFlag
from yantra_quality.service import (
    answer_flag,
    claim_review,
    list_tasks,
    on_unit_submitted,
    parse_batch_ids,
    record_review,
    release_expired_reviews,
    sampled_for_audit,
    stats,
)
from yantra_quality.testing import open_task, submitted_envelope

BATCH = uuid.uuid4()


def unsampled_unit() -> uuid.UUID:
    while True:
        u = uuid.uuid4()
        if not sampled_for_audit(u):
            return u


def sampled_unit() -> uuid.UUID:
    while True:
        u = uuid.uuid4()
        if sampled_for_audit(u):
            return u


def events(session):
    return session.execute(select(OUTBOX.c.type, OUTBOX.c.payload).order_by(OUTBOX.c.occurred_at)).all()


def test_a_submitted_unit_opens_one_task_and_the_sample_is_deterministic(session):
    author = uuid.uuid4()
    env = submitted_envelope(author, BATCH, sampled_unit())
    on_unit_submitted(session, env)
    session.commit()
    task = session.scalar(select(ReviewTask))
    assert task.status == "pending" and task.worker_id == author and task.sampled_for_audit is True


def test_reviewer_never_draws_own_work_and_holds_one_task(session):
    a, b = uuid.uuid4(), uuid.uuid4()
    open_task(session, a, BATCH, unsampled_unit())
    with pytest.raises(NotFound):
        claim_review(session, a)
    session.rollback()
    task = claim_review(session, b)
    session.commit()
    assert task.status == "claimed" and task.reviewer_id == b and task.claim_expires_at is not None
    open_task(session, a, BATCH, unsampled_unit())
    with pytest.raises(Conflict) as e:
        claim_review(session, b)
    assert e.value.code == "one_live_review"


def test_a_claim_narrowed_to_one_batch_skips_older_work_of_other_batches(session):
    author, reviewer, mine = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    open_task(session, author, BATCH, unsampled_unit())  # older, another batch
    unit = open_task(session, author, mine, unsampled_unit())
    task = claim_review(session, reviewer, batch_id=mine)
    session.commit()
    assert task.unit_id == unit and task.batch_id == mine
    with pytest.raises(NotFound):
        claim_review(session, uuid.uuid4(), batch_id=mine)


def test_accept_outside_the_sample_is_canonical_at_once(session):
    author, reviewer = uuid.uuid4(), uuid.uuid4()
    unit = open_task(session, author, BATCH, unsampled_unit())
    task = claim_review(session, reviewer)
    session.commit()
    record_review(session, task.id, reviewer, "accept", feedback={"score": 5})
    session.commit()
    session.refresh(task)
    assert task.status == "canonical" and task.canonical_verdict == "accept"
    last = events(session)[-1]
    assert last.type == "quality.verdict.accepted.v1"
    assert last.payload == {
        "unit_id": str(unit),
        "batch_id": str(BATCH),
        "submission_id": str(task.submission_id),
        "worker_id": str(author),
        "reviewer_id": str(reviewer),
        "auditor_id": None,
        "rubric_version": "v1",
    }


def test_reject_needs_a_reason_code_and_client_caused_codes_are_billable(session):
    author, reviewer = uuid.uuid4(), uuid.uuid4()
    open_task(session, author, BATCH, unsampled_unit())
    task = claim_review(session, reviewer)
    session.commit()
    with pytest.raises(Invalid):
        record_review(session, task.id, reviewer, "reject")
    with pytest.raises(Invalid):
        record_review(session, task.id, reviewer, "needs_edits", reason_code="made_up")
    with pytest.raises(Invalid):
        record_review(session, task.id, reviewer, "maybe")
    record_review(session, task.id, reviewer, "needs_edits", reason_code="client_glossary_change", note="term changed")
    session.commit()
    last = events(session)[-1]
    assert last.type == "quality.verdict.rejected.v1"
    assert (last.payload["verdict"], last.payload["reason_code"], last.payload["billable"]) == (
        "needs_edits",
        "client_glossary_change",
        True,
    )
    review = session.scalar(select(Review))
    assert review.kind == "review" and review.note == "term changed"


def test_a_sampled_accept_waits_for_the_auditor_whose_verdict_wins(session):
    author, reviewer, auditor = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    open_task(session, author, BATCH, sampled_unit())
    task = claim_review(session, reviewer)
    session.commit()
    record_review(session, task.id, reviewer, "accept")
    session.commit()
    session.refresh(task)
    assert task.status == "audit_pending" and events(session) == []
    with pytest.raises(NotFound):  # the reviewer cannot audit their own review
        claim_review(session, reviewer, kind="audit")
    session.rollback()
    with pytest.raises(NotFound):  # and the author cannot audit their own work
        claim_review(session, author, kind="audit")
    session.rollback()
    audit = claim_review(session, auditor, kind="audit")
    session.commit()
    assert audit.id == task.id and audit.status == "audit_claimed" and audit.auditor_id == auditor
    record_review(session, task.id, auditor, "reject", reason_code="low_quality")
    session.commit()
    session.refresh(task)
    assert task.status == "canonical" and task.canonical_verdict == "reject"
    last = events(session)[-1]
    assert last.type == "quality.verdict.rejected.v1" and last.payload["auditor_id"] == str(auditor)
    assert last.payload["billable"] is False
    assert {r.kind for r in session.scalars(select(Review))} == {"review", "audit"}


def test_only_the_holder_can_record_and_a_claim_expires(session):
    author, reviewer, other = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    open_task(session, author, BATCH, unsampled_unit())
    task = claim_review(session, reviewer)
    session.commit()
    with pytest.raises(Forbidden):
        record_review(session, task.id, other, "accept")
    session.rollback()
    with pytest.raises(NotFound):
        record_review(session, uuid.uuid4(), reviewer, "accept")
    session.rollback()
    assert release_expired_reviews(session) == 0
    assert release_expired_reviews(session, now=datetime.now(UTC) + timedelta(hours=2)) == 1
    session.commit()
    session.refresh(task)
    assert task.status == "pending" and task.reviewer_id is None
    with pytest.raises(Conflict) as e:  # their claim ran out: the job released it, the verdict says why
        record_review(session, task.id, reviewer, "accept")
    assert e.value.code == "review_expired"


def test_an_expired_audit_claim_returns_to_the_audit_queue(session):
    author, reviewer, auditor = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    open_task(session, author, BATCH, sampled_unit())
    task = claim_review(session, reviewer)
    session.commit()
    record_review(session, task.id, reviewer, "accept")
    session.commit()
    claim_review(session, auditor, kind="audit")
    session.commit()
    assert release_expired_reviews(session, now=datetime.now(UTC) + timedelta(hours=2)) == 1
    session.commit()
    session.refresh(task)
    assert task.status == "audit_pending" and task.auditor_id is None


def test_rubric_unclear_opens_a_flag_that_ops_answer(session):
    author, reviewer = uuid.uuid4(), uuid.uuid4()
    open_task(session, author, BATCH, unsampled_unit())
    task = claim_review(session, reviewer)
    session.commit()
    record_review(session, task.id, reviewer, "accept", rubric_unclear=True, note="glossary conflicts with sample 3")
    session.commit()
    flag = session.scalar(select(RubricFlag))
    assert flag.batch_id == BATCH and flag.answered_at is None
    answer_flag(session, flag.id, "use the glossary; sample 3 is stale")
    session.commit()
    session.refresh(flag)
    assert flag.answered_at is not None
    with pytest.raises(NotFound):
        answer_flag(session, uuid.uuid4(), "x")


def test_claim_kind_is_validated(session):
    with pytest.raises(Invalid):
        claim_review(session, uuid.uuid4(), kind="other")


def test_two_reviewers_racing_for_the_same_task_get_one_each_or_a_conflict(factory, session):
    from concurrent.futures import ThreadPoolExecutor

    from yantra_common.db import unit_of_work

    author = uuid.uuid4()
    for _ in range(2):
        open_task(session, author, BATCH, unsampled_unit())
    reviewer = uuid.uuid4()

    def go(_: int) -> str:
        try:
            with unit_of_work(factory) as s:
                claim_review(s, reviewer)
            return "ok"
        except Conflict as e:
            return e.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = sorted(pool.map(go, range(2)))
    assert results == ["ok", "one_live_review"]


def test_a_claim_that_slips_past_the_live_check_is_stopped_by_the_index(session, monkeypatch):
    from yantra_quality import service

    author, reviewer = uuid.uuid4(), uuid.uuid4()
    open_task(session, author, BATCH, unsampled_unit())
    open_task(session, author, BATCH, unsampled_unit())
    claim_review(session, reviewer)
    session.commit()
    monkeypatch.setattr(service, "_one_live", lambda *a, **k: None)
    with pytest.raises(Conflict) as e:
        claim_review(session, reviewer)
    assert e.value.code == "one_live_review"


def test_the_task_is_readable_by_its_holder_only_and_keeps_the_submission_copy(session):
    from yantra_quality.service import get_task

    author, reviewer = uuid.uuid4(), uuid.uuid4()
    open_task(session, author, BATCH, unsampled_unit())
    task = claim_review(session, reviewer)
    assert get_task(session, task.id, reviewer).answer == {"transcript": "namaste"}
    assert get_task(session, task.id, reviewer).payload == {"text": "namaste", "language": "hi"}
    for who in (author, uuid.uuid4()):
        with pytest.raises(NotFound):
            get_task(session, task.id, who)
    with pytest.raises(NotFound):
        get_task(session, uuid.uuid4(), reviewer)


def test_the_auditor_reads_the_task_while_it_is_theirs(session):
    from yantra_quality.service import get_task

    author, reviewer, auditor = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    open_task(session, author, BATCH, sampled_unit())
    task = claim_review(session, reviewer)
    record_review(session, task.id, reviewer, "accept")
    session.commit()
    audit = claim_review(session, auditor, kind="audit")
    assert get_task(session, audit.id, auditor).answer == {"transcript": "namaste"}
    for who in (reviewer, author):  # the first reviewer's verdict is in: the copy is no longer theirs
        with pytest.raises(NotFound):
            get_task(session, audit.id, who)


# ---------- my work and disputes ----------


def decided_task(session, author, verdict="reject", reason_code="low_quality", note=None, feedback=None):
    """A task of `author` decided by one reviewer, outside the audit sample."""
    reviewer = uuid.uuid4()
    open_task(session, author, BATCH, unsampled_unit())
    task = claim_review(session, reviewer)
    session.commit()
    record_review(session, task.id, reviewer, verdict, reason_code=reason_code, note=note, feedback=feedback)
    session.commit()
    return task


def test_my_work_is_the_authors_tasks_newest_first_with_the_review_that_became_canonical(session):
    from yantra_quality.service import my_work

    author, other, reviewer, auditor = uuid.uuid4(), uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    rejected = decided_task(session, author, note="too short", feedback={"score": 1})
    open_task(session, author, BATCH, sampled_unit())
    audited = claim_review(session, reviewer)
    record_review(session, audited.id, reviewer, "accept")
    session.commit()
    claim_review(session, auditor, kind="audit")
    record_review(session, audited.id, auditor, "needs_edits", reason_code="incomplete", note="missing line 3")
    session.commit()
    open_task(session, other, BATCH, unsampled_unit())  # someone else's work never shows
    pending_unit = open_task(session, author, BATCH, unsampled_unit())
    rows = my_work(session, author)
    assert [t.unit_id for t, _, _ in rows] == [pending_unit, audited.unit_id, rejected.unit_id]
    assert rows[0][1] is None and rows[0][2] is None and rows[0][0].canonical_at is None
    assert rows[1][1].kind == "audit" and rows[1][1].note == "missing line 3"  # the auditor's verdict won
    assert rows[2][1].kind == "review" and rows[2][1].feedback == {"score": 1}
    assert rows[2][0].canonical_at is not None and rows[2][0].canonical_at <= rows[1][0].canonical_at
    assert my_work(session, other)[0][0].worker_id == other and len(my_work(session, uuid.uuid4())) == 0


def test_a_dispute_is_raised_once_by_the_author_on_a_rejecting_verdict_within_the_window(session):
    from yantra_quality.models import Dispute
    from yantra_quality.service import DISPUTE_WINDOW, raise_dispute

    author, reviewer = uuid.uuid4(), uuid.uuid4()
    open_task(session, author, BATCH, unsampled_unit())
    pending = claim_review(session, reviewer)
    session.commit()
    with pytest.raises(Conflict) as e:
        raise_dispute(session, pending.id, author, "the glossary says otherwise")
    assert e.value.code == "not_disputable"
    session.rollback()
    accepted = decided_task(session, author, "accept", reason_code=None)
    with pytest.raises(Conflict) as e:
        raise_dispute(session, accepted.id, author, "the glossary says otherwise")
    assert e.value.code == "not_disputable"
    session.rollback()
    rejected = decided_task(session, author)
    for who in (reviewer, uuid.uuid4()):  # only the author, and a stranger learns nothing
        with pytest.raises(NotFound):
            raise_dispute(session, rejected.id, who, "the glossary says otherwise")
        session.rollback()
    with pytest.raises(NotFound):
        raise_dispute(session, uuid.uuid4(), author, "the glossary says otherwise")
    session.rollback()
    with pytest.raises(Conflict) as e:
        raise_dispute(
            session, rejected.id, author, "too late", now=datetime.now(UTC) + DISPUTE_WINDOW + timedelta(seconds=1)
        )
    assert e.value.code == "dispute_window_closed"
    session.rollback()
    dispute = raise_dispute(session, rejected.id, author, "the glossary says otherwise")
    session.commit()
    assert dispute.status == "open" and dispute.created_at is not None and dispute.worker_id == author
    with pytest.raises(Conflict) as e:
        raise_dispute(session, rejected.id, author, "again")
    assert e.value.code == "dispute_exists" and e.value.context["dispute_id"] == str(dispute.id)
    session.rollback()
    assert session.scalar(select(Dispute)).task_id == rejected.id


def test_ops_see_open_disputes_oldest_first_and_decide_each_once(session):
    from yantra_quality.service import my_work, open_disputes, raise_dispute, resolve_dispute

    author = uuid.uuid4()
    first = decided_task(session, author, note="unreadable")
    second = decided_task(session, author, "needs_edits", "client_glossary_change")
    d1 = raise_dispute(session, first.id, author, "it was readable in the original")
    session.commit()
    d2 = raise_dispute(session, second.id, author, "the client changed the glossary after I submitted")
    session.commit()
    queue = open_disputes(session)
    assert [d.id for d, _, _ in queue] == [d1.id, d2.id]
    assert [d.id for d, _, _ in open_disputes(session, limit=1)] == [d1.id]  # the queue is paged, oldest first
    assert queue[0][1].unit_id == first.unit_id and queue[0][1].canonical_verdict == "reject"
    assert queue[0][2].reason_code == "low_quality" and queue[1][2].reason_code == "client_glossary_change"
    ops = uuid.uuid4()
    with pytest.raises(Invalid):
        resolve_dispute(session, d1.id, "maybe", "no", resolved_by=ops)
    with pytest.raises(NotFound):
        resolve_dispute(session, uuid.uuid4(), "upheld", "no", resolved_by=ops)
    session.rollback()
    upheld = resolve_dispute(session, d1.id, "upheld", "the scan was fine; reviewer error", resolved_by=ops)
    session.commit()
    assert upheld.status == "upheld" and upheld.resolved_at is not None and upheld.answer.startswith("the scan")
    assert upheld.resolved_by == ops  # the decision is signed by the ops caller
    with pytest.raises(Conflict) as e:
        resolve_dispute(session, d1.id, "dismissed", "changed my mind", resolved_by=ops)
    assert e.value.code == "dispute_resolved"
    session.rollback()
    assert [d.id for d, _, _ in open_disputes(session)] == [d2.id]
    assert events(session)[-1].type == "quality.verdict.rejected.v1"  # an upheld dispute emits nothing: no money moves
    rows = {t.id: d for t, _, d in my_work(session, author)}
    assert rows[first.id].status == "upheld" and rows[second.id].status == "open"


# ---------- ops: stats and the queue list ----------


def reviewed(session, batch, verdict, reason_code=None, sampled=False, audit=None):
    """One task taken to the given review verdict by a fresh reviewer; `audit` is the auditor's (verdict, reason).
    Call it while nothing else is pending: the claim takes the oldest waiting task."""
    author, reviewer = uuid.uuid4(), uuid.uuid4()
    unit = open_task(session, author, batch, sampled_unit() if sampled else unsampled_unit())
    task = claim_review(session, reviewer)
    session.commit()
    assert task.unit_id == unit
    record_review(session, task.id, reviewer, verdict, reason_code)
    session.commit()
    if audit is not None:
        auditor = uuid.uuid4()
        assert claim_review(session, auditor, "audit").id == task.id
        session.commit()
        record_review(session, task.id, auditor, *audit)
        session.commit()
    return task


def test_stats_count_every_stage_from_the_task_status_and_the_canonical_verdict(session):
    a, b = uuid.uuid4(), uuid.uuid4()
    reviewed(session, a, "accept")
    reviewed(session, a, "reject", "low_quality")
    reviewed(session, a, "accept", sampled=True, audit=("reject", "client_glossary_change"))  # a disagreement
    reviewed(session, a, "accept", sampled=True)  # waits for an auditor
    reviewed(session, b, "needs_edits", "client_ambiguous_instruction")
    first = open_task(session, uuid.uuid4(), a, unsampled_unit())
    open_task(session, uuid.uuid4(), a, unsampled_unit())
    claim_review(session, uuid.uuid4())  # the oldest pending task: `first`
    session.commit()
    s = stats(session, {a})
    assert (s["pending"], s["claimed"], s["in_audit"], s["canonical"]) == (1, 1, 1, 3)
    assert (s["accepted"], s["rejected"], s["needs_edits"]) == (1, 2, 0)
    assert s["acceptance_rate"] == "0.3333" and s["audit_disagreements"] == 1
    assert s["reasons"] == [
        {"reason_code": "client_glossary_change", "count": 1, "billable": True},
        {"reason_code": "low_quality", "count": 1, "billable": False},
    ]
    pending = session.scalar(select(ReviewTask).where(ReviewTask.status == "pending"))
    assert pending.unit_id != first and s["oldest_pending_at"] == pending.created_at
    everything = stats(session)
    assert (everything["canonical"], everything["needs_edits"], everything["pending"]) == (4, 1, 1)
    assert everything["acceptance_rate"] == "0.2500" and len(everything["reasons"]) == 3
    only_b = stats(session, {b})
    assert (only_b["canonical"], only_b["needs_edits"], only_b["accepted"]) == (1, 1, 0)
    assert only_b["acceptance_rate"] == "0.0000" and only_b["oldest_pending_at"] is None
    assert only_b["audit_disagreements"] == 0 and only_b["reasons"] == [
        {"reason_code": "client_ambiguous_instruction", "count": 1, "billable": True}
    ]
    empty = stats(session, {uuid.uuid4()})
    assert empty["canonical"] == 0 and empty["acceptance_rate"] is None and empty["reasons"] == []


def test_batch_ids_are_a_comma_list_of_at_most_two_hundred_uuids():
    a, b = uuid.uuid4(), uuid.uuid4()
    assert parse_batch_ids(f"{a}, {b},{a}") == frozenset({a, b})
    assert parse_batch_ids(None) == frozenset() and parse_batch_ids(" , ") == frozenset()
    with pytest.raises(Invalid):
        parse_batch_ids("not-a-uuid")
    assert len(parse_batch_ids(",".join(str(uuid.uuid4()) for _ in range(200)))) == 200
    with pytest.raises(Invalid):
        parse_batch_ids(",".join(str(uuid.uuid4()) for _ in range(201)))


def test_the_queue_list_puts_the_oldest_waiting_task_on_top_and_filters_by_batch_and_status(session):
    a, b = uuid.uuid4(), uuid.uuid4()
    done = reviewed(session, a, "accept")
    units = [open_task(session, uuid.uuid4(), a, unsampled_unit()) for _ in range(3)]
    other = open_task(session, uuid.uuid4(), b, unsampled_unit())
    total, items = list_tasks(session)
    assert total == 5 and [t.unit_id for t in items] == [done.unit_id, *units, other]
    total, items = list_tasks(session, batch_id=a, status="pending")
    assert total == 3 and [t.unit_id for t in items] == units
    total, items = list_tasks(session, batch_id=a, limit=1, offset=1)
    assert total == 4 and [t.unit_id for t in items] == [units[0]]
    total, items = list_tasks(session, status="canonical")
    assert total == 1 and items[0].id == done.id and items[0].canonical_verdict == "accept"
    assert list_tasks(session, batch_id=uuid.uuid4()) == (0, [])
