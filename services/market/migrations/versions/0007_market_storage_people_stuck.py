"""market: stored media and deliverables, released claims, one live claim per unit, the feedback thread's author,
delivery dates, retention, display names and payout holds

Revision ID: 0007
Revises: 0006
"""

import sqlalchemy as sa
from alembic import op

from yantra_common.people import person_table

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None

S = "market"
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.add_column("delivery_manifest", sa.Column("deliverable_key", sa.Text()), schema=S)
    op.add_column("delivery_manifest", sa.Column("deliverable_sha256", sa.String(64)), schema=S)
    op.add_column("delivery_manifest", sa.Column("deliverable_bytes", sa.Integer()), schema=S)
    op.add_column("delivery_manifest", sa.Column("deliverable_lines", sa.Integer()), schema=S)
    op.add_column("delivery_manifest", sa.Column("deliverable_at", TS), schema=S)
    op.add_column("claim", sa.Column("released_at", TS), schema=S)
    op.add_column("claim", sa.Column("released_by", sa.Uuid()), schema=S)
    op.create_index(
        "ix_claim_one_live_per_unit",
        "claim",
        ["unit_id"],
        unique=True,
        schema=S,
        postgresql_where=sa.text("status = 'active'"),
    )
    op.create_index(
        "ix_claim_released_at", "claim", ["released_at"], schema=S, postgresql_where=sa.text("released_at is not null")
    )
    op.add_column(
        "project_feedback",
        sa.Column("author_kind", sa.String(10), nullable=False, server_default="client"),
        schema=S,
    )
    op.create_check_constraint(
        "feedback_author_kind", "project_feedback", "author_kind in ('client', 'staff')", schema=S
    )
    op.add_column("work_batch", sa.Column("due_at", TS), schema=S)
    op.add_column("work_batch", sa.Column("purged_at", TS), schema=S)
    op.add_column(
        "client_project", sa.Column("retention_days", sa.Integer(), nullable=False, server_default="180"), schema=S
    )
    op.add_column("client_project", sa.Column("closed_at", TS), schema=S)
    op.create_check_constraint(
        "project_retention_days", "client_project", "retention_days between 1 and 3650", schema=S
    )
    md = sa.MetaData()
    person_table(md, S)
    md.create_all(op.get_bind())
    op.create_table(
        "worker_hold",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("reason", sa.Text()),
        sa.Column("until", TS),
        sa.Column("updated_at", TS, nullable=False),
        schema=S,
    )


def downgrade() -> None:
    op.drop_table("worker_hold", schema=S)
    op.drop_table("person", schema=S)
    op.drop_constraint("project_retention_days", "client_project", schema=S, type_="check")
    op.drop_column("client_project", "closed_at", schema=S)
    op.drop_column("client_project", "retention_days", schema=S)
    op.drop_column("work_batch", "purged_at", schema=S)
    op.drop_column("work_batch", "due_at", schema=S)
    op.drop_constraint("feedback_author_kind", "project_feedback", schema=S, type_="check")
    op.drop_column("project_feedback", "author_kind", schema=S)
    op.drop_index("ix_claim_released_at", "claim", schema=S)
    op.drop_index("ix_claim_one_live_per_unit", "claim", schema=S)
    op.drop_column("claim", "released_by", schema=S)
    op.drop_column("claim", "released_at", schema=S)
    for c in ("deliverable_at", "deliverable_lines", "deliverable_bytes", "deliverable_sha256", "deliverable_key"):
        op.drop_column("delivery_manifest", c, schema=S)
