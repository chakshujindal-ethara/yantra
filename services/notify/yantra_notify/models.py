"""Tables of the notify schema: a channel per worker (where to send), the inbox (what was said) and support
tickets (what a person asked ops for), and the `person` read model that names ticket authors. The inbox row is
written in the consumer's transaction; the email send happens after, from the row. notify consumes and never emits,
so it has no outbox."""

import uuid
from datetime import datetime
from typing import Any, Literal, get_args

from sqlalchemy import CheckConstraint, DateTime, Index, Integer, MetaData, String, Text, Uuid, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from yantra_common.consumer import consumed_table, dead_table
from yantra_common.people import person_table
from yantra_common.scheduler import job_lease_table
from yantra_notify import SCHEMA

TicketCategory = Literal["bug", "payment", "work", "account", "other"]
TicketStatus = Literal["open", "in_progress", "resolved"]
TICKET_CATEGORIES = get_args(TicketCategory)
TICKET_STATUSES = get_args(TicketStatus)


class Base(DeclarativeBase):
    metadata = MetaData(schema=SCHEMA)


class Channel(Base):
    """Where a worker wants to be reached. The address is the worker's own choice, set by them; `email` is the
    verified address (the only one mail goes to), `pending_email` the one waiting for its code. The code is never
    stored: it is a keyed digest of `verify_nonce` (`service.verification_code`), sent once by the email job, valid
    15 minutes and for five tries."""

    __tablename__ = "channel"

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    email: Mapped[str | None] = mapped_column(String(320))
    email_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    pending_email: Mapped[str | None] = mapped_column(String(320))
    verify_nonce: Mapped[str | None] = mapped_column(String(64))
    verify_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    verify_attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0, server_default="0")
    verify_sent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    verify_error: Mapped[str | None] = mapped_column(String(200))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now()
    )


class Notification(Base):
    __tablename__ = "notification"
    __table_args__ = (
        Index("ix_notification_inbox", "worker_id", "created_at"),
        Index("ix_notification_unread", "worker_id", postgresql_where="read_at IS NULL"),
        Index("ix_notification_unsent", "created_at", postgresql_where="emailed_at IS NULL AND email_error IS NULL"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    event_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False, unique=True)
    kind: Mapped[str] = mapped_column(String(40), nullable=False)
    subject: Mapped[str] = mapped_column(String(200), nullable=False)
    body: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    emailed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    email_attempts: Mapped[int] = mapped_column(Integer, nullable=False, default=0, server_default="0")
    next_attempt_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    email_error: Mapped[str | None] = mapped_column(String(200))


class Ticket(Base):
    """A support ticket: raised by anyone from the screen they were on, worked by ops on the board."""

    __tablename__ = "ticket"
    __table_args__ = (
        CheckConstraint(f"category in {TICKET_CATEGORIES}", name="ticket_category"),
        CheckConstraint(f"status in {TICKET_STATUSES}", name="ticket_status"),
        Index("ix_ticket_author", "author_id", "created_at"),
        Index("ix_ticket_board", "status", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    author_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    category: Mapped[str] = mapped_column(String(10), nullable=False)
    title: Mapped[str] = mapped_column(String(140), nullable=False)
    body: Mapped[str] = mapped_column(Text, nullable=False)
    screen: Mapped[str | None] = mapped_column(String(200))
    context: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False, default=dict, server_default="{}")
    status: Mapped[str] = mapped_column(String(12), nullable=False, default="open")
    note: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now()
    )


PERSON = person_table(Base.metadata, SCHEMA)
CONSUMED = consumed_table(Base.metadata, SCHEMA)
DEAD = dead_table(Base.metadata, SCHEMA)
JOB_LEASE = job_lease_table(Base.metadata, SCHEMA)
TABLES = [t.fullname for t in reversed(Base.metadata.sorted_tables)]
