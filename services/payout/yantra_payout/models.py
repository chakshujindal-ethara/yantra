"""Tables of the payout schema. Money tables are append-only in spirit: an earning is never edited, a window is
never reopened; corrections are new rows."""

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Literal, get_args

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
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
from yantra_common.scheduler import job_lease_table
from yantra_payout import SCHEMA

MONEY = Numeric(18, 6)
EarningKind = Literal["unit", "review", "audit", "adjust"]
EarningStatus = Literal["payable", "windowed", "paid"]
WindowStatus = Literal["closed", "approved", "paying", "paid"]
LineStatus = Literal["payable", "held", "queued", "processing", "paid", "failed", "returned", "released"]
AccountStatus = Literal["verifying", "verified", "failed"]
Verification = Literal["penny_drop", "none"]
AdjustmentKind = Literal["bonus", "correction"]
AdjustmentStatus = Literal["pending", "approved", "rejected"]
EARNING_KINDS = get_args(EarningKind)
EARNING_STATUSES = get_args(EarningStatus)
WINDOW_STATUSES = get_args(WindowStatus)
LINE_STATUSES = get_args(LineStatus)
ADJUSTMENT_KINDS = get_args(AdjustmentKind)
ADJUSTMENT_STATUSES = get_args(AdjustmentStatus)
ACCOUNT_STATUSES = get_args(AccountStatus)
VERIFICATIONS = get_args(Verification)


class Base(DeclarativeBase):
    metadata = MetaData(schema=SCHEMA)


class BatchRate(Base):
    """Read model from `work.unit.published`: what a unit pays and earns, frozen at publish."""

    __tablename__ = "batch_rate"

    batch_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    unit_pay: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    unit_price: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    review_pay: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)


