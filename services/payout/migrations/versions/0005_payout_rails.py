"""payout: lines on a rail (queued, processing, paid, failed, returned, released), windows that are paying,
rail webhooks seen once, reconciliation runs

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

S = "payout"
MONEY = sa.Numeric(18, 6)
NOW = sa.func.now()
LINE = "('payable', 'held', 'queued', 'processing', 'paid', 'failed', 'returned', 'released')"
WINDOW = "('closed', 'approved', 'paying', 'paid')"


def upgrade() -> None:
    op.drop_constraint("line_status", "window_line", schema=S, type_="check")
    op.create_check_constraint("line_status", "window_line", f"status in {LINE}", schema=S)
    for name, type_ in (
        ("attempts", sa.Integer()),
        ("idempotency_key", sa.Text()),
        ("rail", sa.String(20)),
        ("rail_reference", sa.Text()),
        ("rail_status", sa.String(20)),
        ("utr", sa.String(40)),
        ("rail_amount", MONEY),
        ("failure_reason", sa.Text()),
        ("submitted_at", sa.DateTime(timezone=True)),
        ("settled_at", sa.DateTime(timezone=True)),
    ):
        default = "0" if name == "attempts" else None
        op.add_column(
            "window_line",
            sa.Column(name, type_, nullable=default is None, server_default=default),
            schema=S,
        )
    op.create_index(
        "ix_line_in_flight",
        "window_line",
        ["status"],
        schema=S,
        postgresql_where=sa.text("status in ('queued', 'processing')"),
    )
    op.drop_constraint("window_status", "pay_window", schema=S, type_="check")
    op.create_check_constraint("window_status", "pay_window", f"status in {WINDOW}", schema=S)
    op.add_column("pay_window", sa.Column("rail", sa.String(20)), schema=S)
    op.add_column("pay_window", sa.Column("paid_total", MONEY, nullable=False, server_default="0"), schema=S)
    op.add_column("pay_window", sa.Column("reconciled_at", sa.DateTime(timezone=True)), schema=S)
    op.create_table(
        "webhook_event",
        sa.Column("id", sa.String(80), primary_key=True),
        sa.Column("rail", sa.String(20), nullable=False),
        sa.Column("event_type", sa.String(60), nullable=False),
        sa.Column("body_sha256", sa.String(64), nullable=False),
        sa.Column("line_id", sa.Uuid()),
        sa.Column("worker_id", sa.Uuid()),
        sa.Column("applied", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("note", sa.String(40)),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        schema=S,
    )
    op.create_table(
        "reconciliation_run",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("window_id", sa.Uuid(), sa.ForeignKey(f"{S}.pay_window.id"), nullable=False),
        sa.Column("ran_at", sa.DateTime(timezone=True), nullable=False, server_default=NOW),
        sa.Column("earnings_total", MONEY, nullable=False),
        sa.Column("lines_total", MONEY, nullable=False),
        sa.Column("paid_total", MONEY, nullable=False),
        sa.Column("rail_total", MONEY, nullable=False),
        sa.Column("delta_lines", MONEY, nullable=False),
        sa.Column("delta_rail", MONEY, nullable=False),
        sa.Column("failed_lines", sa.Integer(), nullable=False),
        sa.Column("processing_lines", sa.Integer(), nullable=False),
        sa.Column("balanced", sa.Boolean(), nullable=False),
        sa.Column("details", JSONB(), nullable=False, server_default="{}"),
        schema=S,
    )
    op.create_index("ix_reconciliation_window", "reconciliation_run", ["window_id", "ran_at"], schema=S)


def downgrade() -> None:
    op.drop_table("reconciliation_run", schema=S)
    op.drop_table("webhook_event", schema=S)
    for name in ("reconciled_at", "paid_total", "rail"):
        op.drop_column("pay_window", name, schema=S)
    op.drop_constraint("window_status", "pay_window", schema=S, type_="check")
    op.create_check_constraint("window_status", "pay_window", "status in ('closed', 'approved', 'paid')", schema=S)
    op.drop_index("ix_line_in_flight", table_name="window_line", schema=S)
    for name in (
        "settled_at",
        "submitted_at",
        "failure_reason",
        "rail_amount",
        "utr",
        "rail_status",
        "rail_reference",
        "rail",
        "idempotency_key",
        "attempts",
    ):
        op.drop_column("window_line", name, schema=S)
    op.drop_constraint("line_status", "window_line", schema=S, type_="check")
    op.create_check_constraint("line_status", "window_line", "status in ('payable', 'held', 'paid')", schema=S)
