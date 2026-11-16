"""analytics: the event warehouse, dimensions, marts, baselines, control, consumed and dead events, job leases

Revision ID: 0001
Revises:
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

from yantra_common.consumer import consumed_table, dead_table
from yantra_common.scheduler import job_lease_table

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

S = "analytics"
MONEY = sa.Numeric(18, 6)
TS = sa.DateTime(timezone=True)
JSON = postgresql.JSONB()


def _ints(*names: str) -> list[sa.Column]:  # type: ignore[type-arg]
    return [sa.Column(n, sa.Integer(), nullable=False) for n in names]


def upgrade() -> None:
    op.create_table(
        "event",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("type", sa.String(120), nullable=False),
        sa.Column("subject", sa.String(200), nullable=False),
        sa.Column("time", TS, nullable=False),
        sa.Column("worker_id", sa.Uuid()),
        sa.Column("project_id", sa.Uuid()),
        sa.Column("batch_id", sa.Uuid()),
        sa.Column("unit_id", sa.Uuid()),
        sa.Column("listing_id", sa.Uuid()),
        sa.Column("window_id", sa.Uuid()),
        sa.Column("payload", JSON, nullable=False),
        sa.Column("ingested_at", TS, nullable=False),
        schema=S,
    )
    op.create_index("ix_event_type_time", "event", ["type", "time"], schema=S)
    op.create_index(
        "ix_event_project",
        "event",
        ["project_id", "time"],
        schema=S,
        postgresql_where=sa.text("project_id is not null"),
    )
    op.create_index(
        "ix_event_worker", "event", ["worker_id", "time"], schema=S, postgresql_where=sa.text("worker_id is not null")
    )
    op.create_index("ix_event_unit", "event", ["unit_id"], schema=S, postgresql_where=sa.text("unit_id is not null"))
    op.create_index("ix_event_ingested", "event", ["ingested_at"], schema=S)
    op.create_table(
        "dim_batch",
        sa.Column("batch_id", sa.Uuid(), primary_key=True),
        sa.Column("project_id", sa.Uuid()),
        sa.Column("currency", sa.String(3)),
        sa.Column("unit_pay", MONEY),
        sa.Column("unit_price", MONEY),
        sa.Column("review_pay", MONEY),
        sa.Column("unit_count", sa.Integer()),
        sa.Column("mode", sa.String(20)),
        sa.Column("published_at", TS),
        schema=S,
    )
    op.create_index("ix_dim_batch_project", "dim_batch", ["project_id"], schema=S)
    op.create_table(
        "dim_unit",
        sa.Column("unit_id", sa.Uuid(), primary_key=True),
        sa.Column("batch_id", sa.Uuid(), nullable=False),
        schema=S,
    )
    op.create_table(
        "mart_project_day",
        sa.Column("project_id", sa.Uuid(), primary_key=True),
        sa.Column("day", sa.Date(), primary_key=True),
        sa.Column("currency", sa.String(3), primary_key=True),
        *_ints(
            "units_published",
            "units_claimed",
            "units_submitted",
            "units_accepted",
            "units_rejected",
            "first_pass_num",
            "first_pass_den",
        ),
        sa.Column("pay", MONEY, nullable=False),
        sa.Column("price", MONEY, nullable=False),
        sa.Column("review_cost", MONEY, nullable=False),
        sa.Column("audit_cost", MONEY, nullable=False),
        sa.Column("margin", MONEY, nullable=False),
        sa.Column("refreshed_at", TS, nullable=False),
        schema=S,
    )
    op.create_table(
        "mart_funnel_day",
        sa.Column("listing_id", sa.Uuid(), primary_key=True),
        sa.Column("day", sa.Date(), primary_key=True),
        *_ints(
            "applied", "assessment", "screening", "offered", "accepted", "rejected", "declined", "withdrawn", "expired"
        ),
        sa.Column("refreshed_at", TS, nullable=False),
        schema=S,
    )
    op.create_table(
        "mart_worker_week",
        sa.Column("worker_id", sa.Uuid(), primary_key=True),
        sa.Column("week_start", sa.Date(), primary_key=True),
        *_ints("active_seconds", "units_accepted", "units_judged"),
        sa.Column("earnings", JSON, nullable=False),
        sa.Column("refreshed_at", TS, nullable=False),
        schema=S,
    )
    op.create_table(
        "mart_quality_day",
        sa.Column("project_id", sa.Uuid(), primary_key=True),
        sa.Column("day", sa.Date(), primary_key=True),
        *_ints("accepted", "rejected", "needs_edits"),
        sa.Column("reasons", JSON, nullable=False),
        *_ints("billable", "audited"),
        sa.Column("refreshed_at", TS, nullable=False),
        schema=S,
    )
    op.create_table(
        "mart_payout_window",
        sa.Column("window_id", sa.Uuid(), primary_key=True),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("starts_at", TS, nullable=False),
        sa.Column("ends_at", TS, nullable=False),
        sa.Column("closed_at", TS, nullable=False),
        sa.Column("line_count", sa.Integer(), nullable=False),
        sa.Column("gross_total", MONEY, nullable=False),
        sa.Column("held_total", MONEY, nullable=False),
        sa.Column("paid_total", MONEY, nullable=False),
        sa.Column("workers_paid", sa.Integer(), nullable=False),
        sa.Column("paid_at", TS),
        sa.Column("on_time", sa.Boolean()),
        sa.Column("refreshed_at", TS, nullable=False),
        schema=S,
    )
    op.create_table(
        "baseline",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("days_to_staff", sa.Numeric(8, 2)),
        sa.Column("idle_cost_weekly", MONEY),
        sa.Column("first_pass_acceptance", sa.Numeric(5, 4)),
        sa.Column("cost_per_accepted_unit", MONEY),
        sa.Column("idle_hourly_cost", MONEY, nullable=False),
        sa.Column("idle_hours_per_week", sa.Integer(), nullable=False),
        sa.Column("staffing_workers", sa.Integer(), nullable=False),
        sa.Column("rail_fee_per_payout", MONEY, nullable=False),
        sa.Column("levy_rate", sa.Numeric(6, 4), nullable=False),
        sa.Column("payout_sla_days", sa.Integer(), nullable=False),
        sa.Column("note", sa.Text()),
        sa.Column("set_by", sa.Uuid(), nullable=False),
        sa.Column("set_at", TS, nullable=False),
        schema=S,
    )
    op.create_index("ix_baseline_set_at", "baseline", ["set_at"], schema=S)
    op.create_table(
        "control",
        sa.Column("key", sa.String(40), primary_key=True),
        sa.Column("value", JSON, nullable=False),
        sa.Column("updated_at", TS, nullable=False),
        schema=S,
    )
    md = sa.MetaData()
    consumed_table(md, S)
    dead_table(md, S)
    job_lease_table(md, S)
    md.create_all(op.get_bind())


def downgrade() -> None:
    for t in (
        "job_lease",
        "dead_event",
        "consumed_event",
        "control",
        "baseline",
        "mart_payout_window",
        "mart_quality_day",
        "mart_worker_week",
        "mart_funnel_day",
        "mart_project_day",
        "dim_unit",
        "dim_batch",
        "event",
    ):
        op.drop_table(t, schema=S)
