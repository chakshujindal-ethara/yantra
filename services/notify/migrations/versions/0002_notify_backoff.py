"""notify: when the next email attempt may run

Revision ID: 0002
Revises: 0001
"""

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("notification", sa.Column("next_attempt_at", sa.DateTime(timezone=True)), schema="notify")


def downgrade() -> None:
    op.drop_column("notification", "next_attempt_at", schema="notify")
