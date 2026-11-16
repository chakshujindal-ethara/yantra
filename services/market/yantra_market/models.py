"""Tables of the market schema. Names follow the repository's DATAMODEL.md; the additions are
`unit_price` frozen next to `unit_pay`, `rubric_version` on every unit, the margin floor with its approval, the
worker's own availability statement and the project's optional answer schema."""

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
    UniqueConstraint,
    Uuid,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from yantra_common.consumer import consumed_table, dead_table
from yantra_common.outbox import outbox_table
from yantra_common.people import person_table
from yantra_common.scheduler import job_lease_table
from yantra_market import SCHEMA

MONEY = Numeric(18, 6)
UnitStatus = Literal["draft", "available", "claimed", "submitted", "in_review", "accepted", "rejected", "needs_edits"]
BatchStatus = Literal["draft", "published", "paused", "completed", "cancelled"]
BatchMode = Literal["open", "assigned"]
ClaimStatus = Literal["active", "submitted", "expired", "released"]
WorkerStatus = Literal["eligible", "active", "suspended", "offboarded"]
ProjectStatus = Literal["draft", "active", "closed"]
Verdict = Literal["accept", "reject", "needs_edits"]
FeedbackAuthor = Literal["client", "staff"]
UNKNOWN = "unknown"  # the placeholder a profile is born with when a gate arrives before eligibility; never claims
UNIT_STATUSES = get_args(UnitStatus)
BATCH_STATUSES = get_args(BatchStatus)
BATCH_MODES = get_args(BatchMode)
CLAIM_STATUSES = get_args(ClaimStatus)
WORKER_STATUSES = get_args(WorkerStatus)
PROFILE_STATUSES = (UNKNOWN, *WORKER_STATUSES)
VERDICTS = get_args(Verdict)
FEEDBACK_AUTHORS = get_args(FeedbackAuthor)


class Base(DeclarativeBase):
    metadata = MetaData(schema=SCHEMA)


