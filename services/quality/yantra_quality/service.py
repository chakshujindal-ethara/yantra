"""The quality operations. The 10% audit sample is an HMAC of the unit id under `YANTRA_AUDIT_KEY`, decided when
the task opens: a replayed event samples the same way, and nobody without the key can tell which units are sampled
(the reviewer never sees the flag). A review claim lasts 60 minutes. The reviewer is never the author (checked in
the claim query), holds the project's certification gate when it has one, and is cleared by ops for a sensitive
project; they read the task only while they hold it and still may. The author may dispute a needs_edits or reject
verdict once, within 14 days of the decision; ops decide it once, never on their own work or verdict."""

import hashlib
import hmac
import logging
import uuid
from collections.abc import Collection
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Any

from sqlalchemy import Select, and_, case, delete, func, or_, select, true, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, aliased

from yantra_common.errors import Conflict, DomainError, Forbidden, Invalid, NotFound
from yantra_common.events import Envelope
from yantra_common.outbox import emit
from yantra_contracts.events.v1 import (
    AssessCertified,
    QualityVerdictAccepted,
    QualityVerdictRejected,
    TalentOfferAccepted,
    WorkBatchPurged,
    WorkerGatesSet,
    WorkUnitSubmitted,
)
from yantra_quality.config import quality_settings
from yantra_quality.models import (
    OUTBOX,
    Dispute,
    GatesSeq,
    Reason,
    Review,
    Reviewer,
    ReviewerGate,
    ReviewRelease,
    ReviewTask,
    RubricFlag,
)

log = logging.getLogger("yantra.quality")
AUDIT_SAMPLE_PERCENT = 10
REVIEW_TTL = timedelta(minutes=60)
DISPUTE_WINDOW = timedelta(days=14)
DISPUTABLE_VERDICTS = ("needs_edits", "reject")
FLAG_SLA = timedelta(days=2)  # a "rubric unclear" flag older than this is overdue for the TPM
FIRST_REVIEW = aliased(Review, name="first_review")
AUDIT_REVIEW = aliased(Review, name="audit_review")


def sampled_for_audit(unit_id: uuid.UUID, percent: int = AUDIT_SAMPLE_PERCENT, key: str | None = None) -> bool:
    """In the audit sample when the HMAC-SHA256 of the unit id under the audit key, read as a number, falls in the
    first `percent` of a hundred: deterministic per key (stable tests, stable replays), unpredictable without it."""
    secret = (key if key is not None else quality_settings().audit_key).encode()
    digest = hmac.new(secret, unit_id.bytes, hashlib.sha256).digest()
    return int.from_bytes(digest[:8], "big") % 100 < percent


# ---------- consumers ----------


def on_unit_submitted(session: Session, env: Envelope) -> None:
    """`work.unit.submitted` opens a review task. One per submission; a resubmission is a new submission."""
    e = WorkUnitSubmitted.model_validate(env.data)
    session.add(
        ReviewTask(
            unit_id=e.unit_id,
            batch_id=e.batch_id,
            submission_id=e.submission_id,
            worker_id=e.worker_id,
            rubric_version=e.rubric_version,
            sampled_for_audit=sampled_for_audit(e.unit_id),
            payload=e.payload,
            answer=e.answer,
            project_id=e.project_id,
            cert_gate=e.cert_gate,
            sensitive=e.sensitive,
        )
    )
    session.flush()


def upsert_reviewer_gate(session: Session, worker_id: uuid.UUID, gate: str, source: str, at: datetime) -> None:
    session.execute(
        pg_insert(ReviewerGate)
        .values(worker_id=worker_id, gate=gate, source=source, at=at)
        .on_conflict_do_nothing(index_elements=["worker_id", "gate"])
    )


def on_assess_certified(session: Session, env: Envelope) -> None:
    """A passed paper lets the worker review the gate's work too."""
    e = AssessCertified.model_validate(env.data)
    upsert_reviewer_gate(session, e.worker_id, e.gate, "assess", env.occurred_at)


def on_offer_accepted(session: Session, env: Envelope) -> None:
    """An accepted offer on a listing with no paper opens its gate; one with a paper carries none."""
    e = TalentOfferAccepted.model_validate(env.data)
    if e.gate:
        upsert_reviewer_gate(session, e.worker_id, e.gate, "offer", env.occurred_at)


