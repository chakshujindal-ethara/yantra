"""Tables of the tracker schema. A session is one sitting at a claim; its samples are 30-second buckets keyed by
(session, bucket start), which makes a batch idempotent and bounds active time by construction. `live_claim` is
the read model of market's claim events; `anomaly_flag` keeps at most one open flag per worker and kind, and one
over-cap flag per worker and week."""

import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Any, Literal, get_args

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Date,
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
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from yantra_common.consumer import consumed_table, dead_table
from yantra_common.outbox import outbox_table
from yantra_common.scheduler import job_lease_table
from yantra_tracker import SCHEMA

Source = Literal["web", "desktop"]
SampleKind = Literal["active", "idle", "focus_lost"]
EndReason = Literal["client", "stale", "claim_ended", "consent"]
CapScope = Literal["worker", "project"]
AnomalyKind = Literal["impossible_activity", "over_cap", "no_live_claim", "duplicate_device", "pattern"]
AnomalyStatus = Literal["open", "dismissed", "upheld"]
ClaimEnd = Literal["expired", "submitted", "released"]
SOURCES = get_args(Source)
SAMPLE_KINDS = get_args(SampleKind)
END_REASONS = get_args(EndReason)
CAP_SCOPES = get_args(CapScope)
ANOMALY_KINDS = get_args(AnomalyKind)
ANOMALY_STATUSES = get_args(AnomalyStatus)
CLAIM_ENDS = get_args(ClaimEnd)


class Base(DeclarativeBase):
    metadata = MetaData(schema=SCHEMA)


class ActivitySession(Base):
    __tablename__ = "activity_session"
    __table_args__ = (
        CheckConstraint(f"source in {SOURCES}", name="session_source"),
        CheckConstraint(f"end_reason in {END_REASONS}", name="session_end_reason"),
        CheckConstraint("active_seconds >= 0 and idle_seconds >= 0", name="session_seconds"),
        Index("ix_session_one_open", "worker_id", unique=True, postgresql_where=text("ended_at is null")),
        Index("ix_session_worker_started", "worker_id", "started_at"),
        Index("ix_session_device", "device_hash", "started_at"),
        Index("ix_session_claim", "claim_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    claim_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    project_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    source: Mapped[str] = mapped_column(String(10), nullable=False)
    device_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_sample_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    active_seconds: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    idle_seconds: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    over_cap_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    end_reason: Mapped[str | None] = mapped_column(String(12))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class ActivitySample(Base):
    """`at` is the start of the 30-second bucket; the primary key is the idempotency key of a batch."""

    __tablename__ = "activity_sample"
    __table_args__ = (
        CheckConstraint(f"kind in {SAMPLE_KINDS}", name="sample_kind"),
        Index("ix_sample_received", "received_at"),
    )

    session_id: Mapped[uuid.UUID] = mapped_column(Uuid, ForeignKey(f"{SCHEMA}.activity_session.id"), primary_key=True)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), primary_key=True)
    kind: Mapped[str] = mapped_column(String(12), nullable=False)
    label: Mapped[str | None] = mapped_column(String(80))
    over_cap: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ScreenshotRef(Base):
    """A key in object storage and its metadata. The API never serves the object itself."""

    __tablename__ = "screenshot_ref"
    __table_args__ = (Index("ix_screenshot_retention", "retention_until"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    session_id: Mapped[uuid.UUID] = mapped_column(Uuid, ForeignKey(f"{SCHEMA}.activity_session.id"), nullable=False)
    object_key: Mapped[str] = mapped_column(String(300), nullable=False, unique=True)
    content_type: Mapped[str] = mapped_column(String(60), nullable=False)
    taken_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    retention_until: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class HourCap(Base):
    __tablename__ = "hour_cap"
    __table_args__ = (
        CheckConstraint(f"scope in {CAP_SCOPES}", name="cap_scope"),
        CheckConstraint("weekly_cap_hours between 0 and 168", name="cap_hours"),
    )

    scope: Mapped[str] = mapped_column(String(10), primary_key=True)
    scope_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    weekly_cap_hours: Mapped[Decimal] = mapped_column(Numeric(5, 2), nullable=False)
    set_by: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class LiveClaim(Base):
    """market's claims as the tracker sees them: a session may only start on a claim that is still live."""

    __tablename__ = "live_claim"
    __table_args__ = (
        CheckConstraint(f"end_kind in {CLAIM_ENDS}", name="live_claim_end_kind"),
        Index("ix_live_claim_worker", "worker_id", postgresql_where=text("ended_at is null")),
    )

    claim_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    unit_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    batch_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    project_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    claimed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    end_kind: Mapped[str | None] = mapped_column(String(10))


class AnomalyFlag(Base):
    __tablename__ = "anomaly_flag"
    __table_args__ = (
        CheckConstraint(f"kind in {ANOMALY_KINDS}", name="anomaly_kind"),
        CheckConstraint(f"status in {ANOMALY_STATUSES}", name="anomaly_status"),
        Index(
            "ix_anomaly_one_open",
            "worker_id",
            "kind",
            unique=True,
            postgresql_where=text("status = 'open' and kind <> 'over_cap'"),
        ),
        Index(
            "ix_anomaly_one_cap_per_week",
            "worker_id",
            "week_start",
            unique=True,
            postgresql_where=text("kind = 'over_cap'"),
        ),
        Index("ix_anomaly_status", "status", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    session_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    kind: Mapped[str] = mapped_column(String(24), nullable=False)
    detail: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False, default=dict)
    week_start: Mapped[date | None] = mapped_column(Date)
    status: Mapped[str] = mapped_column(String(10), nullable=False, default="open")
    note: Mapped[str | None] = mapped_column(Text)
    decided_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ConsentWithdrawal(Base):
    """A worker who withdrew the data-processing consent (`worker.consent.withdrawn.v1`): no session or sample is
    taken for them until `worker.consent.given.v1` deletes the row."""

    __tablename__ = "consent_withdrawal"

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    withdrawn_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class Erasure(Base):
    """A worker whose personal data was erased (`worker.erasure.completed.v1`). The rows went at once; the objects
    under `tracker/<worker>/` go on the hourly purge, which has the storage (`objects_purged_at`)."""

    __tablename__ = "erasure"
    __table_args__ = (
        Index("ix_erasure_objects_pending", "erased_at", postgresql_where=text("objects_purged_at is null")),
    )

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    erased_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    objects_purged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


OUTBOX = outbox_table(Base.metadata, SCHEMA)
CONSUMED = consumed_table(Base.metadata, SCHEMA)
DEAD = dead_table(Base.metadata, SCHEMA)
JOB_LEASE = job_lease_table(Base.metadata, SCHEMA)
TABLES = [t.fullname for t in reversed(Base.metadata.sorted_tables)]
