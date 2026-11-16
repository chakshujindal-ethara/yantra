"""Transactional outbox. A state change and the event that describes it are written in the same transaction.
The relay (`yantra_common.relay`) publishes unpublished rows to NATS in `occurred_at` order and marks them;
consumers deduplicate on `id`."""

import uuid
from datetime import UTC, datetime

from pydantic import BaseModel
from sqlalchemy import DateTime, Index, String, Table, Uuid, insert, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Session
from sqlalchemy.sql.schema import Column, MetaData


def outbox_table(metadata: MetaData, schema: str) -> Table:
    """Every module owns an `outbox` table on its own schema with this exact shape."""
    return Table(
        "outbox",
        metadata,
        Column("id", Uuid, primary_key=True),
        Column("type", String(120), nullable=False),
        Column("subject", String(200), nullable=False),
        Column("payload", JSONB, nullable=False),
        Column("occurred_at", DateTime(timezone=True), nullable=False),
        Column("published_at", DateTime(timezone=True), nullable=True),
        Index("ix_outbox_unpublished", "occurred_at", postgresql_where=text("published_at is null")),
        schema=schema,
    )


def emit(session: Session, table: Table, subject: str, event: BaseModel) -> uuid.UUID:
    """Write one contract event (a pydantic model with a class-level TYPE) into the module's outbox inside the
    caller's transaction. Returns the event id."""
    event_type = getattr(type(event), "TYPE", None)
    if not isinstance(event_type, str) or not event_type:
        raise TypeError(f"{type(event).__name__} is not a contract event: it has no TYPE")
    event_id = uuid.uuid4()
    session.execute(
        insert(table).values(
            id=event_id,
            type=event_type,
            subject=subject,
            payload=event.model_dump(mode="json"),
            occurred_at=datetime.now(UTC),
            published_at=None,
        )
    )
    return event_id
