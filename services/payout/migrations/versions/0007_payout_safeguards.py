"""payout: who paid a window over its cap and why, the bank account a line was dispatched to, finance's
confirmation of an account whose penny drop proved no name, and when the worker's consent last changed

Revision ID: 0007
Revises: 0006
"""

import sqlalchemy as sa
from alembic import op

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None

S = "payout"
COLUMNS = (
    ("pay_window", "cap_override_by", sa.Uuid()),
    ("pay_window", "cap_override_reason", sa.Text()),
    ("pay_window", "cap_override_at", sa.DateTime(timezone=True)),
    ("window_line", "paid_account_hash", sa.String(64)),
    ("bank_account", "confirmed_by", sa.Uuid()),
    ("bank_account", "confirmed_at", sa.DateTime(timezone=True)),
    ("worker_account", "consent_changed_at", sa.DateTime(timezone=True)),
)


def upgrade() -> None:
    for table, name, type_ in COLUMNS:
        op.add_column(table, sa.Column(name, type_), schema=S)
    op.add_column(
        "worker_account",
        sa.Column("consent_withdrawn", sa.Boolean(), nullable=False, server_default=sa.false()),
        schema=S,
    )


def downgrade() -> None:
    op.drop_column("worker_account", "consent_withdrawn", schema=S)
    for table, name, _ in reversed(COLUMNS):
        op.drop_column(table, name, schema=S)
