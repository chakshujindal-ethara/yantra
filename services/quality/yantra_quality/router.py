"""HTTP surface of the quality module. Reviewers are workers (`X-Worker-Id`); flags and disputes are decided by
ops. The author reads their own history and raises a dispute; they never see who reviewed them."""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Header, Path, Query, status
from pydantic import BaseModel, ConfigDict, Field

from yantra_common.deps import DB, AdminOrOps, Ops, Reviewer, StorageDep, Worker, WorkerId
from yantra_common.errors import NotFound
from yantra_common.storage import find_ref
from yantra_quality import service
from yantra_quality.models import Dispute, Reason, Review, ReviewRelease, ReviewTask, RubricFlag, TaskStatus
from yantra_quality.models import Reviewer as ReviewerRow

# the caller when the gateway sent one; a release signed by nobody reads as the expiry job
Caller = Annotated[uuid.UUID | None, Header(alias="X-Worker-Id")]

router = APIRouter(prefix="/v1/quality", tags=["quality"])


class TaskOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    unit_id: uuid.UUID
    batch_id: uuid.UUID
    submission_id: uuid.UUID
    rubric_version: str
    status: str
    claim_expires_at: datetime | None
    canonical_verdict: str | None


class TaskDetailOut(TaskOut):
    """What the reviewer reads: the unit's payload and the worker's answer, from quality's own copy. Never the
    author's id or whether the task is in the audit sample: both stay in the ops views (`OpsTaskOut`)."""

    payload: dict[str, Any] | None
    answer: dict[str, Any] | None


class ReviewIn(BaseModel):
    verdict: Literal["accept", "needs_edits", "reject"]
    reason_code: str | None = Field(default=None, max_length=40)
    rubric_unclear: bool = False
    note: str | None = Field(default=None, max_length=2000)
    feedback: dict[str, Any] = Field(default_factory=dict)


class FlagOut(BaseModel):
    """`overdue` once an unanswered flag is older than the two-day answer time."""

    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    task_id: uuid.UUID
    batch_id: uuid.UUID
    note: str
    answer: str | None
    answered_at: datetime | None
    created_at: datetime
    overdue: bool = False


def flag_out(flag: RubricFlag, now: datetime) -> FlagOut:
    late = flag.answered_at is None and flag.created_at < now - service.FLAG_SLA
    return FlagOut.model_validate(flag).model_copy(update={"overdue": late})


class AnswerIn(BaseModel):
    answer: str = Field(min_length=1, max_length=2000)


class ReleasedOut(BaseModel):
    released: int


class DisputeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    status: str
    reason: str
    answer: str | None
    created_at: datetime
    resolved_at: datetime | None


class OpsDisputeOut(DisputeOut):
    """A dispute as ops read it: also who decided it. The author's copy (`DisputeOut`) never carries that."""

    resolved_by: uuid.UUID | None


class MyWorkOut(BaseModel):
    """One of the author's tasks: the verdict and the reviewer's words, never the reviewer's or auditor's id.
    A note written with a rubric-unclear flag is for the TPM, so it is withheld here."""

    task_id: uuid.UUID
    unit_id: uuid.UUID
    batch_id: uuid.UUID
    submission_id: uuid.UUID
    rubric_version: str
    stage: Literal["in_review", "decided"]
    canonical_verdict: str | None
    reason_code: str | None
    billable: bool
    reviewer_note: str | None
    feedback: dict[str, Any] | None
    created_at: datetime
    decided_at: datetime | None
    dispute: DisputeOut | None


class DisputeIn(BaseModel):
    reason: str = Field(min_length=10, max_length=2000)


class DisputeQueueOut(OpsDisputeOut):
    """An open dispute for ops: the task it challenges and the verdict that was given."""

    task_id: uuid.UUID
    unit_id: uuid.UUID
    batch_id: uuid.UUID
    worker_id: uuid.UUID
    verdict: str | None
    reason_code: str | None


class ResolveIn(BaseModel):
    outcome: Literal["upheld", "dismissed"]
    answer: str = Field(min_length=1, max_length=2000)


class ReasonOut(BaseModel):
    reason_code: str
    count: int
    billable: bool


