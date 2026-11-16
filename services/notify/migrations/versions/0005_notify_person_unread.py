"""notify: the `person` read model (display names from `talent.person.seen.v1`) and a partial index for the unread
count the app polls.

Revision ID: 0005
Revises: 0004
"""

import sqlalchemy as sa
from alembic import op

from yantra_common.people import person_table

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None

S = "notify"


def upgrade() -> None:
    md = sa.MetaData()
    person_table(md, S)
    md.create_all(op.get_bind())
    op.create_index(
        "ix_notification_unread", "notification", ["worker_id"], schema=S, postgresql_where=sa.text("read_at IS NULL")
    )


def downgrade() -> None:
    op.drop_index("ix_notification_unread", table_name="notification", schema=S)
    op.drop_table("person", schema=S)
