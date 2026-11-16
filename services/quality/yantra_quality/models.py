"""Tables of the quality schema. A review task is created from `work.unit.submitted`; a reviewer claims it
(never their own work, one live review at a time), records a review; accepted reviews in the audit sample go to
an auditor whose verdict wins; the canonical verdict is emitted once. The author may dispute a needs_edits or
reject verdict once, within a window; ops decide it, and the decision is final."""

import uuid
from datetime import datetime
from typing import Any, Literal, get_args

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    MetaData,
    String,
    Text,
    UniqueConstraint,
    Uuid,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from yantra_common.consumer import consumed_table, dead_table
from yantra_common.outbox import outbox_table
from yantra_common.scheduler import job_lease_table
from yantra_quality import SCHEMA

TaskStatus = Literal["pending", "claimed", "audit_pending", "audit_claimed", "canonical"]
Verdict = Literal["accept", "needs_edits", "reject"]
ReviewKind = Literal["review", "audit"]
DisputeStatus = Literal["open", "upheld", "dismissed"]
GateSource = Literal["assess", "offer", "ops"]
ReleaseReason = Literal["expired", "holder", "revoked"]
TASK_STATUSES = get_args(TaskStatus)
VERDICTS = get_args(Verdict)
REVIEW_KINDS = get_args(ReviewKind)
DISPUTE_STATUSES = get_args(DisputeStatus)
GATE_SOURCES = get_args(GateSource)
RELEASE_REASONS = get_args(ReleaseReason)


class Base(DeclarativeBase):
    metadata = MetaData(schema=SCHEMA)


class ReviewTask(Base):
    __tablename__ = "review_task"
    __table_args__ = (
        UniqueConstraint("submission_id", name="task_one_per_submission"),
        CheckConstraint(f"status in {TASK_STATUSES}", name="task_status"),
        Index("ix_task_queue", "status", "created_at"),
        Index("ix_task_queue_gate", "status", "sensitive", "cert_gate", "created_at"),
        Index("ix_task_one_live_per_reviewer", "reviewer_id", unique=True, postgresql_where="status = 'claimed'"),
        Index("ix_task_one_live_per_auditor", "auditor_id", unique=True, postgresql_where="status = 'audit_claimed'"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    unit_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    batch_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    submission_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)  # the author
    rubric_version: Mapped[str] = mapped_column(String(40), nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="pending")
    sampled_for_audit: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    reviewer_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    auditor_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    claim_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    canonical_verdict: Mapped[str | None] = mapped_column(String(20))
    canonical_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))  # when the verdict was decided
    payload: Mapped[dict[str, Any] | None] = mapped_column(JSONB)  # quality's own copy, from the submitted event
    answer: Mapped[dict[str, Any] | None] = mapped_column(JSONB)
    # who may review it, from the submitted event: the project's gate and its sensitive flag (none on older events)
    project_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    cert_gate: Mapped[str | None] = mapped_column(String(80))
    sensitive: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class Review(Base):
    __tablename__ = "review"
    __table_args__ = (
        UniqueConstraint("task_id", "kind", name="review_one_per_kind"),
        CheckConstraint(f"verdict in {VERDICTS}", name="review_verdict"),
        CheckConstraint(f"kind in {REVIEW_KINDS}", name="review_kind"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    task_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.review_task.id"), nullable=False)
    kind: Mapped[str] = mapped_column(String(10), nullable=False)
    reviewer_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    verdict: Mapped[str] = mapped_column(String(20), nullable=False)
    reason_code: Mapped[str | None] = mapped_column(String(40))
    rubric_unclear: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    note: Mapped[str | None] = mapped_column(Text)
    feedback: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class RubricFlag(Base):
    """A reviewer's "rubric unclear" flag, routed to the TPM. Answered within two days (Stage 1 measures it)."""

    __tablename__ = "rubric_flag"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    task_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.review_task.id"), nullable=False)
    batch_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    reviewer_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    note: Mapped[str] = mapped_column(Text, nullable=False)
    answered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    answer: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class Dispute(Base):
    """The author's one challenge to a needs_edits or reject verdict. Ops uphold or dismiss it with an answer;
    an upheld dispute never moves money, it records that the worker was not at fault."""

    __tablename__ = "dispute"
    __table_args__ = (
        UniqueConstraint("task_id", name="dispute_one_per_task"),
        CheckConstraint(f"status in {DISPUTE_STATUSES}", name="dispute_status"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    task_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.review_task.id"), nullable=False)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)  # the author
    reason: Mapped[str] = mapped_column(Text, nullable=False)
    status: Mapped[str] = mapped_column(String(10), nullable=False, default="open")
    answer: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    resolved_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)  # the ops caller who decided it; ops only


class Reviewer(Base):
    """What ops decide about a reviewer: cleared for sensitive projects or not. No row is not cleared."""

    __tablename__ = "reviewer"

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    sensitive_cleared: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    set_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class ReviewerGate(Base):
    """The certification gates a reviewer holds, kept from `assess.certified` and `talent.offer.accepted`
    (the same read model talent and market keep). A gated project's work goes only to holders of its gate."""

    __tablename__ = "reviewer_gate"
    __table_args__ = (CheckConstraint(f"source in {GATE_SOURCES}", name="reviewer_gate_source"),)

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    gate: Mapped[str] = mapped_column(String(80), primary_key=True)
    source: Mapped[str] = mapped_column(String(10), nullable=False)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class GatesSeq(Base):
    """The newest `worker.gates.set` applied per worker: an event with a lower `seq` is a late redelivery and is
    ignored, so it never brings back a gate a later hand-set removed."""

    __tablename__ = "gates_seq"

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class Reason(Base):
    """The reason taxonomy a needs-edits or reject verdict must carry. `billable` marks client-caused rework;
    `applies_to` lists the verdicts a code may go with. Served to the app, edited by ops; a code is retired
    (`active` false), never deleted, so old verdicts keep their meaning."""

    __tablename__ = "reason"

    code: Mapped[str] = mapped_column(String(40), primary_key=True)
    label: Mapped[str] = mapped_column(Text, nullable=False)
    detail: Mapped[str] = mapped_column(Text, nullable=False, default="")
    billable: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    applies_to: Mapped[list[str]] = mapped_column(JSONB, nullable=False)
    sort: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class ReviewRelease(Base):
    """A review or audit claim that ended without a verdict: by the expiry job (`released_by` null), an operator's
    release of an expired claim (their id), the holder giving it back (`reason` holder) or the holder losing the
    clearance or gate the task needs (`reason` revoked, noticed on their next read)."""

    __tablename__ = "review_release"
    __table_args__ = (
        CheckConstraint(f"reason in {RELEASE_REASONS}", name="review_release_reason"),
        CheckConstraint(f"kind in {REVIEW_KINDS}", name="review_release_kind"),
        Index("ix_review_release_at", "released_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    task_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.review_task.id"), nullable=False)
    kind: Mapped[str] = mapped_column(String(10), nullable=False)
    holder_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    reason: Mapped[str] = mapped_column(String(10), nullable=False)
    released_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    released_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


OUTBOX = outbox_table(Base.metadata, SCHEMA)
CONSUMED = consumed_table(Base.metadata, SCHEMA)
DEAD = dead_table(Base.metadata, SCHEMA)
JOB_LEASE = job_lease_table(Base.metadata, SCHEMA)
# every table of the schema, children first, for TRUNCATE in tests; the reason taxonomy is reference data the
# migration seeds, so it is left alone
TABLES = [t.fullname for t in reversed(Base.metadata.sorted_tables) if t.name != "reason"]