def on_gates_set(session: Session, env: Envelope) -> None:
    """Gates set by hand (ops, Odoo) replace the worker's earlier hand-set ones; gates a paper or an offer granted
    stay. A hand-set gate the worker already earned keeps its earned source. An event whose `seq` is not above the
    last one applied for the worker is a late redelivery and changes nothing (one without `seq` predates it)."""
    e = WorkerGatesSet.model_validate(env.data)
    if e.seq is not None:
        applied = session.execute(
            pg_insert(GatesSeq)
            .values(worker_id=e.worker_id, seq=e.seq, at=env.occurred_at)
            .on_conflict_do_update(
                index_elements=["worker_id"], set_={"seq": e.seq, "at": env.occurred_at}, where=GatesSeq.seq < e.seq
            )
            .returning(GatesSeq.worker_id)
        ).first()
        if applied is None:
            log.info("older gates event ignored worker_id=%s seq=%s", e.worker_id, e.seq)
            return
    session.execute(
        delete(ReviewerGate).where(
            ReviewerGate.worker_id == e.worker_id, ReviewerGate.source == "ops", ReviewerGate.gate.not_in(e.gates)
        )
    )
    for gate in e.gates:
        upsert_reviewer_gate(session, e.worker_id, gate, "ops", env.occurred_at)


def on_batch_purged(session: Session, env: Envelope) -> None:
    """The batch's retention ran out in market: drop quality's own copies of its payloads and answers."""
    e = WorkBatchPurged.model_validate(env.data)
    session.execute(update(ReviewTask).where(ReviewTask.batch_id == e.batch_id).values(payload=None, answer=None))


def reviewer_gates(session: Session, worker_id: uuid.UUID) -> list[str]:
    return sorted(session.scalars(select(ReviewerGate.gate).where(ReviewerGate.worker_id == worker_id)))


def is_cleared(session: Session, worker_id: uuid.UUID) -> bool:
    row = session.get(Reviewer, worker_id)
    return row is not None and row.sensitive_cleared


def set_reviewer(session: Session, worker_id: uuid.UUID, sensitive_cleared: bool, set_by: uuid.UUID) -> Reviewer:
    """Ops clear (or un-clear) a reviewer, never themselves (403 `self_action`)."""
    if worker_id == set_by:
        raise Forbidden("you cannot set your own clearance", worker_id=str(worker_id)).with_code("self_action")
    values = {"sensitive_cleared": sensitive_cleared, "set_by": set_by, "updated_at": datetime.now(UTC)}
    stmt = (
        pg_insert(Reviewer)
        .values(worker_id=worker_id, **values)
        .on_conflict_do_update(index_elements=["worker_id"], set_=values)
        .returning(Reviewer)
    )
    return session.scalars(stmt, execution_options={"populate_existing": True}).one()


def _holds(task: ReviewTask, caller_id: uuid.UUID) -> bool:
    return (task.status == "claimed" and task.reviewer_id == caller_id) or (
        task.status == "audit_claimed" and task.auditor_id == caller_id
    )


def _may_review(session: Session, task: ReviewTask, caller_id: uuid.UUID) -> bool:
    """The rule the claim applied, checked again now: the project's gate, and clearance for sensitive work."""
    if task.sensitive and not is_cleared(session, caller_id):
        return False
    return task.cert_gate is None or task.cert_gate in reviewer_gates(session, caller_id)


def _still_allowed(session: Session, task: ReviewTask, caller_id: uuid.UUID) -> ReviewTask:
    """A holder who lost the gate or the clearance since the claim gets the task taken back (committed, so another
    reviewer can take it) and 403 `clearance_revoked`."""
    if _may_review(session, task, caller_id):
        return task
    session.refresh(task, with_for_update=True)
    if not _holds(task, caller_id):  # released meanwhile (their own release, the expiry job): nothing to take back
        raise NotFound("task not found", task_id=str(task.id))
    _give_back(session, task, "revoked", datetime.now(UTC), None)
    session.commit()
    log.info("review taken back: clearance or gate revoked task_id=%s holder=%s", task.id, caller_id)
    raise Forbidden("you may no longer review this task; it is back in the queue", task_id=str(task.id)).with_code(
        "clearance_revoked"
    )


