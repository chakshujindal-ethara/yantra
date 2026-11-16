"""quality: hand-set gates apply in order (`gates_seq`), and a claim may end because the holder lost the clearance
or gate the task needs (`review_release.reason` revoked)

Revision ID: 0008
Revises: 0007
"""

import sqlalchemy as sa
from alembic import op

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None

S = "quality"


def upgrade() -> None:
    op.create_table(
        "gates_seq",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("seq", sa.BigInteger(), nullable=False),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False),
        schema=S,
    )
    op.drop_constraint("review_release_reason", "review_release", schema=S, type_="check")
    op.create_check_constraint(
        "review_release_reason", "review_release", "reason in ('expired', 'holder', 'revoked')", schema=S
    )


def downgrade() -> None:
    op.execute(f"UPDATE {S}.review_release SET reason = 'expired' WHERE reason = 'revoked'")
    op.drop_constraint("review_release_reason", "review_release", schema=S, type_="check")
    op.create_check_constraint("review_release_reason", "review_release", "reason in ('expired', 'holder')", schema=S)
    op.drop_table("gates_seq", schema=S)
