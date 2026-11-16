"""Tables of the assess schema. A paper is Yantra's handle on an assessment in the engine (Assessment v2): the gate
it certifies, how many attempts a worker gets, and how results are released. The engine owns the questions, the exam
and the scoring.

v2 allows one attempt per person per assessment, so attempt k of every worker sits in *cohort k*: cohort 1 is the
paper's base assessment, cohort k a copy the adapter makes when the first worker needs it. A *sitting* is one worker's
attempt (status `assigned` -> `in_progress` -> `awaiting_result` -> `passed` | `failed`, or `void` when it was never
started and is withdrawn); `worker_link` remembers who a worker is in the engine. A pass writes the certification row
and emits `assess.certified`; a fail emits `assess.failed`. A worker holds at most one certification per gate.

Papers and sittings from before the engine (`engine = 'quiz'`, statuses `live` and `expired`) stay readable: their
papers are retired, their certifications stand, their finished sittings still count as attempts."""

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Any, Literal, get_args

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    MetaData,
    Numeric,
    String,
    Text,
    Uuid,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from yantra_assess import SCHEMA
from yantra_common.consumer import consumed_table, dead_table
from yantra_common.outbox import outbox_table
from yantra_common.scheduler import job_lease_table

PaperStatus = Literal["draft", "published", "retired"]
PaperEngine = Literal["v2", "fake", "quiz"]
ReleasePolicy = Literal["manual", "auto_objective"]
CohortState = Literal["draft", "open", "closed"]
SittingStatus = Literal["assigned", "in_progress", "awaiting_result", "passed", "failed", "void", "live", "expired"]
PAPER_STATUSES = get_args(PaperStatus)
PAPER_ENGINES = get_args(PaperEngine)
RELEASE_POLICIES = get_args(ReleasePolicy)
COHORT_STATES = get_args(CohortState)
SITTING_STATUSES = get_args(SittingStatus)
OPEN = ("assigned", "in_progress", "awaiting_result", "live")  # a sitting still running
FINISHED = ("passed", "failed", "expired")  # a sitting that counts as an attempt
SCORE = Numeric(5, 4)


class Base(DeclarativeBase):
    metadata = MetaData(schema=SCHEMA)


class Paper(Base):
    __tablename__ = "paper"
    __table_args__ = (
        CheckConstraint(f"status in {PAPER_STATUSES}", name="paper_status"),
        CheckConstraint(f"engine in {PAPER_ENGINES}", name="paper_engine"),
        CheckConstraint(f"release_policy in {RELEASE_POLICIES}", name="paper_release_policy"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    gate: Mapped[str] = mapped_column(String(80), nullable=False)
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False, default="")
    max_attempts: Mapped[int] = mapped_column(Integer, nullable=False)
    status: Mapped[str] = mapped_column(String(10), nullable=False, default="draft")
    engine: Mapped[str] = mapped_column(String(10), nullable=False, default="v2")
    engine_base_id: Mapped[int | None] = mapped_column(Integer)  # the engine assessment cohort 1 sits
    release_policy: Mapped[str] = mapped_column(String(20), nullable=False, default="manual")
    assigned_ttl_days: Mapped[int] = mapped_column(Integer, nullable=False, default=14)
    generation: Mapped[int] = mapped_column(Integer, nullable=False, default=1)  # bumped by a rotate
    # the engine assessment as last read: duration, question count and types, pass bar, proctoring rules
    snapshot: Mapped[dict[str, Any] | None] = mapped_column(JSONB)
    snapshot_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # who linked or wrote the paper and who published it: they may have read the answers, so they never sit it
    created_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    published_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    # the quiz engine's own columns, kept for its retired papers
    duration_minutes: Mapped[int | None] = mapped_column(Integer)
    pass_mark: Mapped[Decimal | None] = mapped_column(SCORE)
    questions: Mapped[list[dict[str, Any]] | None] = mapped_column(JSONB)


class Cohort(Base):
    """One engine assessment of a paper: everyone's attempt `attempt_no` of generation `generation` sits it."""

    __tablename__ = "cohort"
    __table_args__ = (
        CheckConstraint(f"state in {COHORT_STATES}", name="cohort_state"),
        Index(
            "ix_cohort_one_running",
            "paper_id",
            "attempt_no",
            unique=True,
            postgresql_where="state in ('draft', 'open')",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    paper_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.paper.id"), nullable=False)
    attempt_no: Mapped[int] = mapped_column(Integer, nullable=False)
    generation: Mapped[int] = mapped_column(Integer, nullable=False)
    engine_assessment_id: Mapped[int] = mapped_column(Integer, nullable=False, unique=True)
    state: Mapped[str] = mapped_column(String(10), nullable=False, default="draft")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class Sitting(Base):
    __tablename__ = "sitting"
    __table_args__ = (
        CheckConstraint(f"status in {SITTING_STATUSES}", name="sitting_status"),
        Index(
            "ix_sitting_one_open_per_paper",
            "paper_id",
            "worker_id",
            unique=True,
            postgresql_where=f"status in {OPEN}",
        ),
        Index("ix_sitting_worker", "worker_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    paper_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.paper.id"), nullable=False)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="assigned")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    cohort_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey(f"{SCHEMA}.cohort.id"))
    attempt_no: Mapped[int | None] = mapped_column(Integer)
    engine_attempt_id: Mapped[int | None] = mapped_column(Integer, unique=True)
    engine_state: Mapped[str | None] = mapped_column(String(16))
    result: Mapped[str | None] = mapped_column(String(10))
    released: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    held_reason: Mapped[str | None] = mapped_column(String(40))  # why a submitted sitting has no result yet
    flags: Mapped[dict[str, Any] | None] = mapped_column(JSONB)
    deadline: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    submitted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    score: Mapped[Decimal | None] = mapped_column(SCORE)
    # the quiz engine's own columns
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    answers: Mapped[dict[str, Any] | None] = mapped_column(JSONB)


class Certification(Base):
    """The gate a worker earned by passing a paper. One per worker and gate; the first pass wins."""

    __tablename__ = "certification"

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    gate: Mapped[str] = mapped_column(String(80), primary_key=True)
    paper_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.paper.id"), nullable=False)
    score: Mapped[Decimal] = mapped_column(SCORE, nullable=False)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class WorkerLink(Base):
    """Who a Yantra person is in the engine (a v2 user and its hr.applicant), cached after the first launch."""

    __tablename__ = "worker_link"

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    engine_user_id: Mapped[int] = mapped_column(Integer, nullable=False)
    engine_applicant_id: Mapped[int | None] = mapped_column(Integer)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class EngineCursor(Base):
    """Where the sync last read the engine's attempts from (the engine's own clock, less an overlap)."""

    __tablename__ = "engine_cursor"

    name: Mapped[str] = mapped_column(String(40), primary_key=True)
    since: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


OUTBOX = outbox_table(Base.metadata, SCHEMA)
CONSUMED = consumed_table(Base.metadata, SCHEMA)
DEAD = dead_table(Base.metadata, SCHEMA)
JOB_LEASE = job_lease_table(Base.metadata, SCHEMA)
TABLES = [t.fullname for t in reversed(Base.metadata.sorted_tables)]
