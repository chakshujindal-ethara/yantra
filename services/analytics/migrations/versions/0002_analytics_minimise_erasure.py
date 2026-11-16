"""analytics: minimise the payloads already stored (the allowlist of `yantra_analytics.minimise`), the erased-worker
pseudonyms, and an index on `event.time` for the retention prune.

Revision ID: 0002
Revises: 0001
"""

import sqlalchemy as sa
from alembic import op

from yantra_analytics.minimise import KEEP, PRESENCE

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

S = "analytics"
UUID = "^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$"


def upgrade() -> None:
    op.create_table(
        "erased_worker",
        sa.Column("id_hash", sa.String(64), primary_key=True),
        sa.Column("pseudonym", sa.Uuid(), nullable=False, unique=True),
        sa.Column("erased_at", sa.DateTime(timezone=True), nullable=False),
        schema=S,
    )
    op.create_index("ix_event_time", "event", ["time"], schema=S)
    bind = op.get_bind()
    for type_, keep in KEEP.items():
        presence = "".join(
            f" || jsonb_build_object('has_{f}', coalesce(payload->>'{f}', '') <> '')" for f in PRESENCE.get(type_, ())
        )
        bind.execute(
            sa.text(
                f"update {S}.event set payload = (select coalesce(jsonb_object_agg(k, v), '{{}}'::jsonb) "
                f"from jsonb_each(payload) as j(k, v) where k = any(:keep)){presence} where type = :type"
            ),
            {"keep": sorted(keep), "type": type_},
        )
    bind.execute(
        sa.text(
            f"update {S}.event set payload = (select coalesce(jsonb_object_agg(k, v), '{{}}'::jsonb) "
            "from jsonb_each(payload) as j(k, v) where (k = 'id' or k like '%\\_id') "
            "and jsonb_typeof(v) = 'string' and v #>> '{}' ~ :uuid) where type <> all(:types)"
        ),
        {"uuid": UUID, "types": sorted(KEEP)},
    )


def downgrade() -> None:
    """The dropped fields are gone for good; only the table and the index go back."""
    op.drop_index("ix_event_time", "event", schema=S)
    op.drop_table("erased_worker", schema=S)
