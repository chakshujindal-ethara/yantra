"""HTTP surface of the notify module: a worker's inbox and the channel they choose, and support tickets
(anyone raises and reads their own; ops read the board and move tickets across it)."""

import uuid
from datetime import datetime
from typing import Any

from fastapi import APIRouter, status
from pydantic import BaseModel, ConfigDict, Field

from yantra_common.deps import DB, Ops, Worker, WorkerId
from yantra_common.people import name_of, names_of
from yantra_notify import service
from yantra_notify.models import PERSON, Channel, Notification, Ticket, TicketCategory, TicketStatus

router = APIRouter(prefix="/v1/notify", tags=["notify"])


class ChannelIn(BaseModel):
    email: str | None = Field(default=None, max_length=320, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class ChannelOut(BaseModel):
    """`email` is the verified address (the only one mail goes to); `pending_email` waits for its code
    (`verify_sent_at` once mailed, `verify_error` when the mail failed: ask again)."""

    model_config = ConfigDict(from_attributes=True)
    worker_id: uuid.UUID
    email: str | None
    email_verified_at: datetime | None = None
    pending_email: str | None = None
    verify_expires_at: datetime | None = None
    verify_sent_at: datetime | None = None
    verify_error: str | None = None
    updated_at: datetime


class VerifyIn(BaseModel):
    code: str = Field(min_length=6, max_length=6, pattern=r"^[0-9]{6}$")


class NotificationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    kind: str
    subject: str
    body: str
    created_at: datetime
    read_at: datetime | None
    emailed_at: datetime | None


class TicketIn(BaseModel):
    category: TicketCategory
    title: str = Field(min_length=1, max_length=140)
    body: str = Field(min_length=1, max_length=4000)
    screen: str | None = Field(default=None, max_length=200)
    context: dict[str, Any] = Field(default_factory=dict)


class TicketStatusIn(BaseModel):
    status: TicketStatus
    note: str | None = Field(default=None, max_length=2000)


class TicketOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    author_id: uuid.UUID
    category: str
    title: str
    body: str
    screen: str | None
    context: dict[str, Any]
    status: str
    note: str | None
    created_at: datetime
    updated_at: datetime
    author_name: str | None = None


class UnreadOut(BaseModel):
    unread: int


def with_names(session: DB, tickets: list[Ticket]) -> list[TicketOut]:
    """Tickets with their author's display name, one query for the page."""
    people = names_of(session, PERSON, [t.author_id for t in tickets])
    return [
        TicketOut.model_validate(t).model_copy(update={"author_name": name_of(people, t.author_id)}) for t in tickets
    ]


@router.put("/channel", response_model=ChannelOut, dependencies=[Worker])
def set_channel(body: ChannelIn, worker_id: WorkerId, session: DB) -> Channel:
    return service.set_channel(session, worker_id, body.email)


@router.post("/channel/verify", response_model=ChannelOut, dependencies=[Worker])
def verify_channel(body: VerifyIn, worker_id: WorkerId, session: DB) -> Channel:
    """The code mailed to the pending address: 422 `wrong_code` (with `attempts_left`), 409 `nothing_to_verify`,
    `code_expired` (15 minutes) or `too_many_attempts` (five); ask for a new code with `PUT /channel`."""
    return service.verify_channel(session, worker_id, body.code)


@router.get("/channel", response_model=ChannelOut, dependencies=[Worker])
def get_channel(worker_id: WorkerId, session: DB) -> Channel:
    return service.get_channel(session, worker_id)


@router.get("/inbox", response_model=list[NotificationOut], dependencies=[Worker])
def inbox(worker_id: WorkerId, session: DB) -> list[Notification]:
    return service.inbox(session, worker_id)


@router.get("/inbox/unread-count", response_model=UnreadOut, dependencies=[Worker])
def unread_count(worker_id: WorkerId, session: DB) -> UnreadOut:
    """The badge's poll: cheap, one count."""
    return UnreadOut(unread=service.unread_count(session, worker_id))


@router.post("/inbox/{notification_id}/read", response_model=NotificationOut, dependencies=[Worker])
def mark_read(notification_id: uuid.UUID, worker_id: WorkerId, session: DB) -> Notification:
    return service.mark_read(session, worker_id, notification_id)


@router.post("/tickets", response_model=TicketOut, status_code=status.HTTP_201_CREATED)
def create_ticket(body: TicketIn, worker_id: WorkerId, session: DB) -> TicketOut:
    """Any signed-in person; the author is the caller the gateway identified."""
    return with_names(session, [service.create_ticket(session, worker_id, **body.model_dump())])[0]


@router.get("/tickets/me", response_model=list[TicketOut])
def my_tickets(worker_id: WorkerId, session: DB) -> list[TicketOut]:
    return with_names(session, service.my_tickets(session, worker_id))


@router.get("/tickets", response_model=list[TicketOut], dependencies=[Ops])
def list_tickets(session: DB, status: TicketStatus | None = None) -> list[TicketOut]:
    """The board, each ticket with its author's display name."""
    return with_names(session, service.list_tickets(session, status))


@router.post("/tickets/{ticket_id}/status", response_model=TicketOut, dependencies=[Ops])
def set_ticket_status(ticket_id: uuid.UUID, body: TicketStatusIn, worker_id: WorkerId, session: DB) -> TicketOut:
    ticket = service.set_ticket_status(session, ticket_id, body.status, body.note, moved_by=worker_id)
    return with_names(session, [ticket])[0]


@router.get("/attention", response_model=dict[str, int], dependencies=[Ops])
def attention(session: DB) -> dict[str, int]:
    return service.attention(session)
