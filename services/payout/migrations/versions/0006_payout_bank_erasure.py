"""payout: a bank account marked for erasure, kept until no unpaid window owes the worker money

Revision ID: 0006
Revises: 0005
"""

import sqlalchemy as sa
from alembic import op

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None

S = "payout"


def upgrade() -> None:
    op.add_column("bank_account", sa.Column("erasure_requested_at", sa.DateTime(timezone=True)), schema=S)


def downgrade() -> None:
    op.drop_column("bank_account", "erasure_requested_at", schema=S)