class WorkerAccount(Base):
    __tablename__ = "worker_account"

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    first_paid_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    hold_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    hold_reason: Mapped[str | None] = mapped_column(String(40))
    # withdrawn data-processing consent holds payouts on its own, beside (never instead of) any hold above; the
    # event time of the last consent event applied makes an older one arriving late change nothing
    consent_withdrawn: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False, server_default="false")
    consent_changed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class Earning(Base):
    """One earning per verdict event and kind: the event id is the idempotency key for money. An approved
    adjustment is an earning of kind `adjust` whose event, unit and batch ids are all the adjustment's id: an
    adjustment has no unit, and the unique (event_id, kind) pair makes a second approval impossible."""

    __tablename__ = "earning"
    __table_args__ = (
        UniqueConstraint("event_id", "kind", name="earning_one_per_event_kind"),
        CheckConstraint(f"kind in {EARNING_KINDS}", name="earning_kind"),
        CheckConstraint(f"status in {EARNING_STATUSES}", name="earning_status"),
        CheckConstraint("amount >= 0", name="earning_nonneg"),
        Index("ix_earning_payable", "worker_id", "created_at", postgresql_where="status = 'payable'"),
        Index("ix_earning_window", "window_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    event_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    kind: Mapped[str] = mapped_column(String(10), nullable=False)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    unit_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    batch_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    amount: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    status: Mapped[str] = mapped_column(String(10), nullable=False, default="payable")
    window_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class CostLedger(Base):
    """Every cost line of a unit, one row per verdict event (a resubmission adds a row). Margin is price
    minus every line."""

    __tablename__ = "cost_ledger"

    unit_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    event_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    batch_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    accepted: Mapped[bool] = mapped_column(Boolean, nullable=False)
    price: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    pay: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    review: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    audit: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    billable_rework: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class PayWindow(Base):
    __tablename__ = "pay_window"
    __table_args__ = (
        UniqueConstraint("ends_at", "currency", name="window_one_per_period"),
        CheckConstraint(f"status in {WINDOW_STATUSES}", name="window_status"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    status: Mapped[str] = mapped_column(String(10), nullable=False, default="closed")
    gross_total: Mapped[Decimal] = mapped_column(MONEY, nullable=False, default=Decimal("0"))
    held_total: Mapped[Decimal] = mapped_column(MONEY, nullable=False, default=Decimal("0"))
    closed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    paid_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    rail_reference: Mapped[str | None] = mapped_column(Text)
    rail: Mapped[str | None] = mapped_column(String(20))
    paid_total: Mapped[Decimal] = mapped_column(MONEY, nullable=False, default=Decimal("0"))
    reconciled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # a window over the per-window cap is paid only when finance says so, with a reason (the audit trail)
    cap_override_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    cap_override_reason: Mapped[str | None] = mapped_column(Text)
    cap_override_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class WindowLine(Base):
    """One worker's money in one window. A paying line walks queued -> processing -> paid | failed | returned on
    the rail; finance retries a failed line (a new attempt, a new idempotency key) or releases it (its earnings go
    back to payable for the next close). The idempotency key is written before the rail is called, so a crash
    between the two can never pay twice."""

    __tablename__ = "window_line"
    __table_args__ = (
        UniqueConstraint("window_id", "worker_id", name="line_one_per_worker"),
        CheckConstraint(f"status in {LINE_STATUSES}", name="line_status"),
        Index("ix_line_in_flight", "status", postgresql_where="status in ('queued', 'processing')"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    window_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.pay_window.id"), nullable=False)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    gross: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    earning_count: Mapped[int] = mapped_column(nullable=False)
    status: Mapped[str] = mapped_column(String(10), nullable=False)
    hold_reason: Mapped[str | None] = mapped_column(String(40))
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    idempotency_key: Mapped[str | None] = mapped_column(Text)
    rail: Mapped[str | None] = mapped_column(String(20))
    rail_reference: Mapped[str | None] = mapped_column(Text)
    rail_status: Mapped[str | None] = mapped_column(String(20))
    utr: Mapped[str | None] = mapped_column(String(40))
    rail_amount: Mapped[Decimal | None] = mapped_column(MONEY)
    failure_reason: Mapped[str | None] = mapped_column(Text)
    submitted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    settled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # the account (its keyed digest) checked at dispatch: the bank file pays that account or none
    paid_account_hash: Mapped[str | None] = mapped_column(String(64))


class BankAccount(Base):
    """The one account a worker is paid into, owned by the module that pays. The number is sealed under
    `YANTRA_BANK_KEY` (AES-256-GCM, the worker id as associated data); only its last four, the IFSC and a keyed
    digest of `ifsc:number` (one account per worker across the platform) are readable. Never logged, never in an
    event, never in a response."""

    __tablename__ = "bank_account"
    __table_args__ = (
        CheckConstraint(f"status in {ACCOUNT_STATUSES}", name="bank_account_status"),
        CheckConstraint(f"verification in {VERIFICATIONS}", name="bank_account_verification"),
        UniqueConstraint("account_hash", name="bank_account_one_per_number"),
        Index("ix_bank_account_verifying", "status", postgresql_where="status = 'verifying'"),
    )

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    account_name: Mapped[str] = mapped_column(Text, nullable=False)
    account_name_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    account_last4: Mapped[str] = mapped_column(String(4), nullable=False)
    ifsc: Mapped[str] = mapped_column(String(11), nullable=False)
    account_sealed: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    key_id: Mapped[str] = mapped_column(String(16), nullable=False)
    account_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(10), nullable=False, default="verifying")
    verification: Mapped[str] = mapped_column(String(12), nullable=False, default="penny_drop")
    rail: Mapped[str] = mapped_column(String(20), nullable=False)
    rail_contact_id: Mapped[str | None] = mapped_column(Text)
    rail_fund_account_id: Mapped[str | None] = mapped_column(Text)
    validation_id: Mapped[str | None] = mapped_column(Text)
    registered_name_match: Mapped[bool | None] = mapped_column(Boolean)
    failure_reason: Mapped[str | None] = mapped_column(String(40))
    validations_today: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    validations_reset_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    erasure_requested_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # a penny drop that proved no registered name pays nothing until finance confirms the account
    confirmed_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    confirmed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class WebhookEvent(Base):
    """Every rail webhook seen, keyed by the rail's event id: a replay is answered 200 and applied once. The raw
    body is never stored (it carries beneficiary names); its digest is."""

    __tablename__ = "webhook_event"

    id: Mapped[str] = mapped_column(String(80), primary_key=True)
    rail: Mapped[str] = mapped_column(String(20), nullable=False)
    event_type: Mapped[str] = mapped_column(String(60), nullable=False)
    body_sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    line_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    worker_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    applied: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    note: Mapped[str | None] = mapped_column(String(40))
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class ReconciliationRun(Base):
    """One reconciliation of a window: what was earned, lined, paid and what the rail says it moved. Reports,
    never adjusts. `details` carries line ids only."""

    __tablename__ = "reconciliation_run"
    __table_args__ = (Index("ix_reconciliation_window", "window_id", "ran_at"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    window_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.pay_window.id"), nullable=False)
    ran_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    earnings_total: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    lines_total: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    paid_total: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    rail_total: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    delta_lines: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    delta_rail: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    failed_lines: Mapped[int] = mapped_column(Integer, nullable=False)
    processing_lines: Mapped[int] = mapped_column(Integer, nullable=False)
    balanced: Mapped[bool] = mapped_column(Boolean, nullable=False)
    details: Mapped[dict[str, object]] = mapped_column(JSONB, nullable=False, default=dict)


class Adjustment(Base):
    """A bonus or a correction, always positive, proposed by one operator and decided by a different one.
    Approval creates the `adjust` earning; a rejection moves no money. Decided once, never edited."""

    __tablename__ = "adjustment"
    __table_args__ = (
        CheckConstraint(f"kind in {ADJUSTMENT_KINDS}", name="adjustment_kind"),
        CheckConstraint(f"status in {ADJUSTMENT_STATUSES}", name="adjustment_status"),
        CheckConstraint("amount > 0", name="adjustment_positive"),
        Index("ix_adjustment_status", "status", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    amount: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    kind: Mapped[str] = mapped_column(String(10), nullable=False)
    reason: Mapped[str] = mapped_column(Text, nullable=False)
    status: Mapped[str] = mapped_column(String(10), nullable=False, default="pending")
    proposed_by: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    decided_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    decision_note: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Approval(Base):
    __tablename__ = "approval"

    window_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.pay_window.id"), primary_key=True)
    approver: Mapped[str] = mapped_column(String(200), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


OUTBOX = outbox_table(Base.metadata, SCHEMA)
CONSUMED = consumed_table(Base.metadata, SCHEMA)
DEAD = dead_table(Base.metadata, SCHEMA)
JOB_LEASE = job_lease_table(Base.metadata, SCHEMA)
TABLES = [t.fullname for t in reversed(Base.metadata.sorted_tables)]