class StatsOut(BaseModel):
    """The review funnel for ops. The counts come from `review_task.status` and `canonical_verdict`
    (see `service.stats`); `acceptance_rate` is a decimal string, None until something is canonical."""

    pending: int
    claimed: int
    in_audit: int
    canonical: int
    accepted: int
    rejected: int
    needs_edits: int
    acceptance_rate: str | None
    oldest_pending_at: datetime | None
    reasons: list[ReasonOut]
    audit_disagreements: int
    flags_open: int
    flags_overdue: int


class OpsTaskOut(BaseModel):
    """A queue row for ops: who holds it, the author and the audit sample, which the reviewer's views never show."""

    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    unit_id: uuid.UUID
    batch_id: uuid.UUID
    worker_id: uuid.UUID
    sampled_for_audit: bool
    status: str
    reviewer_id: uuid.UUID | None
    canonical_verdict: str | None
    created_at: datetime
    canonical_at: datetime | None


class TaskPageOut(BaseModel):
    total: int
    items: list[OpsTaskOut]


class ReasonCodeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    code: str
    label: str
    detail: str
    billable: bool
    applies_to: list[str]
    sort: int
    active: bool


class ReasonIn(BaseModel):
    label: str = Field(min_length=1, max_length=120)
    detail: str = Field(default="", max_length=500)
    billable: bool = False
    applies_to: list[Literal["needs_edits", "reject"]] = Field(min_length=1, max_length=2)
    sort: int = Field(default=0, ge=0, le=1000)
    active: bool = True


class ReviewerIn(BaseModel):
    sensitive_cleared: bool


class ReviewerOut(BaseModel):
    worker_id: uuid.UUID
    sensitive_cleared: bool
    gates: list[str]
    updated_at: datetime | None


class ExpiredReviewRow(BaseModel):
    task_id: uuid.UUID
    unit_id: uuid.UUID
    batch_id: uuid.UUID
    kind: Literal["review", "audit"]
    holder_id: uuid.UUID
    claim_expires_at: datetime
    minutes_overdue: int


class ReleasedReviewRow(BaseModel):
    """A review claim that ended without a verdict. `released_by` null is the expiry job; `reason` holder is the
    reviewer giving it back."""

    model_config = ConfigDict(from_attributes=True)
    task_id: uuid.UUID
    kind: str
    holder_id: uuid.UUID
    reason: str
    released_by: uuid.UUID | None
    expires_at: datetime | None
    released_at: datetime


class UrlOut(BaseModel):
    url: str
    expires_at: datetime


def _my_work_row(
    task: ReviewTask, review: Review | None, dispute: Dispute | None, billable: frozenset[str]
) -> MyWorkOut:
    return MyWorkOut(
        task_id=task.id,
        unit_id=task.unit_id,
        batch_id=task.batch_id,
        submission_id=task.submission_id,
        rubric_version=task.rubric_version,
        stage="decided" if task.status == "canonical" else "in_review",
        canonical_verdict=task.canonical_verdict,
        reason_code=review.reason_code if review else None,
        billable=review is not None and review.reason_code in billable,
        reviewer_note=review.note if review and not review.rubric_unclear else None,
        feedback=review.feedback if review else None,
        created_at=task.created_at,
        decided_at=task.canonical_at,
        dispute=DisputeOut.model_validate(dispute) if dispute else None,
    )


def _queue_row(dispute: Dispute, task: ReviewTask, review: Review | None) -> DisputeQueueOut:
    return DisputeQueueOut(
        **OpsDisputeOut.model_validate(dispute).model_dump(),
        task_id=task.id,
        unit_id=task.unit_id,
        batch_id=task.batch_id,
        worker_id=task.worker_id,
        verdict=task.canonical_verdict,
        reason_code=review.reason_code if review else None,
    )


@router.post("/reviews/claim", response_model=TaskOut, status_code=status.HTTP_201_CREATED, dependencies=[Reviewer])
def claim_review(
    worker_id: WorkerId, session: DB, kind: Literal["review", "audit"] = "review", batch_id: uuid.UUID | None = None
) -> ReviewTask:
    return service.claim_review(session, worker_id, kind, batch_id)


@router.get("/reviews/active", response_model=TaskDetailOut, dependencies=[Reviewer])
def active_review(worker_id: WorkerId, session: DB) -> ReviewTask:
    """The task the caller holds, with its payload and answer; 404 when they hold none."""
    return service.active_review(session, worker_id)


