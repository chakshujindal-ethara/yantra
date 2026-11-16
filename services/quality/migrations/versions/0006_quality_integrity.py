"""quality: who may review what (the task's gate and sensitive flag, reviewer clearance, reviewer gates), the reason
taxonomy as data, and the history of released review claims

Revision ID: 0006
Revises: 0005
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None

S = "quality"
TS = sa.DateTime(timezone=True)
NOW = sa.func.now()
BOTH = ["needs_edits", "reject"]
REASONS = [
    ("guideline_miss", "Guideline miss", "The answer ignores a rule in the guidelines.", False),
    ("incomplete", "Incomplete", "A required part of the answer is missing.", False),
    ("wrong_language", "Wrong language", "The answer is not in the language the unit asks for.", False),
    ("low_quality", "Low quality", "Complete, but below the bar the rubric sets.", False),
    (
        "client_glossary_change",
        "Client changed the glossary",
        "Correct when written; the client moved the target.",
        True,
    ),
    ("client_ambiguous_instruction", "Client instruction was ambiguous", "The brief allowed this reading.", True),
]


def upgrade() -> None:
    op.add_column("review_task", sa.Column("project_id", sa.Uuid()), schema=S)
    op.add_column("review_task", sa.Column("cert_gate", sa.String(80)), schema=S)
    op.add_column(
        "review_task", sa.Column("sensitive", sa.Boolean(), nullable=False, server_default=sa.false()), schema=S
    )
    op.create_index("ix_task_queue_gate", "review_task", ["status", "sensitive", "cert_gate", "created_at"], schema=S)
    op.create_table(
        "reviewer",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("sensitive_cleared", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("set_by", sa.Uuid()),
        sa.Column("updated_at", TS, nullable=False, server_default=NOW),
        schema=S,
    )
    op.create_table(
        "reviewer_gate",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("gate", sa.String(80), primary_key=True),
        sa.Column("source", sa.String(10), nullable=False),
        sa.Column("at", TS, nullable=False),
        sa.CheckConstraint("source in ('assess', 'offer')", name="reviewer_gate_source"),
        schema=S,
    )
    reason = op.create_table(
        "reason",
        sa.Column("code", sa.String(40), primary_key=True),
        sa.Column("label", sa.Text(), nullable=False),
        sa.Column("detail", sa.Text(), nullable=False, server_default=""),
        sa.Column("billable", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("applies_to", JSONB(), nullable=False),
        sa.Column("sort", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("updated_at", TS, nullable=False, server_default=NOW),
        schema=S,
    )
    op.bulk_insert(
        reason,
        [
            {"code": c, "label": label, "detail": d, "billable": b, "applies_to": BOTH, "sort": i, "active": True}
            for i, (c, label, d, b) in enumerate(REASONS)
        ],
    )
    op.create_table(
        "review_release",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("task_id", sa.Uuid(), sa.ForeignKey(f"{S}.review_task.id"), nullable=False),
        sa.Column("kind", sa.String(10), nullable=False),
        sa.Column("holder_id", sa.Uuid(), nullable=False),
        sa.Column("reason", sa.String(10), nullable=False),
        sa.Column("released_by", sa.Uuid()),
        sa.Column("expires_at", TS),
        sa.Column("released_at", TS, nullable=False),
        sa.CheckConstraint("reason in ('expired', 'holder')", name="review_release_reason"),
        sa.CheckConstraint("kind in ('review', 'audit')", name="review_release_kind"),
        schema=S,
    )
    op.create_index("ix_review_release_at", "review_release", ["released_at"], schema=S)


def downgrade() -> None:
    op.drop_index("ix_review_release_at", "review_release", schema=S)
    op.drop_table("review_release", schema=S)
    op.drop_table("reason", schema=S)
    op.drop_table("reviewer_gate", schema=S)
    op.drop_table("reviewer", schema=S)
    op.drop_index("ix_task_queue_gate", "review_task", schema=S)
    for c in ("sensitive", "cert_gate", "project_id"):
        op.drop_column("review_task", c, schema=S)
