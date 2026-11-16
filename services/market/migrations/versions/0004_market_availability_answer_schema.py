"""market: the worker's availability check-in and the project's answer schema

Revision ID: 0004
Revises: 0003
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "worker_availability",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("weekly_hours", sa.Integer(), nullable=False),
        sa.Column("paused_until", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("weekly_hours between 0 and 80", name="availability_weekly_hours"),
        schema="market",
    )
    op.add_column("client_project", sa.Column("answer_schema", JSONB(), nullable=True), schema="market")


def downgrade() -> None:
    op.drop_column("client_project", "answer_schema", schema="market")
    op.drop_table("worker_availability", schema="market")
