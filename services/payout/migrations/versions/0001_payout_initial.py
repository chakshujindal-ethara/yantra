"""payout: initial tables

Revision ID: 0001
Revises:
"""

import sqlalchemy as sa
from alembic import op

from yantra_common.consumer import consumed_table, dead_table
from yantra_common.outbox import outbox_table

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

S = "payout"
MONEY = sa.Numeric(18, 6)
NOW = sa.func.now()


def upgrade() -> None:
    op.create_table(
        "batch_rate",
        sa.Column("batch_id", sa.Uuid(), primary_key=True),
        sa.Column("unit_pay", MONEY, nullable=False),
        sa.Column("unit_price", MONEY, nullable=False),
        sa.Column("review_pay", MONEY, nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        schema=S,
    )
    op.create_table(
        "worker_account",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("first_paid_at", sa.DateTime(timezone=True)),
        sa.Column("hold_until", sa.DateTime(timezone=True)),
        sa.Column("hold_reason", sa.String(40)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )
    op.create_table(
        "earning",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("event_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.String(10), nullable=False),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("unit_id", sa.Uuid(), nullable=False),
        sa.Column("batch_id", sa.Uuid(), nullable=False),
        sa.Column("amount", MONEY, nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("window_id", sa.Uuid()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.UniqueConstraint("event_id", "kind", name="earning_one_per_event_kind"),
        sa.CheckConstraint("kind in ('unit', 'review', 'audit')", name="earning_kind"),
        sa.CheckConstraint("status in ('payable', 'windowed', 'paid')", name="earning_status"),
        sa.CheckConstraint("amount >= 0", name="earning_nonneg"),
        schema=S,
    )
    op.create_index(
        "ix_earning_payable",
        "earning",
        ["worker_id", "created_at"],
        schema=S,
        postgresql_where=sa.text("status = 'payable'"),
    )
    op.create_index("ix_earning_window", "earning", ["window_id"], schema=S)
    op.create_table(
        "cost_ledger",
        sa.Column("unit_id", sa.Uuid(), primary_key=True),
        sa.Column("event_id", sa.Uuid(), primary_key=True),
        sa.Column("batch_id", sa.Uuid(), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("accepted", sa.Boolean(), nullable=False),
        sa.Column("price", MONEY, nullable=False),
        sa.Column("pay", MONEY, nullable=False),
        sa.Column("review", MONEY, nullable=False),
        sa.Column("audit", MONEY, nullable=False),
        sa.Column("billable_rework", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )
    op.create_table(
        "pay_window",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("starts_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ends_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("gross_total", MONEY, nullable=False),
        sa.Column("held_total", MONEY, nullable=False),
        sa.Column("closed_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("paid_at", sa.DateTime(timezone=True)),
        sa.Column("rail_reference", sa.Text()),
        sa.UniqueConstraint("ends_at", "currency", name="window_one_per_period"),
        sa.CheckConstraint("status in ('closed', 'approved', 'paid')", name="window_status"),
        schema=S,
    )
    op.create_table(
        "window_line",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("window_id", sa.Uuid(), sa.ForeignKey(f"{S}.pay_window.id"), nullable=False),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("gross", MONEY, nullable=False),
        sa.Column("earning_count", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("hold_reason", sa.String(40)),
        sa.UniqueConstraint("window_id", "worker_id", name="line_one_per_worker"),
        sa.CheckConstraint("status in ('payable', 'held', 'paid')", name="line_status"),
        schema=S,
    )
    op.create_table(
        "approval",
        sa.Column("window_id", sa.Uuid(), sa.ForeignKey(f"{S}.pay_window.id"), primary_key=True),
        sa.Column("approver", sa.String(200), primary_key=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )
    md = sa.MetaData()
    outbox_table(md, S)
    consumed_table(md, S)
    dead_table(md, S)
    md.create_all(op.get_bind())


def downgrade() -> None:
    for t in (
        "consumed_event",
        "outbox",
        "approval",
        "window_line",
        "pay_window",
        "cost_ledger",
        "earning",
        "worker_account",
        "batch_rate",
    ):
        op.drop_table(t, schema=S)
