"""tracker: sessions, samples, screenshot references, hour caps, the live-claim read model, anomaly flags, outbox,
consumed and dead events, job leases

Revision ID: 0001
Revises:
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

from yantra_common.consumer import consumed_table, dead_table
from yantra_common.outbox import outbox_table
from yantra_common.scheduler import job_lease_table

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

S = "tracker"
NOW = sa.func.now()
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "activity_session",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("claim_id", sa.Uuid()),
        sa.Column("project_id", sa.Uuid()),
        sa.Column("source", sa.String(10), nullable=False),
        sa.Column("device_hash", sa.String(64), nullable=False),
        sa.Column("started_at", TS, nullable=False),
        sa.Column("ended_at", TS),
        sa.Column("last_sample_at", TS),
        sa.Column("active_seconds", sa.Integer(), nullable=False),
        sa.Column("idle_seconds", sa.Integer(), nullable=False),
        sa.Column("over_cap_at", TS),
        sa.Column("end_reason", sa.String(12)),
        sa.Column("created_at", TS, nullable=False, server_default=NOW),
        sa.CheckConstraint("source in ('web', 'desktop')", name="session_source"),
        sa.CheckConstraint("end_reason in ('client', 'stale', 'claim_ended')", name="session_end_reason"),
        sa.CheckConstraint("active_seconds >= 0 and idle_seconds >= 0", name="session_seconds"),
        schema=S,
    )
    op.create_index(
        "ix_session_one_open",
        "activity_session",
        ["worker_id"],
        unique=True,
        schema=S,
        postgresql_where=sa.text("ended_at is null"),
    )
    op.create_index("ix_session_worker_started", "activity_session", ["worker_id", "started_at"], schema=S)
    op.create_index("ix_session_device", "activity_session", ["device_hash", "started_at"], schema=S)
    op.create_index("ix_session_claim", "activity_session", ["claim_id"], schema=S)
    op.create_table(
        "activity_sample",
        sa.Column("session_id", sa.Uuid(), sa.ForeignKey(f"{S}.activity_session.id"), primary_key=True),
        sa.Column("at", TS, primary_key=True),
        sa.Column("kind", sa.String(12), nullable=False),
        sa.Column("label", sa.String(80)),
        sa.Column("over_cap", sa.Boolean(), nullable=False),
        sa.Column("received_at", TS, nullable=False),
        sa.CheckConstraint("kind in ('active', 'idle', 'focus_lost')", name="sample_kind"),
        schema=S,
    )
    op.create_index("ix_sample_received", "activity_sample", ["received_at"], schema=S)
    op.create_table(
        "screenshot_ref",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("session_id", sa.Uuid(), sa.ForeignKey(f"{S}.activity_session.id"), nullable=False),
        sa.Column("object_key", sa.String(300), nullable=False, unique=True),
        sa.Column("content_type", sa.String(60), nullable=False),
        sa.Column("taken_at", TS, nullable=False),
        sa.Column("retention_until", TS, nullable=False),
        sa.Column("created_at", TS, nullable=False, server_default=NOW),
        schema=S,
    )
    op.create_index("ix_screenshot_retention", "screenshot_ref", ["retention_until"], schema=S)
    op.create_table(
        "hour_cap",
        sa.Column("scope", sa.String(10), primary_key=True),
        sa.Column("scope_id", sa.Uuid(), primary_key=True),
        sa.Column("weekly_cap_hours", sa.Numeric(5, 2), nullable=False),
        sa.Column("set_by", sa.Uuid(), nullable=False),
        sa.Column("updated_at", TS, nullable=False),
        sa.CheckConstraint("scope in ('worker', 'project')", name="cap_scope"),
        sa.CheckConstraint("weekly_cap_hours between 0 and 168", name="cap_hours"),
        schema=S,
    )
    op.create_table(
        "live_claim",
        sa.Column("claim_id", sa.Uuid(), primary_key=True),
        sa.Column("unit_id", sa.Uuid(), nullable=False),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("batch_id", sa.Uuid()),
        sa.Column("project_id", sa.Uuid()),
        sa.Column("claimed_at", TS),
        sa.Column("expires_at", TS),
        sa.Column("ended_at", TS),
        sa.Column("end_kind", sa.String(10)),
        sa.CheckConstraint("end_kind in ('expired', 'submitted', 'released')", name="live_claim_end_kind"),
        schema=S,
    )
    op.create_index(
        "ix_live_claim_worker", "live_claim", ["worker_id"], schema=S, postgresql_where=sa.text("ended_at is null")
    )
    op.create_table(
        "anomaly_flag",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.Uuid()),
        sa.Column("kind", sa.String(24), nullable=False),
        sa.Column("detail", postgresql.JSONB(), nullable=False),
        sa.Column("week_start", sa.Date()),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("note", sa.Text()),
        sa.Column("decided_by", sa.Uuid()),
        sa.Column("decided_at", TS),
        sa.Column("created_at", TS, nullable=False),
        sa.CheckConstraint(
            "kind in ('impossible_activity', 'over_cap', 'no_live_claim', 'duplicate_device', 'pattern')",
            name="anomaly_kind",
        ),
        sa.CheckConstraint("status in ('open', 'dismissed', 'upheld')", name="anomaly_status"),
        schema=S,
    )
    op.create_index(
        "ix_anomaly_one_open",
        "anomaly_flag",
        ["worker_id", "kind"],
        unique=True,
        schema=S,
        postgresql_where=sa.text("status = 'open' and kind <> 'over_cap'"),
    )
    op.create_index(
        "ix_anomaly_one_cap_per_week",
        "anomaly_flag",
        ["worker_id", "week_start"],
        unique=True,
        schema=S,
        postgresql_where=sa.text("kind = 'over_cap'"),
    )
    op.create_index("ix_anomaly_status", "anomaly_flag", ["status", "created_at"], schema=S)
    md = sa.MetaData()
    outbox_table(md, S)
    consumed_table(md, S)
    dead_table(md, S)
    job_lease_table(md, S)
    md.create_all(op.get_bind())


def downgrade() -> None:
    for t in (
        "job_lease",
        "dead_event",
        "consumed_event",
        "outbox",
        "anomaly_flag",
        "live_claim",
        "hour_cap",
        "screenshot_ref",
        "activity_sample",
        "activity_session",
    ):
        op.drop_table(t, schema=S)
