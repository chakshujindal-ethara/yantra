"""talent: drop onboarding.bank_hash (an unkeyed sha256 of the account number nothing read)

Revision ID: 0002
Revises: 0001
"""

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

S = "talent"


def upgrade() -> None:
    op.drop_column("onboarding", "bank_hash", schema=S)


def downgrade() -> None:
    op.add_column("onboarding", sa.Column("bank_hash", sa.String(64)), schema=S)