class WorkerProfile(Base):
    """Read model built from `worker.eligible`, `assess.certified`, `talent.offer.accepted` and the consent events
    (and Odoo's PUT). Never the source of truth for a person. `unknown` is the row a gate creates before
    eligibility. `cert_gates` is what claims test: the gates earned from events (`earned_gates`) joined with the
    ones set by hand (`ops_gates`, replaced whole on every hand-set, counted by `gates_seq`)."""

    __tablename__ = "worker_profile"
    __table_args__ = (CheckConstraint(f"status in {PROFILE_STATUSES}", name="worker_status"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    partner_ref: Mapped[int | None] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(20), nullable=False)
    cert_gates: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=list)
    earned_gates: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=list)
    ops_gates: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=list)
    gates_seq: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    # set while the worker's data-processing consent is withdrawn: no new claims. `consent_at` is the time of the
    # newest consent event applied, so an older one arriving late changes nothing
    consent_withdrawn_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    consent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class WorkerAvailability(Base):
    """The worker's weekly check-in: the hours they offer and, when set, a pause that hides every pool until it
    lapses. Their own statement, so a row exists with or without a profile; never a measure of eligibility."""

    __tablename__ = "worker_availability"
    __table_args__ = (CheckConstraint("weekly_hours between 0 and 80", name="availability_weekly_hours"),)

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    weekly_hours: Mapped[int] = mapped_column(Integer, nullable=False)
    paused_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class ClientOrg(Base):
    """A lab or vendor buying work. Its members are the `client` callers who may read its projects."""

    __tablename__ = "client_org"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class ClientMember(Base):
    __tablename__ = "client_member"
    __table_args__ = (Index("ix_client_member_user", "user_id"),)

    org_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.client_org.id"), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class ClientProject(Base):
    """`rubric_log` keeps every rubric bump as `{version, note, at}` so a client can read why acceptance moved."""

    __tablename__ = "client_project"
    __table_args__ = (
        Index("ix_client_project_org", "client_org_id"),
        CheckConstraint("retention_days between 1 and 3650", name="project_retention_days"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="draft")
    payload_schema: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    answer_schema: Mapped[dict[str, Any] | None] = mapped_column(JSONB)
    rubric_version: Mapped[str] = mapped_column(String(40), nullable=False, default="v1")
    margin_floor: Mapped[Decimal | None] = mapped_column(Numeric(5, 4))
    cert_gate: Mapped[str | None] = mapped_column(String(80))
    client_org_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey(f"{SCHEMA}.client_org.id"))
    brief: Mapped[str | None] = mapped_column(Text)
    llm_policy: Mapped[str | None] = mapped_column(Text)
    sensitive: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    rubric_log: Mapped[list[dict[str, Any]]] = mapped_column(JSONB, nullable=False, default=list)
    retention_days: Mapped[int] = mapped_column(Integer, nullable=False, default=180)
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class ProjectFeedback(Base):
    """One note in a project's thread: a client's (`author_kind` client) or an operator's answer (`staff`)."""

    __tablename__ = "project_feedback"
    __table_args__ = (
        Index("ix_project_feedback_project", "project_id", "created_at"),
        CheckConstraint(f"author_kind in {FEEDBACK_AUTHORS}", name="feedback_author_kind"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    project_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.client_project.id"), nullable=False)
    author_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    author_kind: Mapped[str] = mapped_column(String(10), nullable=False, default="client")
    body: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class WorkBatch(Base):
    __tablename__ = "work_batch"
    __table_args__ = (
        CheckConstraint(f"status in {BATCH_STATUSES}", name="batch_status"),
        CheckConstraint(f"mode in {BATCH_MODES}", name="batch_mode"),
        CheckConstraint("unit_pay >= 0 and unit_price >= 0 and review_pay >= 0", name="batch_money_nonneg"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    project_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.client_project.id"), nullable=False)
    title: Mapped[str] = mapped_column(Text, nullable=False)
    mode: Mapped[str] = mapped_column(String(10), nullable=False, default="open")
    unit_pay: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    unit_price: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    review_pay: Mapped[Decimal] = mapped_column(MONEY, nullable=False, default=Decimal("0"))
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="draft")
    claim_ttl_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=240)
    rubric_version: Mapped[str] = mapped_column(String(40), nullable=False)
    floor_approved_by: Mapped[str | None] = mapped_column(Text)
    floor_approval_note: Mapped[str | None] = mapped_column(Text)
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))  # the client's delivery date
    purged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))  # retention ran out
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class WorkUnit(Base):
    __tablename__ = "work_unit"
    __table_args__ = (
        UniqueConstraint("batch_id", "external_ref", name="unit_external_ref"),
        CheckConstraint(f"status in {UNIT_STATUSES}", name="unit_status"),
        Index("ix_unit_available", "batch_id", "id", postgresql_where="status = 'available'"),
        Index(
            "ix_unit_assigned_waiting",
            "assigned_at",
            postgresql_where="status = 'available' and assigned_worker_id is not null",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    batch_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.work_batch.id"), nullable=False)
    external_ref: Mapped[str] = mapped_column(String(200), nullable=False)
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    payload_uri: Mapped[str | None] = mapped_column(Text)
    unit_pay: Mapped[Decimal | None] = mapped_column(MONEY)
    unit_price: Mapped[Decimal | None] = mapped_column(MONEY)
    rubric_version: Mapped[str | None] = mapped_column(String(40))
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="draft")
    assigned_worker_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    assigned_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))  # since when it waits for them
    unassigned_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)  # the operator who last took an assignment off
    unassigned_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    current_claim_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class Claim(Base):
    """`idempotency_key` is unique per worker: a key is the worker's own retry handle, never a shared name."""

    __tablename__ = "claim"
    __table_args__ = (
        UniqueConstraint("worker_id", "idempotency_key", name="claim_idempotency_key"),
        CheckConstraint(f"status in {CLAIM_STATUSES}", name="claim_status"),
        Index("ix_claim_one_live_per_worker", "worker_id", unique=True, postgresql_where="status = 'active'"),
        # a unit is never held twice: the double-claim alert guards a state this index makes impossible
        Index("ix_claim_one_live_per_unit", "unit_id", unique=True, postgresql_where="status = 'active'"),
        Index("ix_claim_released_at", "released_at", postgresql_where="released_at is not null"),
        Index("ix_claim_active_expiry", "expires_at", postgresql_where="status = 'active'"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    unit_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.work_unit.id"), nullable=False)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(200), nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="active")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    # set when the claim ended without a submission: by the expiry job (no `released_by`), an operator's release
    # of an expired claim (their id) or the worker giving it back (`status` released, their own id)
    released_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    released_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)


class Submission(Base):
    __tablename__ = "submission"
    __table_args__ = (UniqueConstraint("claim_id", name="submission_one_per_claim"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    claim_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.claim.id"), nullable=False)
    unit_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.work_unit.id"), nullable=False)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    answer: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    rubric_version: Mapped[str] = mapped_column(String(40), nullable=False)
    submitted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class DeliveryManifest(Base):
    """One per batch, built when every unit is accepted: the accepted units, their answers and the price."""

    __tablename__ = "delivery_manifest"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    batch_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.work_batch.id"), nullable=False, unique=True)
    project_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    unit_price: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    accepted_units: Mapped[int] = mapped_column(Integer, nullable=False)
    total_price: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    digest: Mapped[str] = mapped_column(String(64), nullable=False)
    units: Mapped[list[dict[str, Any]]] = mapped_column(JSONB, nullable=False)
    # the deliverable files in object storage, written on the first download and reused after
    deliverable_key: Mapped[str | None] = mapped_column(Text)
    deliverable_sha256: Mapped[str | None] = mapped_column(String(64))
    deliverable_bytes: Mapped[int | None] = mapped_column(Integer)
    deliverable_lines: Mapped[int | None] = mapped_column(Integer)
    deliverable_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class VerdictLog(Base):
    """A read model of every canonical verdict, one row per event: what the reason distributions, acceptance rates
    and the client's billable-rework count read. `event_id` is unique so a redelivered verdict writes nothing."""

    __tablename__ = "verdict_log"
    __table_args__ = (
        CheckConstraint(f"verdict in {VERDICTS}", name="verdict_log_verdict"),
        Index("ix_verdict_log_project", "project_id"),
        Index("ix_verdict_log_batch", "batch_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    event_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False, unique=True)
    unit_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    batch_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    project_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    verdict: Mapped[str] = mapped_column(String(20), nullable=False)
    reason_code: Mapped[str | None] = mapped_column(String(60))
    billable: Mapped[bool] = mapped_column(Boolean, nullable=False)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class WorkerHold(Base):
    """Payout holds, from `payout.hold.set`: the bench shows who is held. A hold whose `until` has passed (or is
    null: lifted) holds nothing."""

    __tablename__ = "worker_hold"

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    reason: Mapped[str | None] = mapped_column(Text)
    until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


# display names, from `talent.person.seen`: what the bench, the feedback thread and `/v1/people` show
PERSON = person_table(Base.metadata, SCHEMA)
OUTBOX = outbox_table(Base.metadata, SCHEMA)
CONSUMED = consumed_table(Base.metadata, SCHEMA)
DEAD = dead_table(Base.metadata, SCHEMA)
JOB_LEASE = job_lease_table(Base.metadata, SCHEMA)
# every table of the schema, children first, for TRUNCATE in tests
TABLES = [t.fullname for t in reversed(Base.metadata.sorted_tables)]
