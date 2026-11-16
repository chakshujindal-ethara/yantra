"""assess: papers backed by an assessment engine (Ethara's Assessment v2), cohorts per attempt, engine-tracked
sittings, the worker link and the sync cursor. The quiz engine's papers are retired (their certifications stand,
their finished sittings still count as attempts); its columns stay for reading them.

Revision ID: 0004
Revises: 0003
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None

S = "assess"
NOW = sa.func.now()
SITTING_STATUSES = "('assigned', 'in_progress', 'awaiting_result', 'passed', 'failed', 'void', 'live', 'expired')"
OPEN = "('assigned', 'in_progress', 'awaiting_result', 'live')"


def upgrade() -> None:
    # papers: the engine columns; the quiz columns become optional; existing papers were the quiz engine's
    op.add_column("paper", sa.Column("engine", sa.String(10), nullable=False, server_default="quiz"), schema=S)
    op.alter_column("paper", "engine", server_default="v2", schema=S)
    op.add_column("paper", sa.Column("engine_base_id", sa.Integer()), schema=S)
    op.add_column(
        "paper", sa.Column("release_policy", sa.String(20), nullable=False, server_default="manual"), schema=S
    )
    op.add_column("paper", sa.Column("assigned_ttl_days", sa.Integer(), nullable=False, server_default="14"), schema=S)
    op.add_column("paper", sa.Column("generation", sa.Integer(), nullable=False, server_default="1"), schema=S)
    op.add_column("paper", sa.Column("snapshot", postgresql.JSONB()), schema=S)
    op.add_column("paper", sa.Column("snapshot_at", sa.DateTime(timezone=True)), schema=S)
    for column in ("duration_minutes", "pass_mark", "questions"):
        op.alter_column("paper", column, nullable=True, schema=S)
    op.drop_constraint("paper_status", "paper", schema=S)
    op.execute(f"UPDATE {S}.paper SET status = 'retired' WHERE engine = 'quiz' AND status = 'published'")
    op.create_check_constraint("paper_status", "paper", "status in ('draft', 'published', 'retired')", schema=S)
    op.create_check_constraint("paper_engine", "paper", "engine in ('v2', 'fake', 'quiz')", schema=S)
    op.create_check_constraint(
        "paper_release_policy", "paper", "release_policy in ('manual', 'auto_objective')", schema=S
    )

    op.create_table(
        "cohort",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("paper_id", sa.Uuid(), sa.ForeignKey(f"{S}.paper.id"), nullable=False),
        sa.Column("attempt_no", sa.Integer(), nullable=False),
        sa.Column("generation", sa.Integer(), nullable=False),
        sa.Column("engine_assessment_id", sa.Integer(), nullable=False, unique=True),
        sa.Column("state", sa.String(10), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.CheckConstraint("state in ('draft', 'open', 'closed')", name="cohort_state"),
        schema=S,
    )
    op.create_index(
        "ix_cohort_one_running",
        "cohort",
        ["paper_id", "attempt_no"],
        unique=True,
        schema=S,
        postgresql_where=sa.text("state in ('draft', 'open')"),
    )

    # sittings: the engine columns; the quiz columns become optional
    op.add_column("sitting", sa.Column("created_at", sa.DateTime(timezone=True), server_default=NOW), schema=S)
    op.execute(f"UPDATE {S}.sitting SET created_at = started_at")
    op.alter_column("sitting", "created_at", nullable=False, schema=S)
    op.alter_column("sitting", "status", type_=sa.String(16), schema=S)
    for column in ("started_at", "expires_at"):
        op.alter_column("sitting", column, nullable=True, schema=S)
    op.add_column("sitting", sa.Column("cohort_id", sa.Uuid(), sa.ForeignKey(f"{S}.cohort.id")), schema=S)
    op.add_column("sitting", sa.Column("attempt_no", sa.Integer()), schema=S)
    op.add_column("sitting", sa.Column("engine_attempt_id", sa.Integer(), unique=True), schema=S)
    op.add_column("sitting", sa.Column("engine_state", sa.String(16)), schema=S)
    op.add_column("sitting", sa.Column("result", sa.String(10)), schema=S)
    op.add_column("sitting", sa.Column("released", sa.Boolean(), nullable=False, server_default=sa.false()), schema=S)
    op.add_column("sitting", sa.Column("held_reason", sa.String(40)), schema=S)
    op.add_column("sitting", sa.Column("flags", postgresql.JSONB()), schema=S)
    op.add_column("sitting", sa.Column("deadline", sa.DateTime(timezone=True)), schema=S)
    op.drop_constraint("sitting_status", "sitting", schema=S)
    op.create_check_constraint("sitting_status", "sitting", f"status in {SITTING_STATUSES}", schema=S)
    op.drop_index("ix_sitting_one_live_per_paper", table_name="sitting", schema=S)
    op.create_index(
        "ix_sitting_one_open_per_paper",
        "sitting",
        ["paper_id", "worker_id"],
        unique=True,
        schema=S,
        postgresql_where=sa.text(f"status in {OPEN}"),
    )
    op.drop_index("ix_sitting_worker", table_name="sitting", schema=S)
    op.create_index("ix_sitting_worker", "sitting", ["worker_id", "created_at"], schema=S)

    op.create_table(
        "worker_link",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("engine_user_id", sa.Integer(), nullable=False),
        sa.Column("engine_applicant_id", sa.Integer()),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )
    op.create_table(
        "engine_cursor",
        sa.Column("name", sa.String(40), primary_key=True),
        sa.Column("since", sa.DateTime(timezone=True)),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )


def downgrade() -> None:
    op.drop_table("engine_cursor", schema=S)
    op.drop_table("worker_link", schema=S)
    op.drop_index("ix_sitting_worker", table_name="sitting", schema=S)
    op.create_index("ix_sitting_worker", "sitting", ["worker_id", "started_at"], schema=S)
    op.drop_index("ix_sitting_one_open_per_paper", table_name="sitting", schema=S)
    # what the engine produced has no place in the quiz schema
    engine_papers = f"SELECT id FROM {S}.paper WHERE engine <> 'quiz'"
    legacy = "('live', 'passed', 'failed', 'expired')"
    op.execute(f"DELETE FROM {S}.sitting WHERE paper_id IN ({engine_papers}) OR status not in {legacy}")
    op.execute(f"DELETE FROM {S}.certification WHERE paper_id IN ({engine_papers})")
    for column in ("started_at", "expires_at"):
        op.alter_column("sitting", column, nullable=False, schema=S)
    op.create_index(
        "ix_sitting_one_live_per_paper",
        "sitting",
        ["paper_id", "worker_id"],
        unique=True,
        schema=S,
        postgresql_where=sa.text("status = 'live'"),
    )
    op.drop_constraint("sitting_status", "sitting", schema=S)
    op.create_check_constraint(
        "sitting_status", "sitting", "status in ('live', 'passed', 'failed', 'expired')", schema=S
    )
    for column in (
        "deadline",
        "flags",
        "held_reason",
        "released",
        "result",
        "engine_state",
        "engine_attempt_id",
        "attempt_no",
        "cohort_id",
        "created_at",
    ):
        op.drop_column("sitting", column, schema=S)
    op.drop_index("ix_cohort_one_running", table_name="cohort", schema=S)
    op.drop_table("cohort", schema=S)
    op.execute(f"DELETE FROM {S}.paper WHERE engine <> 'quiz'")
    op.drop_constraint("paper_release_policy", "paper", schema=S)
    op.drop_constraint("paper_engine", "paper", schema=S)
    op.drop_constraint("paper_status", "paper", schema=S)
    op.execute(f"UPDATE {S}.paper SET status = 'published' WHERE status = 'retired'")
    op.create_check_constraint("paper_status", "paper", "status in ('draft', 'published')", schema=S)
    for column in ("duration_minutes", "pass_mark", "questions"):
        op.alter_column("paper", column, nullable=False, schema=S)
    for column in ("snapshot_at", "snapshot", "generation", "assigned_ttl_days", "release_policy", "engine_base_id"):
        op.drop_column("paper", column, schema=S)
    op.drop_column("paper", "engine", schema=S)