def get_task(session: Session, task_id: uuid.UUID, caller_id: uuid.UUID) -> ReviewTask:
    """A task is readable only by the reviewer or auditor holding it right now, while they still may review it:
    never by its author, never after the verdict, never by anyone else (404, so a task id leaks nothing)."""
    task = session.get(ReviewTask, task_id)
    if task is None or not _holds(task, caller_id):
        raise NotFound("task not found", task_id=str(task_id))
    return _still_allowed(session, task, caller_id)


# ---------- review claims ----------


def _one_live(session: Session, reviewer_id: uuid.UUID, status: str) -> None:
    col = ReviewTask.reviewer_id if status == "claimed" else ReviewTask.auditor_id
    live = session.scalar(select(ReviewTask.id).where(col == reviewer_id, ReviewTask.status == status).limit(1))
    if live is not None:
        raise Conflict("reviewer already holds a live task", reviewer_id=str(reviewer_id)).with_code("one_live_review")


def active_review(session: Session, caller_id: uuid.UUID) -> ReviewTask:
    """The task the caller holds right now, as reviewer or as auditor; 404 when they hold none. Lets the app
    show a held task again after a reload instead of reporting an empty queue."""
    task = session.scalar(
        select(ReviewTask).where(
            or_(
                and_(ReviewTask.reviewer_id == caller_id, ReviewTask.status == "claimed"),
                and_(ReviewTask.auditor_id == caller_id, ReviewTask.status == "audit_claimed"),
            )
        )
    )
    if task is None:
        raise NotFound("no task held by this reviewer", reviewer_id=str(caller_id))
    return _still_allowed(session, task, caller_id)


def claim_review(
    session: Session, reviewer_id: uuid.UUID, kind: str = "review", batch_id: uuid.UUID | None = None
) -> ReviewTask:
    """Next task in queue order the reviewer may take: never their own work, only gated work whose gate they hold,
    only sensitive work once ops cleared them. When nothing they may take waits, the 404 counts the work waiting for
    a gate they lack (`waiting_for_gate`) and for a clearance (`waiting_for_clearance`), so the app can say why the
    queue looks empty; other gates' work is someone else's queue, not an error. `batch_id` narrows the queue to one
    batch (a lead clearing one batch, or a check that must not touch other work)."""
    if kind not in ("review", "audit"):
        raise Invalid("kind must be review or audit")
    pending, claimed = ("pending", "claimed") if kind == "review" else ("audit_pending", "audit_claimed")
    _one_live(session, reviewer_id, claimed)
    gates = reviewer_gates(session, reviewer_id)
    cleared = is_cleared(session, reviewer_id)
    mine = [ReviewTask.status == pending, ReviewTask.worker_id != reviewer_id]
    if kind == "audit":
        mine.append(ReviewTask.reviewer_id != reviewer_id)
    if batch_id is not None:
        mine.append(ReviewTask.batch_id == batch_id)
    allowed = [or_(ReviewTask.cert_gate.is_(None), ReviewTask.cert_gate.in_(gates))]
    if not cleared:
        allowed.append(ReviewTask.sensitive.is_(False))
    query = (
        select(ReviewTask)
        .where(*mine, *allowed)
        .order_by(ReviewTask.created_at, ReviewTask.id)
        .limit(1)
        .with_for_update(skip_locked=True)
    )
    task = session.scalar(query)
    if task is None:
        gated = session.scalar(
            select(func.count())
            .select_from(ReviewTask)
            .where(*mine, ReviewTask.cert_gate.is_not(None), ReviewTask.cert_gate.not_in(gates))
        )
        sensitive: int | None = 0
        if not cleared:
            sensitive = session.scalar(
                select(func.count()).select_from(ReviewTask).where(*mine, ReviewTask.sensitive.is_(True))
            )
        raise NotFound(
            "no task waiting for this reviewer",
            waiting_for_gate=int(gated or 0),
            waiting_for_clearance=int(sensitive or 0),
        )
    task.status = claimed
    if kind == "review":
        task.reviewer_id = reviewer_id
    else:
        task.auditor_id = reviewer_id
    task.claim_expires_at = datetime.now(UTC) + REVIEW_TTL
    try:
        session.flush()
    except IntegrityError as e:
        raise Conflict("reviewer already holds a live task", reviewer_id=str(reviewer_id)).with_code(
            "one_live_review"
        ) from e
    return task


