"""Request and response bodies of the talent API. Pay is a Decimal string on the wire. The identity body carries the
PAN in; nothing ever carries it out. The bank account is payout's (`PUT /v1/payout/accounts/me`)."""

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Any, Literal, Self

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, model_validator

from yantra_talent.models import (
    ApplicationStatus,
    Commitment,
    DocumentKind,
    ErasureStatus,
    ListingStatus,
    OnboardingStep,
    StepKind,
    StepStatus,
)

QUESTION_KEY = r"^[a-z][a-z0-9_]{0,39}$"
PHONE = r"^[6-9][0-9]{9}$"
DIGITS4 = r"^[0-9]{4}$"
STEP_ORDER: tuple[StepKind, ...] = ("form", "paper", "availability")


def listing_steps(chosen: list[StepKind] | None, has_paper: bool) -> list[StepKind]:
    """The application steps of a listing, in their fixed order: the form always, the paper exactly when the listing
    has one, availability when ops ask for it (by default with a paper, as before steps were configurable)."""
    wanted = set(chosen) if chosen is not None else ({"availability"} if has_paper else set())
    return [
        k for k in STEP_ORDER if k == "form" or (k == "paper" and has_paper) or (k == "availability" and k in wanted)
    ]


# ---------- listings ----------


class QuestionIn(BaseModel):
    key: str = Field(pattern=QUESTION_KEY)
    prompt: str = Field(min_length=1, max_length=500)
    kind: Literal["text", "choice"] = "text"
    options: list[str] | None = Field(default=None, max_length=20)
    required: bool = True

    @model_validator(mode="after")
    def options_match_kind(self) -> Self:
        if self.kind == "choice" and len(self.options or []) < 2:
            raise ValueError("a choice question needs at least two options")
        if self.kind == "text" and self.options:
            raise ValueError("a text question has no options")
        return self


class ListingIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    domain: str = Field(min_length=1, max_length=80)
    summary: str = Field(min_length=1, max_length=500)
    description: str = Field(default="", max_length=20000)
    pay_min: Decimal = Field(ge=0, decimal_places=6)
    pay_max: Decimal = Field(ge=0, decimal_places=6)
    pay_unit: Literal["per_unit"] = "per_unit"
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    commitment: Commitment
    hours_per_week: int | None = Field(default=None, ge=1, le=80)
    slots_total: int = Field(ge=1, le=100000)
    cert_gate: str | None = Field(default=None, min_length=1, max_length=80)
    paper_id: uuid.UUID | None = None
    requirements: list[str] = Field(default_factory=list, max_length=50)
    questions: list[QuestionIn] = Field(default_factory=list, max_length=30)
    llm_policy: str | None = Field(default=None, max_length=5000)
    sensitive: bool = False
    steps: list[StepKind] | None = Field(default=None, max_length=3)
    status: ListingStatus = "draft"
    closes_at: AwareDatetime | None = None

    @model_validator(mode="after")
    def consistent(self) -> Self:
        if self.pay_min > self.pay_max:
            raise ValueError("pay_min must not exceed pay_max")
        keys = [q.key for q in self.questions]
        if len(set(keys)) != len(keys):
            raise ValueError("question keys must be unique")
        if self.paper_id is not None and self.cert_gate is None:
            raise ValueError("a paper needs a cert_gate to certify")
        self.steps = listing_steps(self.steps, self.paper_id is not None)
        return self


class ListingPatch(BaseModel):
    """Every field optional; the merged result is validated as a whole ListingIn."""

    model_config = ConfigDict(extra="forbid")
    title: str | None = None
    domain: str | None = None
    summary: str | None = None
    description: str | None = None
    pay_min: Decimal | None = None
    pay_max: Decimal | None = None
    currency: str | None = None
    commitment: Commitment | None = None
    hours_per_week: int | None = None
    slots_total: int | None = None
    cert_gate: str | None = None
    paper_id: uuid.UUID | None = None
    requirements: list[str] | None = None
    questions: list[QuestionIn] | None = None
    llm_policy: str | None = None
    sensitive: bool | None = None
    steps: list[StepKind] | None = None
    status: ListingStatus | None = None
    closes_at: AwareDatetime | None = None


class ListingOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    title: str
    domain: str
    summary: str
    description: str
    pay_min: Decimal
    pay_max: Decimal
    pay_unit: str
    currency: str
    commitment: str
    hours_per_week: int | None
    slots_total: int
    slots_filled: int
    cert_gate: str | None
    paper_id: uuid.UUID | None
    requirements: list[str]
    questions: list[dict[str, Any]]
    llm_policy: str | None
    sensitive: bool
    steps: list[StepKind]
    status: str
    posted_at: datetime | None
    closes_at: datetime | None
    created_at: datetime
    hired_this_week: int = 0  # accepted offers in the last seven days


class RedirectOut(BaseModel):
    """Where a closed listing points: an open pool of the same domain (Mercor's evergreen redirect)."""

    listing_id: uuid.UUID
    title: str


