"""market: initial tables

Revision ID: 0001
Revises:
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

S = "market"
MONEY = sa.Numeric(18, 6)
NOW = sa.func.now()


def upgrade() -> None:
    op.create_table(
        "worker_profile",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("partner_ref", sa.Integer()),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("cert_gates", postgresql.JSONB(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.CheckConstraint("status in ('eligible', 'active', 'suspended', 'offboarded')", name="worker_status"),
        schema=S,
    )
    op.create_table(
        "client_project",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("payload_schema", postgresql.JSONB(), nullable=False),
        sa.Column("rubric_version", sa.String(40), nullable=False),
        sa.Column("margin_floor", sa.Numeric(5, 4)),
        sa.Column("cert_gate", sa.String(80)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )
    op.create_table(
        "work_batch",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("project_id", sa.Uuid(), sa.ForeignKey(f"{S}.client_project.id"), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("mode", sa.String(10), nullable=False),
        sa.Column("unit_pay", MONEY, nullable=False),
        sa.Column("unit_price", MONEY, nullable=False),
        sa.Column("review_pay", MONEY, nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("claim_ttl_minutes", sa.Integer(), nullable=False),
        sa.Column("rubric_version", sa.String(40), nullable=False),
        sa.Column("floor_approved_by", sa.Text()),
        sa.Column("floor_approval_note", sa.Text()),
        sa.Column("published_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.CheckConstraint("status in ('draft', 'published', 'paused', 'completed', 'cancelled')", name="batch_status"),
        sa.CheckConstraint("mode in ('open', 'assigned')", name="batch_mode"),
        sa.CheckConstraint("unit_pay >= 0 and unit_price >= 0 and review_pay >= 0", name="batch_money_nonneg"),
        schema=S,
    )
    op.create_table(
        "work_unit",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("batch_id", sa.Uuid(), sa.ForeignKey(f"{S}.work_batch.id"), nullable=False),
        sa.Column("external_ref", sa.String(200), nullable=False),
        sa.Column("payload", postgresql.JSONB(), nullable=False),
        sa.Column("payload_uri", sa.Text()),
        sa.Column("unit_pay", MONEY),
        sa.Column("unit_price", MONEY),
        sa.Column("rubric_version", sa.String(40)),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("assigned_worker_id", sa.Uuid()),
        sa.Column("current_claim_id", sa.Uuid()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.UniqueConstraint("batch_id", "external_ref", name="unit_external_ref"),
        sa.CheckConstraint(
            "status in ('draft', 'available', 'claimed', 'submitted', 'in_review', "
            "'accepted', 'rejected', 'needs_edits')",
            name="unit_status",
        ),
        schema=S,
    )
    op.create_index(
        "ix_unit_available", "work_unit", ["batch_id", "id"], schema=S, postgresql_where=sa.text("status = 'available'")
    )
    op.create_table(
        "claim",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("unit_id", sa.Uuid(), sa.ForeignKey(f"{S}.work_unit.id"), nullable=False),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("idempotency_key", sa.String(200), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("worker_id", "idempotency_key", name="claim_idempotency_key"),
        sa.CheckConstraint("status in ('active', 'submitted', 'expired', 'released')", name="claim_status"),
        schema=S,
    )
    op.create_index(
        "ix_claim_one_live_per_worker",
        "claim",
        ["worker_id"],
        unique=True,
        schema=S,
        postgresql_where=sa.text("status = 'active'"),
    )
    op.create_index(
        "ix_claim_active_expiry", "claim", ["expires_at"], schema=S, postgresql_where=sa.text("status = 'active'")
    )
    op.create_table(
        "submission",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("claim_id", sa.Uuid(), sa.ForeignKey(f"{S}.claim.id"), nullable=False),
        sa.Column("unit_id", sa.Uuid(), sa.ForeignKey(f"{S}.work_unit.id"), nullable=False),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("answer", postgresql.JSONB(), nullable=False),
        sa.Column("rubric_version", sa.String(40), nullable=False),
        sa.Column("submitted_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.UniqueConstraint("claim_id", name="submission_one_per_claim"),
        schema=S,
    )
    op.create_table(
        "outbox",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("type", sa.String(120), nullable=False),
        sa.Column("subject", sa.String(200), nullable=False),
        sa.Column("payload", postgresql.JSONB(), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("published_at", sa.DateTime(timezone=True)),
        schema=S,
    )
    op.create_index(
        "ix_outbox_unpublished", "outbox", ["occurred_at"], schema=S, postgresql_where=sa.text("published_at is null")
    )


def downgrade() -> None:
    for t in ("outbox", "submission", "claim", "work_unit", "work_batch", "client_project", "worker_profile"):
        op.drop_table(t, schema=S)
