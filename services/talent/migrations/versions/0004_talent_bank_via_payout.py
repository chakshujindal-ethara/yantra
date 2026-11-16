"""talent: the bank account moves to payout. Talent keeps only the keyed digest of the verified account name and when
the account was verified; the last four, the IFSC and the account name now live with the module that pays.

Revision ID: 0004
Revises: 0003
"""

import sqlalchemy as sa
from alembic import op

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None

S = "talent"


def upgrade() -> None:
    op.add_column("onboarding", sa.Column("account_name_hash", sa.String(64)), schema=S)
    op.add_column("onboarding", sa.Column("account_verified_at", sa.DateTime(timezone=True)), schema=S)
    for column in ("bank_account_last4", "ifsc", "account_name"):
        op.drop_column("onboarding", column, schema=S)


def downgrade() -> None:
    op.add_column("onboarding", sa.Column("account_name", sa.Text), schema=S)
    op.add_column("onboarding", sa.Column("ifsc", sa.String(11)), schema=S)
    op.add_column("onboarding", sa.Column("bank_account_last4", sa.String(4)), schema=S)
    op.drop_column("onboarding", "account_verified_at", schema=S)
    op.drop_column("onboarding", "account_name_hash", schema=S)
