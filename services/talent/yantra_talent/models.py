"""Tables of the talent schema: listings (the pools a worker applies to), applications with their step checklist,
the onboarding row (the PAN as a keyed hash + last four; the bank account lives in payout), the `worker_gate` read
model fed by `assess.certified.v1` and accepted offers, people (display names), versioned policies, erasure requests,
worker documents (object keys, never the bytes), and the outbox/consumed/dead tables every module keeps."""

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Any, Literal, get_args

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    MetaData,
    Numeric,
    String,
    Text,
    Uuid,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from yantra_common.consumer import consumed_table, dead_table
from yantra_common.outbox import outbox_table
from yantra_common.people import person_table
from yantra_common.scheduler import job_lease_table
from yantra_talent import SCHEMA

MONEY = Numeric(18, 6)
ListingStatus = Literal["draft", "open", "closed"]
Commitment = Literal["task_based", "part_time"]
ApplicationStatus = Literal[
    "applied", "assessment", "screening", "offered", "accepted", "declined", "rejected", "withdrawn", "expired"
]
StepKind = Literal["form", "paper", "availability"]
StepStatus = Literal["pending", "done", "failed"]
OnboardingStep = Literal["profile", "agreement", "consent", "identity", "bank", "payout_ack"]
GateSource = Literal["assess", "offer"]
DocumentKind = Literal["identity_front", "identity_back", "address_proof", "signed_agreement"]
ErasureStatus = Literal["requested", "approved", "done"]
LISTING_STATUSES = get_args(ListingStatus)
COMMITMENTS = get_args(Commitment)
APPLICATION_STATUSES = get_args(ApplicationStatus)
ONBOARDING_STEPS = get_args(OnboardingStep)
GATE_SOURCES = get_args(GateSource)
DOCUMENT_KINDS = get_args(DocumentKind)
ERASURE_STATUSES = get_args(ErasureStatus)
# an application in one of these states is over: the worker may apply to the listing again
ENDED_STATUSES = ("declined", "rejected", "withdrawn", "expired")
LIVE_STATUSES = tuple(s for s in APPLICATION_STATUSES if s not in ENDED_STATUSES)


class Base(DeclarativeBase):
    metadata = MetaData(schema=SCHEMA)


class Listing(Base):
    """A pool a worker can apply to. `slots_filled` counts accepted offers and is moved only under the row lock."""

    __tablename__ = "listing"
    __table_args__ = (
        CheckConstraint(f"status in {LISTING_STATUSES}", name="listing_status"),
        CheckConstraint(f"commitment in {COMMITMENTS}", name="listing_commitment"),
        CheckConstraint("pay_min >= 0 and pay_min <= pay_max", name="listing_pay_range"),
        CheckConstraint("slots_total >= 1 and slots_filled between 0 and slots_total", name="listing_slots"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    title: Mapped[str] = mapped_column(Text, nullable=False)
    domain: Mapped[str] = mapped_column(String(80), nullable=False)
    summary: Mapped[str] = mapped_column(Text, nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False, default="")
    pay_min: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    pay_max: Mapped[Decimal] = mapped_column(MONEY, nullable=False)
    pay_unit: Mapped[str] = mapped_column(String(20), nullable=False, default="per_unit")
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    commitment: Mapped[str] = mapped_column(String(20), nullable=False)
    hours_per_week: Mapped[int | None] = mapped_column(Integer)
    slots_total: Mapped[int] = mapped_column(Integer, nullable=False)
    slots_filled: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    cert_gate: Mapped[str | None] = mapped_column(String(80))
    paper_id: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    requirements: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=list)
    questions: Mapped[list[dict[str, Any]]] = mapped_column(JSONB, nullable=False, default=list)
    llm_policy: Mapped[str | None] = mapped_column(Text)
    sensitive: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    steps: Mapped[list[str]] = mapped_column(JSONB, nullable=False, default=lambda: ["form"])
    status: Mapped[str] = mapped_column(String(10), nullable=False, default="draft")
    posted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    closes_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


class Application(Base):
    """One live application per worker and listing (the partial unique index); an ended one may be followed by
    another. `steps` is the checklist the app shows: `[{kind, status}]`."""

    __tablename__ = "application"
    __table_args__ = (
        CheckConstraint(f"status in {APPLICATION_STATUSES}", name="application_status"),
        Index(
            "ix_application_one_live",
            "listing_id",
            "worker_id",
            unique=True,
            postgresql_where=f"status in {LIVE_STATUSES}",
        ),
        Index("ix_application_worker", "worker_id"),
        Index("ix_application_hired", "listing_id", "updated_at", postgresql_where="status = 'accepted'"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    listing_id: Mapped[uuid.UUID] = mapped_column(ForeignKey(f"{SCHEMA}.listing.id"), nullable=False)
    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False)
    steps: Mapped[list[dict[str, Any]]] = mapped_column(JSONB, nullable=False, default=list)
    answers: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False, default=dict)
    note: Mapped[str | None] = mapped_column(Text)
    offer_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    decided_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    # the latest paper outcome for this listing's gate: {status: passed|failed, score, at, attempts_left?}
    paper_result: Mapped[dict[str, Any] | None] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now()
    )


