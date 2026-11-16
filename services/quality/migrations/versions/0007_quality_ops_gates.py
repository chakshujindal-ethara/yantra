"""quality: a reviewer gate may come from an operator's hand (`worker.gates.set.v1`), not only a paper or an offer

Revision ID: 0007
Revises: 0006
"""

from alembic import op

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None

S = "quality"


def upgrade() -> None:
    op.drop_constraint("reviewer_gate_source", "reviewer_gate", schema=S, type_="check")
    op.create_check_constraint(
        "reviewer_gate_source", "reviewer_gate", "source in ('assess', 'offer', 'ops')", schema=S
    )


def downgrade() -> None:
    op.execute(f"DELETE FROM {S}.reviewer_gate WHERE source = 'ops'")
    op.drop_constraint("reviewer_gate_source", "reviewer_gate", schema=S, type_="check")
    op.create_check_constraint("reviewer_gate_source", "reviewer_gate", "source in ('assess', 'offer')", schema=S)