def _give_back(session: Session, task: ReviewTask, reason: str, now: datetime, released_by: uuid.UUID | None) -> None:
    """Back to the queue it came from, with a history row: who held it, why it ended, who released it."""
    if task.status == "claimed":
        kind, holder = "review", task.reviewer_id
        task.status, task.reviewer_id = "pending", None
    else:
        kind, holder = "audit", task.auditor_id
        task.status, task.auditor_id = "audit_pending", None
    assert holder is not None  # a claimed task always has its holder
    session.add(
        ReviewRelease(
            task_id=task.id,
            kind=kind,
            holder_id=holder,
            reason=reason,
            released_by=released_by,
            expires_at=task.claim_expires_at,
            released_at=now,
        )
    )
    task.claim_expires_at = None


HELD = ("claimed", "audit_claimed")


def release_expired_reviews(
    session: Session, now: datetime | None = None, limit: int = 500, released_by: uuid.UUID | None = None
) -> int:
    """Review claims past their time go back to the queue: the expiry job (`released_by` None) or an operator's
    "release all" (their id)."""
    now = now or datetime.now(UTC)
    tasks = session.scalars(
        select(ReviewTask)
        .where(ReviewTask.status.in_(HELD), ReviewTask.claim_expires_at < now)
        .limit(limit)
        .with_for_update(skip_locked=True)
    ).all()
    for task in tasks:
        _give_back(session, task, "expired", now, released_by)
    session.flush()
    return len(tasks)


def release_expired_review(
    session: Session, task_id: uuid.UUID, released_by: uuid.UUID, now: datetime | None = None
) -> ReviewTask:
    """An operator releases one stuck review claim from the stuck-work list."""
    now = now or datetime.now(UTC)
    task = session.scalar(select(ReviewTask).where(ReviewTask.id == task_id).with_for_update())
    if task is None:
        raise NotFound("task not found", task_id=str(task_id))
    if task.status not in HELD or task.claim_expires_at is None or task.claim_expires_at >= now:
        raise Conflict(
            "only a held review past its time can be released here", task_id=str(task_id), status=task.status
        ).with_code("review_not_expired")
    _give_back(session, task, "expired", now, released_by)
    session.flush()
    log.info("expired review released by hand task_id=%s released_by=%s", task.id, released_by)
    return task


def release_review(session: Session, task_id: uuid.UUID, holder: uuid.UUID, now: datetime | None = None) -> ReviewTask:
    """The holder gives the task back without a verdict."""
    now = now or datetime.now(UTC)
    task = session.scalar(select(ReviewTask).where(ReviewTask.id == task_id).with_for_update())
    held = task is not None and (
        (task.status == "claimed" and task.reviewer_id == holder)
        or (task.status == "audit_claimed" and task.auditor_id == holder)
    )
    if task is None or not held:
        raise Forbidden("task is not held by this reviewer", task_id=str(task_id))
    _give_back(session, task, "holder", now, holder)
    session.flush()
    return task


def expired_reviews(session: Session, now: datetime | None = None, limit: int = 200) -> list[ReviewTask]:
    """Held reviews past their time, oldest first: what the stuck-work list shows."""
    now = now or datetime.now(UTC)
    return list(
        session.scalars(
            select(ReviewTask)
            .where(ReviewTask.status.in_(HELD), ReviewTask.claim_expires_at < now)
            .order_by(ReviewTask.claim_expires_at, ReviewTask.id)
            .limit(limit)
        )
    )


def released_reviews(session: Session, since: datetime, limit: int = 200) -> list[ReviewRelease]:
    return list(
        session.scalars(
            select(ReviewRelease)
            .where(ReviewRelease.released_at >= since)
            .order_by(ReviewRelease.released_at.desc(), ReviewRelease.id)
            .limit(limit)
        )
    )


# ---------- the reason taxonomy ----------


def reasons(session: Session, include_retired: bool = False) -> list[Reason]:
    stmt = select(Reason).order_by(Reason.sort, Reason.code)
    if not include_retired:
        stmt = stmt.where(Reason.active.is_(True))
    return list(session.scalars(stmt))


