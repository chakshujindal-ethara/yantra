"""quality: the job lease table (one row per scheduled job)

Revision ID: 0005
Revises: 0004
"""

import sqlalchemy as sa
from alembic import op

from yantra_common.scheduler import job_lease_table

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None

S = "quality"


def upgrade() -> None:
    md = sa.MetaData()
    job_lease_table(md, S)
    md.create_all(op.get_bind())


def downgrade() -> None:
    op.drop_table("job_lease", schema=S)