class ViewerOut(BaseModel):
    prequalified: bool
    application_id: uuid.UUID | None
    application_status: str | None
    redirect: RedirectOut | None = None


class WorkerListingOut(ListingOut):
    viewer: ViewerOut


class OpsListingOut(ListingOut):
    applications: dict[str, int]


# ---------- applications ----------


class ApplyIn(BaseModel):
    answers: dict[str, Any] = Field(default_factory=dict, max_length=30)


class StepOut(BaseModel):
    kind: StepKind
    status: StepStatus


class PaperOut(BaseModel):
    """The latest paper outcome behind an application: passed, or failed with the attempts left."""

    status: Literal["passed", "failed"]
    score: Decimal
    at: datetime
    attempts_left: int | None = None


class ApplicationOut(BaseModel):
    id: uuid.UUID
    listing_id: uuid.UUID
    listing_title: str
    worker_id: uuid.UUID
    status: ApplicationStatus
    steps: list[StepOut]
    answers: dict[str, Any]
    note: str | None
    offer_expires_at: datetime | None
    decided_by: uuid.UUID | None
    created_at: datetime
    updated_at: datetime
    worker_name: str | None = None
    paper: PaperOut | None = None


class DecideIn(BaseModel):
    decision: Literal["offer", "reject"]
    note: str | None = Field(default=None, max_length=2000)
    offer_days: int = Field(default=7, ge=1, le=30)


class OfferAnswerIn(BaseModel):
    accept: bool


# ---------- onboarding ----------


class ProfileIn(BaseModel):
    legal_name: str = Field(min_length=1, max_length=200)
    phone: str = Field(pattern=PHONE)
    city: str = Field(min_length=1, max_length=100)


class AgreementIn(BaseModel):
    accepted: Literal[True]
    version: str = Field(min_length=1, max_length=40)


class ConsentIn(BaseModel):
    """`accepted: false` withdraws the consent. `version` is the consent text the worker read; when given it must be
    the current one."""

    accepted: bool
    version: str | None = Field(default=None, min_length=1, max_length=40)


class IdentityIn(BaseModel):
    pan: str = Field(min_length=10, max_length=12)
    aadhaar_last4: str = Field(pattern=DIGITS4)


class PayoutAckIn(BaseModel):
    accepted: Literal[True]


class OnboardingStepOut(BaseModel):
    key: OnboardingStep
    status: Literal["pending", "done"]
    done_at: datetime | None
    group: str


class DocumentBriefOut(BaseModel):
    kind: DocumentKind
    uploaded_at: datetime


class ErasureOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    worker_id: uuid.UUID
    status: ErasureStatus
    requested_at: datetime
    due_at: datetime
    approved_at: datetime | None
    approved_by: uuid.UUID | None
    done_at: datetime | None


class OnboardingOut(BaseModel):
    complete: bool
    eligible_sent_at: datetime | None
    steps: list[OnboardingStepOut]
    agreement_version: str | None = None
    consent_version: str | None = None
    documents: list[DocumentBriefOut] = []
    erasure: ErasureOut | None = None


class OnboardingRowOut(BaseModel):
    worker_id: uuid.UUID
    complete: bool
    steps_done: int
    updated_at: datetime


# ---------- people ----------


class PersonOut(BaseModel):
    id: uuid.UUID
    name: str | None
    kind: Literal["worker", "staff", "client"]


# ---------- policies ----------


class PolicySection(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    paragraphs: list[str] = Field(default_factory=list, max_length=50)
    bullets: list[str] = Field(default_factory=list, max_length=100)


class PolicyIn(BaseModel):
    """A new version of a policy. `label` is what the worker sees and accepts; the revision number when absent."""

    title: str = Field(min_length=1, max_length=200)
    summary: str = Field(min_length=1, max_length=500)
    sections: list[PolicySection] = Field(min_length=1, max_length=40)
    label: str | None = Field(default=None, min_length=1, max_length=40)


class PolicyOut(BaseModel):
    slug: str
    version: str  # the label
    revision: int
    title: str
    summary: str
    sections: list[PolicySection]
    updated_at: datetime


# ---------- documents ----------

DOCUMENT_TYPES = ("image/jpeg", "image/png", "application/pdf")
MAX_DOCUMENT_BYTES = 10 * 1024 * 1024


class DocumentPresignIn(BaseModel):
    kind: DocumentKind
    content_type: Literal["image/jpeg", "image/png", "application/pdf"]
    size_bytes: int = Field(ge=1, le=MAX_DOCUMENT_BYTES)


class PresignedOut(BaseModel):
    key: str
    url: str
    method: str
    headers: dict[str, str]
    expires_at: datetime
    max_bytes: int


class DocumentIn(BaseModel):
    key: str = Field(min_length=1, max_length=300)
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    size_bytes: int = Field(ge=1, le=MAX_DOCUMENT_BYTES)


class DocumentOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    kind: DocumentKind
    sha256: str
    size_bytes: int
    content_type: str
    uploaded_at: datetime


class UrlOut(BaseModel):
    url: str
    expires_at: datetime