def upsert_reason(session: Session, code: str, fields: dict[str, Any]) -> Reason:
    values = {**fields, "updated_at": datetime.now(UTC)}
    stmt = (
        pg_insert(Reason)
        .values(code=code, **values)
        .on_conflict_do_update(index_elements=["code"], set_=values)
        .returning(Reason)
    )
    return session.scalars(stmt, execution_options={"populate_existing": True}).one()


def billable_codes(session: Session) -> frozenset[str]:
    """Every client-caused code, retired ones included: an old verdict keeps its meaning."""
    return frozenset(session.scalars(select(Reason.code).where(Reason.billable.is_(True))))


# ---------- verdicts ----------


def record_review(
    session: Session,
    task_id: uuid.UUID,
    reviewer_id: uuid.UUID,
    verdict: str,
    reason_code: str | None = None,
    rubric_unclear: bool = False,
    note: str | None = None,
    feedback: dict[str, Any] | None = None,
) -> ReviewTask:
    """A reviewer's or an auditor's verdict on the task they hold. Needs-edits and reject need an active reason code
    that applies to the verdict. A verdict after the claim ran out is refused with 409 `review_expired` whether the
    expiry job got there first (the caller's last claim on the task ended by expiry) or not (the task goes back to
    the queue at once, committed, so another reviewer can take it). A holder who lost the gate or clearance is 403
    `clearance_revoked`. An accepted review in the audit sample waits for the auditor; otherwise the verdict becomes
    canonical now."""
    if verdict not in ("accept", "needs_edits", "reject"):
        raise Invalid("verdict must be accept, needs_edits or reject")
    if verdict != "accept":
        allowed = sorted(r.code for r in reasons(session) if verdict in r.applies_to)
        if reason_code not in allowed:
            raise Invalid(f"a reason code is required for {verdict}", codes=allowed)
    task = session.scalar(select(ReviewTask).where(ReviewTask.id == task_id).with_for_update())
    if task is None:
        raise NotFound("task not found", task_id=str(task_id))
    if task.status == "claimed" and task.reviewer_id == reviewer_id:
        kind = "review"
    elif task.status == "audit_claimed" and task.auditor_id == reviewer_id:
        kind = "audit"
    else:
        if _lapsed_holder(session, task, reviewer_id):
            raise _expired(task_id)
        raise Forbidden("task is not held by this reviewer", task_id=str(task_id), status=task.status)
    now = datetime.now(UTC)
    if task.claim_expires_at is not None and task.claim_expires_at < now:
        _give_back(session, task, "expired", now, None)
        session.commit()  # the release stands although the verdict is refused
        raise _expired(task_id)
    _still_allowed(session, task, reviewer_id)
    session.add(
        Review(
            task_id=task.id,
            kind=kind,
            reviewer_id=reviewer_id,
            verdict=verdict,
            reason_code=reason_code if verdict != "accept" else None,
            rubric_unclear=rubric_unclear,
            note=note,
            feedback=feedback or {},
        )
    )
    if rubric_unclear:
        session.add(RubricFlag(task_id=task.id, batch_id=task.batch_id, reviewer_id=reviewer_id, note=note or ""))
    if kind == "review" and verdict == "accept" and task.sampled_for_audit:
        task.status = "audit_pending"
        task.claim_expires_at = None
        session.flush()
        return task
    _make_canonical(session, task, verdict, reason_code)
    session.flush()
    return task


def _expired(task_id: uuid.UUID) -> DomainError:
    return Conflict("your time on this task ran out; it is back in the queue", task_id=str(task_id)).with_code(
        "review_expired"
    )


def _lapsed_holder(session: Session, task: ReviewTask, reviewer_id: uuid.UUID) -> bool:
    """The caller's latest claim on the task ended by expiry and they have not reviewed it since."""
    last = session.scalar(
        select(ReviewRelease.reason)
        .where(ReviewRelease.task_id == task.id, ReviewRelease.holder_id == reviewer_id)
        .order_by(ReviewRelease.released_at.desc(), ReviewRelease.id)
        .limit(1)
    )
    reviewed = session.scalar(
        select(Review.id).where(Review.task_id == task.id, Review.reviewer_id == reviewer_id).limit(1)
    )
    return last == "expired" and reviewed is None


