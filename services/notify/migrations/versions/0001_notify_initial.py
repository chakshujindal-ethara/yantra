"""notify: channel, notification, consumed_event, dead_event

Revision ID: 0001
Revises:
"""

import sqlalchemy as sa
from alembic import op

from yantra_common.consumer import consumed_table, dead_table

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

S = "notify"
NOW = sa.func.now()


def upgrade() -> None:
    op.create_table(
        "channel",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("email", sa.String(320)),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )
    op.create_table(
        "notification",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("event_id", sa.Uuid(), nullable=False, unique=True),
        sa.Column("kind", sa.String(40), nullable=False),
        sa.Column("subject", sa.String(200), nullable=False),
        sa.Column("body", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("read_at", sa.DateTime(timezone=True)),
        sa.Column("emailed_at", sa.DateTime(timezone=True)),
        sa.Column("email_attempts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("email_error", sa.String(200)),
        schema=S,
    )
    op.create_index("ix_notification_inbox", "notification", ["worker_id", "created_at"], schema=S)
    op.create_index(
        "ix_notification_unsent",
        "notification",
        ["created_at"],
        schema=S,
        postgresql_where=sa.text("emailed_at IS NULL AND email_error IS NULL"),
    )
    md = sa.MetaData()
    consumed_table(md, S)
    dead_table(md, S)
    md.create_all(op.get_bind())


def downgrade() -> None:
    for table in ("dead_event", "consumed_event", "notification", "channel"):
        op.drop_table(table, schema=S)
