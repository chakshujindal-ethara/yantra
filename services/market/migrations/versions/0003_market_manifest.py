"""market: the delivery manifest, one per batch

Revision ID: 0003
Revises: 0002
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "delivery_manifest",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("batch_id", sa.Uuid(), sa.ForeignKey("market.work_batch.id"), nullable=False, unique=True),
        sa.Column("project_id", sa.Uuid(), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("unit_price", sa.Numeric(18, 6), nullable=False),
        sa.Column("accepted_units", sa.Integer(), nullable=False),
        sa.Column("total_price", sa.Numeric(18, 6), nullable=False),
        sa.Column("digest", sa.String(64), nullable=False),
        sa.Column("units", JSONB(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        schema="market",
    )


def downgrade() -> None:
    op.drop_table("delivery_manifest", schema="market")