def _make_canonical(session: Session, task: ReviewTask, verdict: str, reason_code: str | None) -> None:
    task.status = "canonical"
    task.canonical_verdict = verdict
    task.canonical_at = datetime.now(UTC)
    task.claim_expires_at = None
    common = dict(
        unit_id=task.unit_id,
        batch_id=task.batch_id,
        submission_id=task.submission_id,
        worker_id=task.worker_id,
        reviewer_id=task.reviewer_id,
        auditor_id=task.auditor_id,
        rubric_version=task.rubric_version,
    )
    if verdict == "accept":
        emit(session, OUTBOX, f"unit/{task.unit_id}", QualityVerdictAccepted(**common))
    else:
        assert reason_code is not None
        emit(
            session,
            OUTBOX,
            f"unit/{task.unit_id}",
            QualityVerdictRejected(
                **common,
                verdict=verdict,
                reason_code=reason_code,
                billable=reason_code in billable_codes(session),
            ),
        )


def answer_flag(session: Session, flag_id: uuid.UUID, answer: str) -> RubricFlag:
    flag = session.get(RubricFlag, flag_id)
    if flag is None:
        raise NotFound("flag not found", flag_id=str(flag_id))
    flag.answer = answer
    flag.answered_at = datetime.now(UTC)
    session.flush()
    return flag


# ---------- the author's side: my work and disputes ----------


def _with_reviews(query: Select[Any]) -> Select[Any]:
    """Joins the reviewer's and the auditor's review of `ReviewTask` (either may be missing)."""
    return query.outerjoin(
        FIRST_REVIEW, (FIRST_REVIEW.task_id == ReviewTask.id) & (FIRST_REVIEW.kind == "review")
    ).outerjoin(AUDIT_REVIEW, (AUDIT_REVIEW.task_id == ReviewTask.id) & (AUDIT_REVIEW.kind == "audit"))


def canonical_review(task: ReviewTask, review: Review | None, audit: Review | None) -> Review | None:
    """The review that became canonical, the way `_make_canonical` is reached: the auditor's when one exists
    (their verdict wins), else the reviewer's. None while the task is still in review."""
    if task.status != "canonical":
        return None
    return audit if audit is not None else review


def my_work(
    session: Session, worker_id: uuid.UUID, limit: int = 200
) -> list[tuple[ReviewTask, Review | None, Dispute | None]]:
    """The author's own tasks, newest first, each with the review that became canonical and its dispute."""
    query = (
        _with_reviews(select(ReviewTask, FIRST_REVIEW, AUDIT_REVIEW, Dispute).select_from(ReviewTask))
        .outerjoin(Dispute, Dispute.task_id == ReviewTask.id)
        .where(ReviewTask.worker_id == worker_id)
        .order_by(ReviewTask.created_at.desc(), ReviewTask.id.desc())
        .limit(limit)
    )
    return [
        (task, canonical_review(task, review, audit), dispute)
        for task, review, audit, dispute in session.execute(query).all()
    ]


def raise_dispute(
    session: Session, task_id: uuid.UUID, worker_id: uuid.UUID, reason: str, now: datetime | None = None
) -> Dispute:
    """The author disputes a needs_edits or reject verdict, once per task, within DISPUTE_WINDOW of the decision.
    Anyone else gets not-found, so a task id leaks nothing. The task row lock serialises two disputes of one task."""
    task = session.scalar(select(ReviewTask).where(ReviewTask.id == task_id).with_for_update())
    if task is None or task.worker_id != worker_id:
        raise NotFound("task not found", task_id=str(task_id))
    if task.status != "canonical" or task.canonical_verdict not in DISPUTABLE_VERDICTS:
        raise Conflict(
            "only a needs_edits or reject verdict can be disputed", task_id=str(task_id), status=task.status
        ).with_code("not_disputable")
    now = now or datetime.now(UTC)
    if task.canonical_at is None or now - task.canonical_at > DISPUTE_WINDOW:
        raise Conflict(
            f"a dispute must be raised within {DISPUTE_WINDOW.days} days of the verdict", task_id=str(task_id)
        ).with_code("dispute_window_closed")
    existing = session.scalar(select(Dispute).where(Dispute.task_id == task.id))
    if existing is not None:
        raise Conflict("this task is already disputed", task_id=str(task_id), dispute_id=str(existing.id)).with_code(
            "dispute_exists"
        )
    dispute = Dispute(task_id=task.id, worker_id=worker_id, reason=reason)
    session.add(dispute)
    session.flush()
    session.refresh(dispute)
    return dispute


