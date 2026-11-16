"""assess: who created and who published a paper (they may not sit it).

Revision ID: 0003
Revises: 0002
"""

import sqlalchemy as sa
from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None

S = "assess"


def upgrade() -> None:
    op.add_column("paper", sa.Column("created_by", sa.Uuid()), schema=S)
    op.add_column("paper", sa.Column("published_by", sa.Uuid()), schema=S)


def downgrade() -> None:
    op.drop_column("paper", "published_by", schema=S)
    op.drop_column("paper", "created_by", schema=S)
