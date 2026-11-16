"""payout: the bank account a worker is paid into (sealed number, penny-drop state)

Revision ID: 0004
Revises: 0003
"""

import sqlalchemy as sa
from alembic import op

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None

S = "payout"
NOW = sa.func.now()


def upgrade() -> None:
    op.create_table(
        "bank_account",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("account_name", sa.Text(), nullable=False),
        sa.Column("account_name_hash", sa.String(64), nullable=False),
        sa.Column("account_last4", sa.String(4), nullable=False),
        sa.Column("ifsc", sa.String(11), nullable=False),
        sa.Column("account_sealed", sa.LargeBinary(), nullable=False),
        sa.Column("key_id", sa.String(16), nullable=False),
        sa.Column("account_hash", sa.String(64), nullable=False),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("verification", sa.String(12), nullable=False),
        sa.Column("rail", sa.String(20), nullable=False),
        sa.Column("rail_contact_id", sa.Text()),
        sa.Column("rail_fund_account_id", sa.Text()),
        sa.Column("validation_id", sa.Text()),
        sa.Column("registered_name_match", sa.Boolean()),
        sa.Column("failure_reason", sa.String(40)),
        sa.Column("validations_today", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("validations_reset_at", sa.DateTime(timezone=True)),
        sa.Column("verified_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.CheckConstraint("status in ('verifying', 'verified', 'failed')", name="bank_account_status"),
        sa.CheckConstraint("verification in ('penny_drop', 'none')", name="bank_account_verification"),
        sa.UniqueConstraint("account_hash", name="bank_account_one_per_number"),
        schema=S,
    )
    op.create_index(
        "ix_bank_account_verifying",
        "bank_account",
        ["status"],
        schema=S,
        postgresql_where=sa.text("status = 'verifying'"),
    )


def downgrade() -> None:
    op.drop_table("bank_account", schema=S)
