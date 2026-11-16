"""quality: the author's dispute of a verdict, and when a task became canonical (the dispute window counts from it)

Revision ID: 0003
Revises: 0002
"""

import sqlalchemy as sa
from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None

S = "quality"
NOW = sa.func.now()


def upgrade() -> None:
    op.add_column("review_task", sa.Column("canonical_at", sa.DateTime(timezone=True), nullable=True), schema=S)
    # a task decided before this column existed was decided by its latest review (the audit, when there was one)
    op.execute(
        f"UPDATE {S}.review_task t SET canonical_at = "
        f"(SELECT max(r.created_at) FROM {S}.review r WHERE r.task_id = t.id) WHERE t.status = 'canonical'"
    )
    op.create_table(
        "dispute",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("task_id", sa.Uuid(), sa.ForeignKey(f"{S}.review_task.id"), nullable=False),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("status", sa.String(10), nullable=False, server_default="open"),
        sa.Column("answer", sa.Text()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("resolved_at", sa.DateTime(timezone=True)),
        sa.UniqueConstraint("task_id", name="dispute_one_per_task"),
        sa.CheckConstraint("status in ('open', 'upheld', 'dismissed')", name="dispute_status"),
        schema=S,
    )


def downgrade() -> None:
    op.drop_table("dispute", schema=S)
    op.drop_column("review_task", "canonical_at", schema=S)
