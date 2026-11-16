"""quality: who resolved a dispute (the ops caller's worker id)

Revision ID: 0004
Revises: 0003
"""

import sqlalchemy as sa
from alembic import op

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None

S = "quality"


def upgrade() -> None:
    op.add_column("dispute", sa.Column("resolved_by", sa.Uuid(), nullable=True), schema=S)


def downgrade() -> None:
    op.drop_column("dispute", "resolved_by", schema=S)
