"""notify: support tickets

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

S = "notify"
NOW = sa.func.now()


def upgrade() -> None:
    op.create_table(
        "ticket",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("author_id", sa.Uuid(), nullable=False),
        sa.Column("category", sa.String(10), nullable=False),
        sa.Column("title", sa.String(140), nullable=False),
        sa.Column("body", sa.Text(), nullable=False),
        sa.Column("screen", sa.String(200)),
        sa.Column("context", JSONB(), nullable=False, server_default=sa.text("'{}'::jsonb")),
        sa.Column("status", sa.String(12), nullable=False),
        sa.Column("note", sa.Text()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.CheckConstraint("category in ('bug', 'payment', 'work', 'account', 'other')", name="ticket_category"),
        sa.CheckConstraint("status in ('open', 'in_progress', 'resolved')", name="ticket_status"),
        schema=S,
    )
    op.create_index("ix_ticket_author", "ticket", ["author_id", "created_at"], schema=S)
    op.create_index("ix_ticket_board", "ticket", ["status", "created_at"], schema=S)


def downgrade() -> None:
    op.drop_index("ix_ticket_board", "ticket", schema=S)
    op.drop_index("ix_ticket_author", "ticket", schema=S)
    op.drop_table("ticket", schema=S)
