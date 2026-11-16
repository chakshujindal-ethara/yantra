"""notify: the job lease table (one row per scheduled job)

Revision ID: 0004
Revises: 0003
"""

import sqlalchemy as sa
from alembic import op

from yantra_common.scheduler import job_lease_table

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None

S = "notify"


def upgrade() -> None:
    md = sa.MetaData()
    job_lease_table(md, S)
    md.create_all(op.get_bind())


def downgrade() -> None:
    op.drop_table("job_lease", schema=S)