def open_disputes(session: Session, limit: int = 200) -> list[tuple[Dispute, ReviewTask, Review | None]]:
    """Open disputes oldest first (`limit` at most), each with its task and the review that was disputed."""
    query = (
        _with_reviews(select(Dispute, ReviewTask, FIRST_REVIEW, AUDIT_REVIEW).select_from(Dispute).join(ReviewTask))
        .where(Dispute.status == "open")
        .order_by(Dispute.created_at, Dispute.id)
        .limit(limit)
    )
    return [
        (dispute, task, canonical_review(task, review, audit))
        for dispute, task, review, audit in session.execute(query).all()
    ]


def resolve_dispute(
    session: Session, dispute_id: uuid.UUID, outcome: str, answer: str, resolved_by: uuid.UUID
) -> Dispute:
    """Ops uphold or dismiss a dispute with an answer, once; the decision is final and signed with the caller's
    worker id. Nobody decides a dispute on their own work or on a verdict they gave (403 `self_action`). An upheld
    dispute never changes money (only an accepted verdict creates an earning): it records that the worker was not at
    fault, and the app leaves upheld disputes out of the worker's quality count."""
    if outcome not in ("upheld", "dismissed"):
        raise Invalid("outcome must be upheld or dismissed")
    dispute = session.scalar(select(Dispute).where(Dispute.id == dispute_id).with_for_update())
    if dispute is None:
        raise NotFound("dispute not found", dispute_id=str(dispute_id))
    if dispute.status != "open":
        raise Conflict("dispute already resolved", dispute_id=str(dispute_id), status=dispute.status).with_code(
            "dispute_resolved"
        )
    task = session.get(ReviewTask, dispute.task_id)
    assert task is not None  # the foreign key holds it
    if resolved_by in (task.worker_id, task.reviewer_id, task.auditor_id):
        raise Forbidden(
            "you cannot decide a dispute on your own work or verdict", dispute_id=str(dispute_id)
        ).with_code("self_action")
    dispute.status = outcome
    dispute.answer = answer
    dispute.resolved_at = datetime.now(UTC)
    dispute.resolved_by = resolved_by
    session.flush()
    return dispute


# ---------- ops: stats and the queue list ----------

MAX_BATCH_IDS = 200
RATE_PLACES = Decimal("0.0001")


def parse_batch_ids(raw: str | None) -> frozenset[uuid.UUID]:
    """`batch_ids=a,b`: the project filter, since quality has no project table. At most MAX_BATCH_IDS."""
    parts = [p.strip() for p in (raw or "").split(",") if p.strip()]
    if len(parts) > MAX_BATCH_IDS:
        raise Invalid(f"at most {MAX_BATCH_IDS} batch ids", given=len(parts))
    try:
        return frozenset(uuid.UUID(p) for p in parts)
    except ValueError as e:
        raise Invalid("batch_ids must be a comma-separated list of UUIDs") from e


def _canonical_reason() -> Any:
    """The reason code of the review that became canonical: the auditor's when they reviewed, else the reviewer's."""
    return case((AUDIT_REVIEW.id.is_not(None), AUDIT_REVIEW.reason_code), else_=FIRST_REVIEW.reason_code)


