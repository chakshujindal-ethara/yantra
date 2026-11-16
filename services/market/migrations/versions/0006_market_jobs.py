"""market: the job lease table (one row per scheduled job)

Revision ID: 0006
Revises: 0005
"""

import sqlalchemy as sa
from alembic import op

from yantra_common.scheduler import job_lease_table

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None

S = "market"


def upgrade() -> None:
    md = sa.MetaData()
    job_lease_table(md, S)
    md.create_all(op.get_bind())


def downgrade() -> None:
    op.drop_table("job_lease", schema=S)