class Onboarding(Base):
    """The worker's checklist. `steps` maps a step key to the time it was done. The PAN is kept as an HMAC-SHA256
    of the normalised value under `YANTRA_PII_KEY` plus the last four digits: enough to detect reuse, never enough to
    reconstruct it. The bank account lives in payout; talent keeps the keyed digest of the verified account name
    (what the legal name is compared with) and when payout verified it."""

    __tablename__ = "onboarding"

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    steps: Mapped[dict[str, Any]] = mapped_column(JSONB, nullable=False, default=dict)
    legal_name: Mapped[str | None] = mapped_column(Text)
    phone: Mapped[str | None] = mapped_column(String(10))
    city: Mapped[str | None] = mapped_column(Text)
    agreement_version: Mapped[str | None] = mapped_column(String(40))
    consent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    consent_version: Mapped[str | None] = mapped_column(String(40))
    pan_hash: Mapped[str | None] = mapped_column(String(64), unique=True)
    pan_last4: Mapped[str | None] = mapped_column(String(4))
    aadhaar_last4: Mapped[str | None] = mapped_column(String(4))
    account_name_hash: Mapped[str | None] = mapped_column(String(64))
    account_verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    payout_ack_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    eligible_sent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now(), onupdate=func.now()
    )


class WorkerGate(Base):
    """Read model: the gates a worker holds, from `assess.certified.v1` or an accepted offer on a paperless listing.
    What "prequalified" and the initial application status read."""

    __tablename__ = "worker_gate"
    __table_args__ = (CheckConstraint(f"source in {GATE_SOURCES}", name="worker_gate_source"),)

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    gate: Mapped[str] = mapped_column(String(80), primary_key=True)
    source: Mapped[str] = mapped_column(String(10), nullable=False)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class Policy(Base):
    """One version of a policy text. A new text is a new revision; a row is never edited. `label` is the version the
    worker sees and accepts (the contractor agreement's `2026-11`)."""

    __tablename__ = "policy"

    slug: Mapped[str] = mapped_column(String(40), primary_key=True)
    revision: Mapped[int] = mapped_column(Integer, primary_key=True)
    label: Mapped[str] = mapped_column(String(40), nullable=False)
    title: Mapped[str] = mapped_column(Text, nullable=False)
    summary: Mapped[str] = mapped_column(Text, nullable=False)
    sections: Mapped[list[dict[str, Any]]] = mapped_column(JSONB, nullable=False)
    effective_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    created_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)


class Erasure(Base):
    """A worker's request to erase their personal data: due 30 days after the request, or at once when ops
    approve it; the hourly job does the erasing."""

    __tablename__ = "erasure"
    __table_args__ = (
        CheckConstraint(f"status in {ERASURE_STATUSES}", name="erasure_status"),
        Index("ix_erasure_due", "due_at", postgresql_where="status <> 'done'"),
    )

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    status: Mapped[str] = mapped_column(String(10), nullable=False)
    requested_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())
    due_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    approved_by: Mapped[uuid.UUID | None] = mapped_column(Uuid)
    done_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class WorkerDocument(Base):
    """One uploaded document per kind: the object key in storage, its digest and size. The bytes never touch a
    database or a service: the browser puts them straight into storage with a presigned URL."""

    __tablename__ = "worker_document"
    __table_args__ = (CheckConstraint(f"kind in {DOCUMENT_KINDS}", name="worker_document_kind"),)

    worker_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    kind: Mapped[str] = mapped_column(String(20), primary_key=True)
    key: Mapped[str] = mapped_column(Text, nullable=False)
    sha256: Mapped[str] = mapped_column(String(64), nullable=False)
    size_bytes: Mapped[int] = mapped_column(Integer, nullable=False)
    content_type: Mapped[str] = mapped_column(String(100), nullable=False)
    uploaded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, server_default=func.now())


PERSON = person_table(Base.metadata, SCHEMA)
OUTBOX = outbox_table(Base.metadata, SCHEMA)
CONSUMED = consumed_table(Base.metadata, SCHEMA)
DEAD = dead_table(Base.metadata, SCHEMA)
JOB_LEASE = job_lease_table(Base.metadata, SCHEMA)
# every table of the schema, children first, for TRUNCATE in tests; `policy` is reference data the migration seeds,
# so tests keep it (and delete only the versions they add: `testing.reset_policies`)
TABLES = [t.fullname for t in reversed(Base.metadata.sorted_tables) if t.name != "policy"]
