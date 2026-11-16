"""quality: the task keeps its own copy of the payload and the answer for the reviewer

Revision ID: 0002
Revises: 0001
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("review_task", sa.Column("payload", JSONB(), nullable=True), schema="quality")
    op.add_column("review_task", sa.Column("answer", JSONB(), nullable=True), schema="quality")


def downgrade() -> None:
    op.drop_column("review_task", "answer", schema="quality")
    op.drop_column("review_task", "payload", schema="quality")
