"""payout: two-person adjustments, and `adjust` as an earning kind

Revision ID: 0002
Revises: 0001
"""

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

S = "payout"
MONEY = sa.Numeric(18, 6)
NOW = sa.func.now()


def upgrade() -> None:
    op.create_table(
        "adjustment",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("amount", MONEY, nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("kind", sa.String(10), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("proposed_by", sa.Uuid(), nullable=False),
        sa.Column("decided_by", sa.Uuid()),
        sa.Column("decision_note", sa.Text()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("decided_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint("kind in ('bonus', 'correction')", name="adjustment_kind"),
        sa.CheckConstraint("status in ('pending', 'approved', 'rejected')", name="adjustment_status"),
        sa.CheckConstraint("amount > 0", name="adjustment_positive"),
        schema=S,
    )
    op.create_index("ix_adjustment_status", "adjustment", ["status", "created_at"], schema=S)
    op.drop_constraint("earning_kind", "earning", schema=S, type_="check")
    op.create_check_constraint("earning_kind", "earning", "kind in ('unit', 'review', 'audit', 'adjust')", schema=S)


def downgrade() -> None:
    op.drop_constraint("earning_kind", "earning", schema=S, type_="check")
    op.create_check_constraint("earning_kind", "earning", "kind in ('unit', 'review', 'audit')", schema=S)
    op.drop_index("ix_adjustment_status", "adjustment", schema=S)
    op.drop_table("adjustment", schema=S)