def stats(session: Session, batch_ids: Collection[uuid.UUID] | None = None) -> dict[str, Any]:
    """The review funnel, from `review_task.status` and `canonical_verdict`:
    pending = status pending; claimed = status claimed; in_audit = audit_pending or audit_claimed;
    canonical = status canonical, split into accepted / rejected / needs_edits by the canonical verdict.
    acceptance_rate = accepted / canonical (None when nothing is canonical yet). Reasons come from the canonical
    reviews; audit_disagreements counts tasks whose auditor overruled the reviewer."""
    scope = ReviewTask.batch_id.in_(batch_ids) if batch_ids else true()
    counts: dict[str, int] = dict.fromkeys(
        ("pending", "claimed", "in_audit", "canonical", "accepted", "rejected", "needs_edits"), 0
    )
    oldest_pending: datetime | None = None
    for status, verdict, count, oldest in session.execute(
        select(ReviewTask.status, ReviewTask.canonical_verdict, func.count(), func.min(ReviewTask.created_at))
        .where(scope)
        .group_by(ReviewTask.status, ReviewTask.canonical_verdict)
    ):
        if status in ("audit_pending", "audit_claimed"):
            counts["in_audit"] += count
        elif status == "canonical":
            counts["canonical"] += count
            counts[{"accept": "accepted", "reject": "rejected"}.get(verdict, verdict)] += count
        else:
            counts[status] += count
            if status == "pending":
                oldest_pending = oldest
    reason = _canonical_reason()
    reason_rows = session.execute(
        _with_reviews(select(reason, func.count()).select_from(ReviewTask))
        .where(scope, ReviewTask.status == "canonical", reason.is_not(None))
        .group_by(reason)
        .order_by(func.count().desc(), reason)
    ).all()
    disagreements = session.scalar(
        select(func.count())
        .select_from(ReviewTask)
        .join(FIRST_REVIEW, (FIRST_REVIEW.task_id == ReviewTask.id) & (FIRST_REVIEW.kind == "review"))
        .join(AUDIT_REVIEW, (AUDIT_REVIEW.task_id == ReviewTask.id) & (AUDIT_REVIEW.kind == "audit"))
        .where(scope, FIRST_REVIEW.verdict != AUDIT_REVIEW.verdict)
    )
    rate = (
        str((Decimal(counts["accepted"]) / Decimal(counts["canonical"])).quantize(RATE_PLACES))
        if counts["canonical"]
        else None
    )
    billable = billable_codes(session)
    flag_scope = RubricFlag.batch_id.in_(batch_ids) if batch_ids else true()
    open_flags = [RubricFlag.answered_at.is_(None), flag_scope]
    flags_open = session.scalar(select(func.count()).select_from(RubricFlag).where(*open_flags))
    flags_overdue = session.scalar(
        select(func.count())
        .select_from(RubricFlag)
        .where(*open_flags, RubricFlag.created_at < datetime.now(UTC) - FLAG_SLA)
    )
    return {
        **counts,
        "acceptance_rate": rate,
        "oldest_pending_at": oldest_pending,
        "reasons": [
            {"reason_code": code, "count": int(count), "billable": code in billable} for code, count in reason_rows
        ],
        "audit_disagreements": int(disagreements or 0),
        "flags_open": int(flags_open or 0),
        "flags_overdue": int(flags_overdue or 0),
    }


def list_tasks(
    session: Session,
    batch_id: uuid.UUID | None = None,
    status: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> tuple[int, list[ReviewTask]]:
    """The queue as ops read it: oldest waiting on top (created_at ascending), with the total before paging."""
    conditions = []
    if batch_id is not None:
        conditions.append(ReviewTask.batch_id == batch_id)
    if status is not None:
        conditions.append(ReviewTask.status == status)
    total = session.scalar(select(func.count()).select_from(ReviewTask).where(*conditions)) or 0
    rows = session.scalars(
        select(ReviewTask).where(*conditions).order_by(ReviewTask.created_at, ReviewTask.id).limit(limit).offset(offset)
    ).all()
    return int(total), list(rows)


def open_flags(session: Session, overdue_only: bool = False, now: datetime | None = None) -> list[RubricFlag]:
    """Unanswered "rubric unclear" flags, oldest first; `overdue_only` keeps those past the two-day answer time."""
    stmt = select(RubricFlag).where(RubricFlag.answered_at.is_(None)).order_by(RubricFlag.created_at)
    if overdue_only:
        stmt = stmt.where(RubricFlag.created_at < (now or datetime.now(UTC)) - FLAG_SLA)
    return list(session.scalars(stmt))


def attention(session: Session, now: datetime | None = None) -> dict[str, Any]:
    """Quality's share of the ops attention list."""
    now = now or datetime.now(UTC)
    s = stats(session)
    disputes = session.scalar(select(func.count()).select_from(Dispute).where(Dispute.status == "open"))
    expired = session.scalar(
        select(func.count())
        .select_from(ReviewTask)
        .where(ReviewTask.status.in_(HELD), ReviewTask.claim_expires_at < now)
    )
    return {
        "review_backlog": s["pending"],
        "oldest_pending_at": s["oldest_pending_at"],
        "flags_open": s["flags_open"],
        "flags_overdue": s["flags_overdue"],
        "disputes_open": int(disputes or 0),
        "expired_reviews": int(expired or 0),
    }
