"""tracker: consent withdrawals (no sessions or samples while withdrawn), erasures (the objects go on the hourly
purge), and the `consent` end reason of a session.

Revision ID: 0002
Revises: 0001
"""

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

S = "tracker"
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "consent_withdrawal",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("withdrawn_at", TS, nullable=False),
        schema=S,
    )
    op.create_table(
        "erasure",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("erased_at", TS, nullable=False),
        sa.Column("objects_purged_at", TS),
        schema=S,
    )
    op.create_index(
        "ix_erasure_objects_pending",
        "erasure",
        ["erased_at"],
        schema=S,
        postgresql_where=sa.text("objects_purged_at is null"),
    )
    op.drop_constraint("session_end_reason", "activity_session", schema=S, type_="check")
    op.create_check_constraint(
        "session_end_reason",
        "activity_session",
        "end_reason in ('client', 'stale', 'claim_ended', 'consent')",
        schema=S,
    )


def downgrade() -> None:
    op.drop_constraint("session_end_reason", "activity_session", schema=S, type_="check")
    op.create_check_constraint(
        "session_end_reason", "activity_session", "end_reason in ('client', 'stale', 'claim_ended')", schema=S
    )
    op.drop_table("erasure", schema=S)
    op.drop_table("consent_withdrawal", schema=S)
