"""market: client organisations and members, the project's client-facing fields and rubric log, project
feedback, the verdict log, and the `unknown` placeholder status on worker_profile.

`worker_profile.status` gains `unknown`: a certification can arrive before Odoo or onboarding has said anything
about the person, and the gate must not be lost. `unknown` is what `GET /v1/workers/me` already answers for an
absent row, so the app sees the same word either way; a worker in `unknown` cannot claim.

Revision ID: 0005
Revises: 0004
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None

S = "market"
NOW = sa.func.now()


def upgrade() -> None:
    op.drop_constraint("worker_status", "worker_profile", schema=S, type_="check")
    op.create_check_constraint(
        "worker_status",
        "worker_profile",
        "status in ('unknown', 'eligible', 'active', 'suspended', 'offboarded')",
        schema=S,
    )
    op.create_table(
        "client_org",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )
    op.create_table(
        "client_member",
        sa.Column("org_id", sa.Uuid(), sa.ForeignKey(f"{S}.client_org.id"), primary_key=True),
        sa.Column("user_id", sa.Uuid(), primary_key=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )
    op.create_index("ix_client_member_user", "client_member", ["user_id"], schema=S)
    op.add_column(
        "client_project",
        sa.Column("client_org_id", sa.Uuid(), sa.ForeignKey(f"{S}.client_org.id"), nullable=True),
        schema=S,
    )
    op.add_column("client_project", sa.Column("brief", sa.Text(), nullable=True), schema=S)
    op.add_column("client_project", sa.Column("llm_policy", sa.Text(), nullable=True), schema=S)
    op.add_column(
        "client_project",
        sa.Column("sensitive", sa.Boolean(), nullable=False, server_default=sa.false()),
        schema=S,
    )
    op.add_column(
        "client_project",
        sa.Column("rubric_log", JSONB(), nullable=False, server_default=sa.text("'[]'::jsonb")),
        schema=S,
    )
    op.create_index("ix_client_project_org", "client_project", ["client_org_id"], schema=S)
    op.create_table(
        "project_feedback",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("project_id", sa.Uuid(), sa.ForeignKey(f"{S}.client_project.id"), nullable=False),
        sa.Column("author_id", sa.Uuid(), nullable=False),
        sa.Column("body", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )
    op.create_index("ix_project_feedback_project", "project_feedback", ["project_id", "created_at"], schema=S)
    op.create_table(
        "verdict_log",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("event_id", sa.Uuid(), nullable=False, unique=True),
        sa.Column("unit_id", sa.Uuid(), nullable=False),
        sa.Column("batch_id", sa.Uuid(), nullable=False),
        sa.Column("project_id", sa.Uuid(), nullable=False),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("verdict", sa.String(20), nullable=False),
        sa.Column("reason_code", sa.String(60), nullable=True),
        sa.Column("billable", sa.Boolean(), nullable=False),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("verdict in ('accept', 'reject', 'needs_edits')", name="verdict_log_verdict"),
        schema=S,
    )
    op.create_index("ix_verdict_log_project", "verdict_log", ["project_id"], schema=S)
    op.create_index("ix_verdict_log_batch", "verdict_log", ["batch_id"], schema=S)


def downgrade() -> None:
    op.drop_table("verdict_log", schema=S)
    op.drop_table("project_feedback", schema=S)
    op.drop_index("ix_client_project_org", "client_project", schema=S)
    for column in ("rubric_log", "sensitive", "llm_policy", "brief", "client_org_id"):
        op.drop_column("client_project", column, schema=S)
    op.drop_table("client_member", schema=S)
    op.drop_table("client_org", schema=S)
    op.drop_constraint("worker_status", "worker_profile", schema=S, type_="check")
    op.create_check_constraint(
        "worker_status", "worker_profile", "status in ('eligible', 'active', 'suspended', 'offboarded')", schema=S
    )
