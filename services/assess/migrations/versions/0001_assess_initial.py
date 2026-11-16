"""assess: initial tables

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

S = "assess"
NOW = sa.func.now()
SCORE = sa.Numeric(5, 4)


def upgrade() -> None:
    op.create_table(
        "paper",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("gate", sa.String(80), nullable=False),
        sa.Column("title", sa.String(200), nullable=False),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column("duration_minutes", sa.Integer(), nullable=False),
        sa.Column("pass_mark", SCORE, nullable=False),
        sa.Column("max_attempts", sa.Integer(), nullable=False),
        sa.Column("questions", postgresql.JSONB(), nullable=False),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("published_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint("status in ('draft', 'published')", name="paper_status"),
        schema=S,
    )
    op.create_table(
        "sitting",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("paper_id", sa.Uuid(), sa.ForeignKey(f"{S}.paper.id"), nullable=False),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("submitted_at", sa.DateTime(timezone=True)),
        sa.Column("answers", postgresql.JSONB()),
        sa.Column("score", SCORE),
        sa.Column("status", sa.String(10), nullable=False),
        sa.CheckConstraint("status in ('live', 'passed', 'failed', 'expired')", name="sitting_status"),
        schema=S,
    )
    op.create_index(
        "ix_sitting_one_live_per_paper",
        "sitting",
        ["paper_id", "worker_id"],
        unique=True,
        schema=S,
        postgresql_where=sa.text("status = 'live'"),
    )
    op.create_index("ix_sitting_worker", "sitting", ["worker_id", "started_at"], schema=S)
    op.create_table(
        "certification",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("gate", sa.String(80), primary_key=True),
        sa.Column("paper_id", sa.Uuid(), sa.ForeignKey(f"{S}.paper.id"), nullable=False),
        sa.Column("score", SCORE, nullable=False),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False),
        schema=S,
    )
    md = sa.MetaData()
    outbox_table(md, S)
    consumed_table(md, S)
    dead_table(md, S)
    md.create_all(op.get_bind())


def downgrade() -> None:
    for t in ("dead_event", "consumed_event", "outbox", "certification", "sitting", "paper"):
        op.drop_table(t, schema=S)
