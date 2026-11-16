"""Tables of the analytics schema: the event warehouse, two small dimensions learnt from events (which batch a unit
belongs to, a batch's project and rates), the marts recomputed from the warehouse, the insert-only baselines the
leadership numbers are compared with, and a control table for the refresh cursor and the rebuild drill."""

import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Any

from sqlalchemy import Boolean, Date, DateTime, Index, Integer, MetaData, Numeric, String, Text, Uuid, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from yantra_analytics import SCHEMA
from yantra_common.consumer import consumed_table, dead_table
from yantra_common.scheduler import job_lease_table

MONEY = Numeric(18, 6)


class Base(DeclarativeBase):
    metadata = MetaData(schema=SCHEMA)


class Event(Base):
    """Every event seen in the retention (`YANTRA_ANALYTICS_RETENTION_DAYS`, 400 days), keyed by its CloudEvent id.
    `payload` is the minimised payload (`minimise.py`), never the event as sent. The id columns are pulled out of it
    when present."""

    __tablename__ = "event"
    __table_args__ = (
        Index("ix_event_type_time", "type", "time"),
        Index("ix_event_project", "project_id", "time", postgresql_where=text("project_id is not null")),
        Index("ix_event_worker", "worker_id", "time", postgresql_where=text("worker_id is not null")),
        Index("ix_event_unit", "unit_id", postgresql_where=text("unit_id is not null")),
        Index("ix_event_ingested", "ingested_at"),
        Index("ix_event_time", "time"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    type: Mapped[str] = mapped_column(String(120), nullable=False)
    subject: Mapped[str] = mapped_column(String(200), nullable=False)
    time: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    worker_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    project_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    batch_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    unit_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    listing_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    window_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    payload: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    ingested_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class DimBatch(Base):
    __tablename__ = "dim_batch"
    __table_args__ = (Index("ix_dim_batch_project", "project_id"),)

    batch_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    project_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    currency: Mapped[str | None] = mapped_column(String(3))
    unit_pay: Mapped[Decimal | None] = mapped_column(MONEY)
    unit_price: Mapped[Decimal | None] = mapped_column(MONEY)
    review_pay: Mapped[Decimal | None] = mapped_column(MONEY)
    unit_count: Mapped[int | None] = mapped_column(Integer)
    mode: Mapped[str | None] = mapped_column(String(20))
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class DimUnit(Base):
    """Which batch a unit belongs to, learnt from any event that names both (a claim names only the unit)."""

    __tablename__ = "dim_unit"

    unit_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    batch_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)


class MartProjectDay(Base):
    __tablename__ = "mart_project_day"

    project_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    day: Mapped[date] = mapped_column(Date, primary_key=True)
    currency: Mapped[str] = mapped_column(String(3), primary_key=True)
    units_published: Mapped[int] = mapped_column(Integer, nullable=False)
    units_claimed: Mapped[int] = mapped_column(Integer, nullable=False)
    units_submitted: Mapped[int] = mapped_column(Integer, nullable=False)
    units_accepted: Mapped[int] = mapped_column(Integer, nullable=False)
    units_rejected: Mapped[int] = mapped_column(Integer, nullable=False)
    first_pass_num: Mapped[int] = mapped_column(Integer, nullable=False)
    first_pass_den: Mapped[int] = mapped_column(Integer, nullable=False)
    pay: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    price: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    review_cost: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    audit_cost: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    margin: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    refreshed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class MartFunnelDay(Base):
    __tablename__ = "mart_funnel_day"

    listing_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    day: Mapped[date] = mapped_column(Date, primary_key=True)
    applied: Mapped[int] = mapped_column(Integer, nullable=False)
    assessment: Mapped[int] = mapped_column(Integer, nullable=False)
    screening: Mapped[int] = mapped_column(Integer, nullable=False)
    offered: Mapped[int] = mapped_column(Integer, nullable=False)
    accepted: Mapped[int] = mapped_column(Integer, nullable=False)
    rejected: Mapped[int] = mapped_column(Integer, nullable=False)
    declined: Mapped[int] = mapped_column(Integer, nullable=False)
    withdrawn: Mapped[int] = mapped_column(Integer, nullable=False)
    expired: Mapped[int] = mapped_column(Integer, nullable=False)
    refreshed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class MartWorkerWeek(Base):
    __tablename__ = "mart_worker_week"

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    week_start: Mapped[date] = mapped_column(Date, primary_key=True)
    active_seconds: Mapped[int] = mapped_column(Integer, nullable=False)
    units_accepted: Mapped[int] = mapped_column(Integer, nullable=False)
    units_judged: Mapped[int] = mapped_column(Integer, nullable=False)
    earnings: Mapped[dict[str, str]] = mapped_column(JSONB, nullable=False)  # {currency: amount}
    refreshed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class MartQualityDay(Base):
    __tablename__ = "mart_quality_day"

    project_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    day: Mapped[date] = mapped_column(Date, primary_key=True)
    accepted: Mapped[int] = mapped_column(Integer, nullable=False)
    rejected: Mapped[int] = mapped_column(Integer, nullable=False)
    needs_edits: Mapped[int] = mapped_column(Integer, nullable=False)
    reasons: Mapped[dict[str, int]] = mapped_column(JSONB, nullable=False)
    billable: Mapped[int] = mapped_column(Integer, nullable=False)
    audited: Mapped[int] = mapped_column(Integer, nullable=False)
    refreshed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class MartPayoutWindow(Base):
    __tablename__ = "mart_payout_window"

    window_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    closed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    line_count: Mapped[int] = mapped_column(Integer, nullable=False)
    gross_total: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    held_total: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    paid_total: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    workers_paid: Mapped[int] = mapped_column(Integer, nullable=False)
    paid_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    on_time: Mapped[bool | None] = mapped_column(Boolean)
    refreshed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class Baseline(Base):
    """Insert-only: the latest row by `set_at` is the one the leadership numbers compare against."""

    __tablename__ = "baseline"
    __table_args__ = (Index("ix_baseline_set_at", "set_at"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    days_to_staff: Mapped[Decimal | None] = mapped_column(Numeric(8, 2))
    idle_cost_weekly: Mapped[Decimal | None] = mapped_column(MONEY)
    first_pass_acceptance: Mapped[Decimal | None] = mapped_column(Numeric(5, 4))
    cost_per_accepted_unit: Mapped[Decimal | None] = mapped_column(MONEY)
    idle_hourly_cost: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    idle_hours_per_week: Mapped[int] = mapped_column(Integer, nullable=False)
    staffing_workers: Mapped[int] = mapped_column(Integer, nullable=False)
    rail_fee_per_payout: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    levy_rate: Mapped[Decimal] = mapped_column(Numeric(6, 4), nullable=False)
    payout_sla_days: Mapped[int] = mapped_column(Integer, nullable=False)
    note: Mapped[str | None] = mapped_column(Text)
    set_by: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    set_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ErasedWorker(Base):
    """A worker whose personal data was erased (`worker.erasure.completed.v1`), by the keyed digest of their id (never
    the id itself), and the random pseudonym that replaced the id in every warehouse row and mart. Events naming the
    worker that arrive later (or again, in a rebuild) are stored under the pseudonym too, so counts stay whole."""

    __tablename__ = "erased_worker"

    id_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    pseudonym: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False, unique=True)
    erased_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class Control(Base):
    """Small named documents: `refresh` (the mart cursor) and `rebuild` (the replay drill's state)."""

    __tablename__ = "control"

    key: Mapped[str] = mapped_column(String(40), primary_key=True)
    value: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


CONSUMED = consumed_table(Base.metadata, SCHEMA)
DEAD = dead_table(Base.metadata, SCHEMA)
JOB_LEASE = job_lease_table(Base.metadata, SCHEMA)
TABLES = [t.fullname for t in reversed(Base.metadata.sorted_tables)]
MARTS = [MartProjectDay, MartFunnelDay, MartWorkerWeek, MartQualityDay, MartPayoutWindow]
