"""notify: email verification. An address is used only once its owner typed the code mailed to it; the addresses
set before this revision were never verified, so they become pending (the worker asks for a code from the app).

Revision ID: 0006
Revises: 0005
"""

import sqlalchemy as sa
from alembic import op

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None

S = "notify"
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.add_column("channel", sa.Column("email_verified_at", TS), schema=S)
    op.add_column("channel", sa.Column("pending_email", sa.String(320)), schema=S)
    op.add_column("channel", sa.Column("verify_nonce", sa.String(64)), schema=S)
    op.add_column("channel", sa.Column("verify_expires_at", TS), schema=S)
    op.add_column("channel", sa.Column("verify_attempts", sa.Integer(), nullable=False, server_default="0"), schema=S)
    op.add_column("channel", sa.Column("verify_sent_at", TS), schema=S)
    op.add_column("channel", sa.Column("verify_error", sa.String(200)), schema=S)
    op.execute(f"update {S}.channel set pending_email = email, email = null where email is not null")


def downgrade() -> None:
    op.execute(f"update {S}.channel set email = coalesce(email, pending_email)")
    for column in (
        "verify_error",
        "verify_sent_at",
        "verify_attempts",
        "verify_expires_at",
        "verify_nonce",
        "pending_email",
        "email_verified_at",
    ):
        op.drop_column("channel", column, schema=S)
