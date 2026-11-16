"""market: consumed_event and dead_event tables for idempotent consumers

Revision ID: 0002
Revises: 0001
"""

import sqlalchemy as sa
from alembic import op

from yantra_common.consumer import consumed_table, dead_table

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    md = sa.MetaData()
    consumed_table(md, "market")
    dead_table(md, "market")
    md.create_all(op.get_bind())


def downgrade() -> None:
    op.drop_table("dead_event", schema="market")
    op.drop_table("consumed_event", schema="market")