@router.get("/tasks/{task_id}", response_model=TaskDetailOut, dependencies=[Reviewer])
def get_task(task_id: uuid.UUID, worker_id: WorkerId, session: DB) -> ReviewTask:
    return service.get_task(session, task_id, worker_id)


@router.post("/tasks/{task_id}/review", response_model=TaskOut, dependencies=[Reviewer])
def record_review(task_id: uuid.UUID, body: ReviewIn, worker_id: WorkerId, session: DB) -> ReviewTask:
    return service.record_review(session, task_id, worker_id, **body.model_dump())


@router.post("/reviews/{task_id}/release", response_model=TaskOut, dependencies=[Reviewer])
def release_review(task_id: uuid.UUID, worker_id: WorkerId, session: DB) -> ReviewTask:
    """The holder gives the task back without a verdict; it returns to its queue."""
    return service.release_review(session, task_id, worker_id)


@router.get("/tasks/{task_id}/payload-url", response_model=UrlOut, dependencies=[Reviewer])
def payload_url(task_id: uuid.UUID, worker_id: WorkerId, session: DB, store: StorageDep) -> UrlOut:
    """A five-minute link to the media the task's payload names, for the reviewer or auditor holding it (the same
    rule as the task: only while held, only while they may still review it)."""
    task = service.get_task(session, task_id, worker_id)
    key = find_ref(task.payload, store.bucket)
    if key is None:
        raise NotFound("this task has no stored media", task_id=str(task_id)).with_code("no_payload_object")
    p = store.presign_get(key)
    return UrlOut(url=p.url, expires_at=p.expires_at)


# ---------- stuck work: review claims past their time ----------


@router.post("/reviews/release-expired", response_model=ReleasedOut, dependencies=[AdminOrOps])
def release_expired(session: DB, worker_id: Caller = None) -> ReleasedOut:
    """Release every review claim past its time now (the expiry job does the same every 30 s), signed by the caller."""
    return ReleasedOut(released=service.release_expired_reviews(session, released_by=worker_id))


