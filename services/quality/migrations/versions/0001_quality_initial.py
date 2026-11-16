"""quality: initial tables

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

S = "quality"
NOW = sa.func.now()


def upgrade() -> None:
    op.create_table(
        "review_task",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("unit_id", sa.Uuid(), nullable=False),
        sa.Column("batch_id", sa.Uuid(), nullable=False),
        sa.Column("submission_id", sa.Uuid(), nullable=False),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("rubric_version", sa.String(40), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("sampled_for_audit", sa.Boolean(), nullable=False),
        sa.Column("reviewer_id", sa.Uuid()),
        sa.Column("auditor_id", sa.Uuid()),
        sa.Column("claim_expires_at", sa.DateTime(timezone=True)),
        sa.Column("canonical_verdict", sa.String(20)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.UniqueConstraint("submission_id", name="task_one_per_submission"),
        sa.CheckConstraint(
            "status in ('pending', 'claimed', 'audit_pending', 'audit_claimed', 'canonical')", name="task_status"
        ),
        schema=S,
    )
    op.create_index("ix_task_queue", "review_task", ["status", "created_at"], schema=S)
    op.create_index(
        "ix_task_one_live_per_reviewer",
        "review_task",
        ["reviewer_id"],
        unique=True,
        schema=S,
        postgresql_where=sa.text("status = 'claimed'"),
    )
    op.create_index(
        "ix_task_one_live_per_auditor",
        "review_task",
        ["auditor_id"],
        unique=True,
        schema=S,
        postgresql_where=sa.text("status = 'audit_claimed'"),
    )
    op.create_table(
        "review",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("task_id", sa.Uuid(), sa.ForeignKey(f"{S}.review_task.id"), nullable=False),
        sa.Column("kind", sa.String(10), nullable=False),
        sa.Column("reviewer_id", sa.Uuid(), nullable=False),
        sa.Column("verdict", sa.String(20), nullable=False),
        sa.Column("reason_code", sa.String(40)),
        sa.Column("rubric_unclear", sa.Boolean(), nullable=False),
        sa.Column("note", sa.Text()),
        sa.Column("feedback", postgresql.JSONB(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.UniqueConstraint("task_id", "kind", name="review_one_per_kind"),
        sa.CheckConstraint("verdict in ('accept', 'needs_edits', 'reject')", name="review_verdict"),
        sa.CheckConstraint("kind in ('review', 'audit')", name="review_kind"),
        schema=S,
    )
    op.create_table(
        "rubric_flag",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("task_id", sa.Uuid(), sa.ForeignKey(f"{S}.review_task.id"), nullable=False),
        sa.Column("batch_id", sa.Uuid(), nullable=False),
        sa.Column("reviewer_id", sa.Uuid(), nullable=False),
        sa.Column("note", sa.Text(), nullable=False),
        sa.Column("answered_at", sa.DateTime(timezone=True)),
        sa.Column("answer", sa.Text()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )
    md = sa.MetaData()
    outbox_table(md, S)
    consumed_table(md, S)
    dead_table(md, S)
    md.create_all(op.get_bind())


def downgrade() -> None:
    for t in ("dead_event", "consumed_event", "outbox", "rubric_flag", "review", "review_task"):
        op.drop_table(t, schema=S)
