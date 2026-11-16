"""market: hand-set gates kept apart from earned ones (so a hand-set replaces only its own), the worker's consent
state, and when a unit was assigned and who took an assignment off

Revision ID: 0008
Revises: 0007
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None

S = "market"
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.add_column("worker_profile", sa.Column("earned_gates", JSONB(), nullable=False, server_default="[]"), schema=S)
    op.add_column("worker_profile", sa.Column("ops_gates", JSONB(), nullable=False, server_default="[]"), schema=S)
    op.add_column("worker_profile", sa.Column("gates_seq", sa.Integer(), nullable=False, server_default="0"), schema=S)
    op.add_column("worker_profile", sa.Column("consent_withdrawn_at", TS), schema=S)
    op.add_column("worker_profile", sa.Column("consent_at", TS), schema=S)
    # which existing gate came from a hand-set is unknown: keep them all as earned, so no later hand-set drops one
    op.execute(f"UPDATE {S}.worker_profile SET earned_gates = cert_gates")
    op.add_column("work_unit", sa.Column("assigned_at", TS), schema=S)
    op.add_column("work_unit", sa.Column("unassigned_by", sa.Uuid()), schema=S)
    op.add_column("work_unit", sa.Column("unassigned_at", TS), schema=S)
    op.execute(f"UPDATE {S}.work_unit SET assigned_at = created_at WHERE assigned_worker_id IS NOT NULL")
    op.create_index(
        "ix_unit_assigned_waiting",
        "work_unit",
        ["assigned_at"],
        schema=S,
        postgresql_where=sa.text("status = 'available' and assigned_worker_id is not null"),
    )


def downgrade() -> None:
    op.drop_index("ix_unit_assigned_waiting", "work_unit", schema=S)
    for column in ("unassigned_at", "unassigned_by", "assigned_at"):
        op.drop_column("work_unit", column, schema=S)
    for column in ("consent_at", "consent_withdrawn_at", "gates_seq", "ops_gates", "earned_gates"):
        op.drop_column("worker_profile", column, schema=S)