@router.get("/reviews/expired", response_model=list[ExpiredReviewRow], dependencies=[AdminOrOps])
def expired_reviews(session: DB) -> list[ExpiredReviewRow]:
    now = datetime.now(UTC)
    rows = []
    for t in service.expired_reviews(session, now):
        holder = t.reviewer_id if t.status == "claimed" else t.auditor_id
        assert holder is not None and t.claim_expires_at is not None  # a held task has both
        rows.append(
            ExpiredReviewRow(
                task_id=t.id,
                unit_id=t.unit_id,
                batch_id=t.batch_id,
                kind="review" if t.status == "claimed" else "audit",
                holder_id=holder,
                claim_expires_at=t.claim_expires_at,
                minutes_overdue=int((now - t.claim_expires_at).total_seconds() // 60),
            )
        )
    return rows


@router.post("/reviews/{task_id}/release-expired", response_model=TaskOut, dependencies=[AdminOrOps])
def release_expired_review(task_id: uuid.UUID, worker_id: WorkerId, session: DB) -> ReviewTask:
    """One stuck review claim back to its queue. 409 `review_not_expired` unless held and past its time."""
    return service.release_expired_review(session, task_id, worker_id)


@router.get("/reviews/released", response_model=list[ReleasedReviewRow], dependencies=[AdminOrOps])
def released_reviews(session: DB, days: Annotated[int, Query(ge=1, le=90)] = 7) -> list[ReviewRelease]:
    return service.released_reviews(session, datetime.now(UTC) - timedelta(days=days))


# ---------- who may review what ----------


def reviewer_out(session: DB, worker_id: uuid.UUID, row: ReviewerRow | None) -> ReviewerOut:
    return ReviewerOut(
        worker_id=worker_id,
        sensitive_cleared=row.sensitive_cleared if row else False,
        gates=service.reviewer_gates(session, worker_id),
        updated_at=row.updated_at if row else None,
    )


@router.put("/reviewers/{reviewer_id}", response_model=ReviewerOut, dependencies=[Ops])
def set_reviewer(reviewer_id: uuid.UUID, body: ReviewerIn, worker_id: WorkerId, session: DB) -> ReviewerOut:
    """Clear (or un-clear) a reviewer for sensitive projects, signed by the caller; never oneself (403
    `self_action`)."""
    row = service.set_reviewer(session, reviewer_id, body.sensitive_cleared, worker_id)
    return reviewer_out(session, reviewer_id, row)


@router.get("/reviewers/{reviewer_id}", response_model=ReviewerOut, dependencies=[Ops])
def get_reviewer(reviewer_id: uuid.UUID, session: DB) -> ReviewerOut:
    return reviewer_out(session, reviewer_id, session.get(ReviewerRow, reviewer_id))


@router.get("/reasons", response_model=list[ReasonCodeOut])
def reasons(session: DB, all: bool = False) -> list[Reason]:
    """The reason taxonomy, in display order; `all=true` includes retired codes. Readable by every signed-in role."""
    return service.reasons(session, include_retired=all)


@router.put("/reasons/{code}", response_model=ReasonCodeOut, dependencies=[Ops])
def put_reason(code: Annotated[str, Path(pattern=r"^[a-z][a-z0-9_]{1,39}$")], body: ReasonIn, session: DB) -> Reason:
    """Add or edit a code; retire one with `active` false (never delete: old verdicts keep their meaning)."""
    return service.upsert_reason(session, code, body.model_dump())


# ---------- flags ----------


@router.get("/flags", response_model=list[FlagOut], dependencies=[Ops])
def open_flags(session: DB, overdue: bool = False) -> list[FlagOut]:
    """Unanswered rubric-unclear flags, oldest first; `overdue=true` keeps those past the two-day answer time."""
    now = datetime.now(UTC)
    return [flag_out(f, now) for f in service.open_flags(session, overdue, now)]


@router.post("/flags/{flag_id}/answer", response_model=FlagOut, dependencies=[Ops])
def answer_flag(flag_id: uuid.UUID, body: AnswerIn, session: DB) -> FlagOut:
    return flag_out(service.answer_flag(session, flag_id, body.answer), datetime.now(UTC))


@router.get("/my-work", response_model=list[MyWorkOut], dependencies=[Worker])
def my_work(worker_id: WorkerId, session: DB) -> list[MyWorkOut]:
    """The caller's own tasks, newest first (200 at most)."""
    billable = service.billable_codes(session)
    return [_my_work_row(*row, billable) for row in service.my_work(session, worker_id)]


@router.post(
    "/tasks/{task_id}/dispute", response_model=DisputeOut, status_code=status.HTTP_201_CREATED, dependencies=[Worker]
)
def raise_dispute(task_id: uuid.UUID, body: DisputeIn, worker_id: WorkerId, session: DB) -> Dispute:
    return service.raise_dispute(session, task_id, worker_id, body.reason)


@router.get("/disputes", response_model=list[DisputeQueueOut], dependencies=[Ops])
def open_disputes(session: DB) -> list[DisputeQueueOut]:
    return [_queue_row(*row) for row in service.open_disputes(session)]


@router.post("/disputes/{dispute_id}/resolve", response_model=OpsDisputeOut, dependencies=[Ops])
def resolve_dispute(dispute_id: uuid.UUID, body: ResolveIn, worker_id: WorkerId, session: DB) -> Dispute:
    """The decision is signed with the ops caller's worker id (the gateway sets it from the token)."""
    return service.resolve_dispute(session, dispute_id, body.outcome, body.answer, resolved_by=worker_id)


@router.get("/stats", response_model=StatsOut, dependencies=[Ops])
def stats(
    session: DB,
    batch_id: uuid.UUID | None = None,
    batch_ids: str | None = Query(default=None, max_length=8000, description="comma-separated batch ids (200 at most)"),
) -> StatsOut:
    """The review funnel, over every task or over the batches given (`batch_id`, or a project's `batch_ids`)."""
    scope = set(service.parse_batch_ids(batch_ids))
    if batch_id is not None:
        scope.add(batch_id)
    return StatsOut(**service.stats(session, scope))


@router.get("/tasks", response_model=TaskPageOut, dependencies=[Ops])
def list_tasks(
    session: DB,
    batch_id: uuid.UUID | None = None,
    status: TaskStatus | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> TaskPageOut:
    """The queue, oldest waiting on top."""
    total, items = service.list_tasks(session, batch_id, status, limit, offset)
    return TaskPageOut(total=total, items=[OpsTaskOut.model_validate(t) for t in items])
