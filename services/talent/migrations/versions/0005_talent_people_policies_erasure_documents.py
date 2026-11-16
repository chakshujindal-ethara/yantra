"""talent: people (display names), versioned policies seeded with version 1 of every text, erasure requests, worker
documents, the consent version, listing steps, and the paper result on an application.

Revision ID: 0005
Revises: 0004
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

from yantra_common.people import person_table
from yantra_talent.policies_seed import POLICIES

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None

S = "talent"
NOW = sa.func.now()
DOCUMENT_KINDS = ("identity_front", "identity_back", "address_proof", "signed_agreement")


def upgrade() -> None:
    md = sa.MetaData()
    person_table(md, S)
    md.create_all(op.get_bind())
    policy = op.create_table(
        "policy",
        sa.Column("slug", sa.String(40), primary_key=True),
        sa.Column("revision", sa.Integer, primary_key=True),
        sa.Column("label", sa.String(40), nullable=False),
        sa.Column("title", sa.Text, nullable=False),
        sa.Column("summary", sa.Text, nullable=False),
        sa.Column("sections", JSONB, nullable=False),
        sa.Column("effective_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("created_by", sa.Uuid),
        schema=S,
    )
    op.bulk_insert(
        policy,
        [{**{k: p[k] for k in ("slug", "label", "title", "summary", "sections")}, "revision": 1} for p in POLICIES],
    )
    op.create_table(
        "erasure",
        sa.Column("worker_id", sa.Uuid, primary_key=True),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("requested_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("due_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("approved_at", sa.DateTime(timezone=True)),
        sa.Column("approved_by", sa.Uuid),
        sa.Column("done_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint("status in ('requested', 'approved', 'done')", name="erasure_status"),
        schema=S,
    )
    op.create_index("ix_erasure_due", "erasure", ["due_at"], schema=S, postgresql_where=sa.text("status <> 'done'"))
    op.create_table(
        "worker_document",
        sa.Column("worker_id", sa.Uuid, primary_key=True),
        sa.Column("kind", sa.String(20), primary_key=True),
        sa.Column("key", sa.Text, nullable=False),
        sa.Column("sha256", sa.String(64), nullable=False),
        sa.Column("size_bytes", sa.Integer, nullable=False),
        sa.Column("content_type", sa.String(100), nullable=False),
        sa.Column("uploaded_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.CheckConstraint(f"kind in {DOCUMENT_KINDS}", name="worker_document_kind"),
        schema=S,
    )
    op.add_column("onboarding", sa.Column("consent_version", sa.String(40)), schema=S)
    op.add_column(
        "listing", sa.Column("steps", JSONB, nullable=False, server_default=sa.text("""'["form"]'::jsonb""")), schema=S
    )
    op.execute(
        f"""UPDATE {S}.listing SET steps = '["form", "paper", "availability"]'::jsonb WHERE paper_id IS NOT NULL"""
    )
    op.add_column("application", sa.Column("paper_result", JSONB), schema=S)
    op.create_index(
        "ix_application_hired",
        "application",
        ["listing_id", "updated_at"],
        schema=S,
        postgresql_where=sa.text("status = 'accepted'"),
    )


def downgrade() -> None:
    op.drop_index("ix_application_hired", table_name="application", schema=S)
    op.drop_column("application", "paper_result", schema=S)
    op.drop_column("listing", "steps", schema=S)
    op.drop_column("onboarding", "consent_version", schema=S)
    op.drop_table("worker_document", schema=S)
    op.drop_index("ix_erasure_due", table_name="erasure", schema=S)
    op.drop_table("erasure", schema=S)
    op.drop_table("policy", schema=S)
    op.drop_table("person", schema=S)
