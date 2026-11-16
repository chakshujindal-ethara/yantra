"""talent: listings, applications, onboarding, worker gates, outbox, consumed and dead events

Revision ID: 0001
Revises:
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

from yantra_common.consumer import consumed_table, dead_table
from yantra_common.outbox import outbox_table

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

S = "talent"
MONEY = sa.Numeric(18, 6)
NOW = sa.func.now()
LIVE = "('applied', 'assessment', 'screening', 'offered', 'accepted')"


def upgrade() -> None:
    op.create_table(
        "listing",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("domain", sa.String(80), nullable=False),
        sa.Column("summary", sa.Text(), nullable=False),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column("pay_min", MONEY, nullable=False),
        sa.Column("pay_max", MONEY, nullable=False),
        sa.Column("pay_unit", sa.String(20), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("commitment", sa.String(20), nullable=False),
        sa.Column("hours_per_week", sa.Integer()),
        sa.Column("slots_total", sa.Integer(), nullable=False),
        sa.Column("slots_filled", sa.Integer(), nullable=False),
        sa.Column("cert_gate", sa.String(80)),
        sa.Column("paper_id", sa.Uuid()),
        sa.Column("requirements", postgresql.JSONB(), nullable=False),
        sa.Column("questions", postgresql.JSONB(), nullable=False),
        sa.Column("llm_policy", sa.Text()),
        sa.Column("sensitive", sa.Boolean(), nullable=False),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("posted_at", sa.DateTime(timezone=True)),
        sa.Column("closes_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.CheckConstraint("status in ('draft', 'open', 'closed')", name="listing_status"),
        sa.CheckConstraint("commitment in ('task_based', 'part_time')", name="listing_commitment"),
        sa.CheckConstraint("pay_min >= 0 and pay_min <= pay_max", name="listing_pay_range"),
        sa.CheckConstraint("slots_total >= 1 and slots_filled between 0 and slots_total", name="listing_slots"),
        schema=S,
    )
    op.create_table(
        "application",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("listing_id", sa.Uuid(), sa.ForeignKey(f"{S}.listing.id"), nullable=False),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("steps", postgresql.JSONB(), nullable=False),
        sa.Column("answers", postgresql.JSONB(), nullable=False),
        sa.Column("note", sa.Text()),
        sa.Column("offer_expires_at", sa.DateTime(timezone=True)),
        sa.Column("decided_by", sa.Uuid()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.CheckConstraint(
            "status in ('applied', 'assessment', 'screening', 'offered', 'accepted', "
            "'declined', 'rejected', 'withdrawn', 'expired')",
            name="application_status",
        ),
        schema=S,
    )
    op.create_index(
        "ix_application_one_live",
        "application",
        ["listing_id", "worker_id"],
        unique=True,
        schema=S,
        postgresql_where=sa.text(f"status in {LIVE}"),
    )
    op.create_index("ix_application_worker", "application", ["worker_id"], schema=S)
    op.create_table(
        "onboarding",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("steps", postgresql.JSONB(), nullable=False),
        sa.Column("legal_name", sa.Text()),
        sa.Column("phone", sa.String(10)),
        sa.Column("city", sa.Text()),
        sa.Column("agreement_version", sa.String(40)),
        sa.Column("consent_at", sa.DateTime(timezone=True)),
        sa.Column("pan_hash", sa.String(64), unique=True),
        sa.Column("pan_last4", sa.String(4)),
        sa.Column("aadhaar_last4", sa.String(4)),
        sa.Column("bank_hash", sa.String(64)),
        sa.Column("bank_account_last4", sa.String(4)),
        sa.Column("ifsc", sa.String(11)),
        sa.Column("account_name", sa.Text()),
        sa.Column("payout_ack_at", sa.DateTime(timezone=True)),
        sa.Column("eligible_sent_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )
    op.create_table(
        "worker_gate",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("gate", sa.String(80), primary_key=True),
        sa.Column("source", sa.String(10), nullable=False),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("source in ('assess', 'offer')", name="worker_gate_source"),
        schema=S,
    )
    md = sa.MetaData()
    outbox_table(md, S)
    consumed_table(md, S)
    dead_table(md, S)
    md.create_all(op.get_bind())


def downgrade() -> None:
    for t in ("dead_event", "consumed_event", "outbox", "worker_gate", "onboarding", "application", "listing"):
        op.drop_table(t, schema=S)
