"""Request and response bodies of the market API. Money is a Decimal string on the wire, never a float."""

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Any, Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator

from yantra_market.models import BatchMode, ProjectStatus, WorkerStatus
from yantra_market.rules import ImportReport

MAX_FEEDBACK_CHARS = 4000


class ProjectIn(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    payload_schema: dict[str, Any]
    answer_schema: dict[str, Any] | None = None
    rubric_version: str = Field(default="v1", max_length=40)
    margin_floor: Decimal | None = Field(default=None, ge=0, le=1, decimal_places=4)
    cert_gate: str | None = Field(default=None, max_length=80)
    retention_days: int = Field(default=180, ge=1, le=3650)


class ProjectOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    name: str
    currency: str
    status: str
    rubric_version: str
    margin_floor: Decimal | None
    cert_gate: str | None
    answer_schema: dict[str, Any] | None


class BatchIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    mode: BatchMode = "open"
    unit_pay: Decimal = Field(ge=0, decimal_places=6)
    unit_price: Decimal = Field(ge=0, decimal_places=6)
    review_pay: Decimal = Field(default=Decimal("0"), ge=0, decimal_places=6)
    claim_ttl_minutes: int = Field(default=240, ge=1, le=10080)
    due_at: AwareDatetime | None = None


class BatchPatch(BaseModel):
    """Only the fields sent change. `due_at` null clears the date."""

    model_config = ConfigDict(extra="forbid")
    title: str | None = Field(default=None, min_length=1, max_length=200)
    due_at: AwareDatetime | None = None


class BatchOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    project_id: uuid.UUID
    title: str
    mode: str
    unit_pay: Decimal
    unit_price: Decimal
    review_pay: Decimal
    currency: str
    status: str
    claim_ttl_minutes: int
    rubric_version: str
    floor_approved_by: str | None
    published_at: datetime | None
    due_at: datetime | None = None
    purged_at: datetime | None = None


class ImportIn(BaseModel):
    lines: list[dict[str, Any]] = Field(max_length=20000)


class ImportOut(ImportReport):
    dry_run: bool


class PublishIn(BaseModel):
    approved_by: str | None = Field(default=None, max_length=200)
    approval_note: str | None = Field(default=None, max_length=1000)


class ClaimOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    unit_id: uuid.UUID
    worker_id: uuid.UUID
    status: str
    expires_at: datetime


class SubmissionIn(BaseModel):
    answer: dict[str, Any]


class SubmissionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    claim_id: uuid.UUID
    unit_id: uuid.UUID
    rubric_version: str
    submitted_at: datetime


class UnitOut(BaseModel):
    """What a worker sees of a unit: the payload and the pay, never the client's price."""

    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    batch_id: uuid.UUID
    external_ref: str
    payload: dict[str, Any]
    unit_pay: Decimal | None
    rubric_version: str | None
    status: str
    current_claim_id: uuid.UUID | None


class WorkerIn(BaseModel):
    """Odoo's or an operator's push. `cert_gates`, when sent, replaces the gates set by hand before; the gates the
    events granted (a paper, an offer) always stay."""

    status: WorkerStatus
    cert_gates: list[str] | None = Field(default=None, max_length=50)
    partner_ref: int | None = None


class WorkerOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    status: WorkerStatus
    cert_gates: list[str]
    partner_ref: int | None
    updated_at: datetime


class AvailabilityIn(BaseModel):
    """The weekly check-in: hours offered this week and an optional pause (an aware timestamp)."""

    weekly_hours: int = Field(ge=0, le=80)
    paused_until: AwareDatetime | None = None


class AvailabilityOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    weekly_hours: int
    paused_until: datetime | None
    updated_at: datetime


class WorkerMeOut(BaseModel):
    """The caller's own view: `status` is `unknown` and `cert_gates` empty until Odoo has pushed a profile, so the
    app can say "not onboarded yet" instead of meeting a 404."""

    id: uuid.UUID
    status: str
    cert_gates: list[str]
    partner_ref: int | None
    updated_at: datetime | None
    availability: AvailabilityOut | None


class ReleasedOut(BaseModel):
    released: int
    more: bool


class BatchBriefOut(BaseModel):
    """What a worker needs to know about the batch they hold: the pay and the answer schema, never the price."""

    id: uuid.UUID
    project_id: uuid.UUID
    project_name: str
    title: str
    currency: str
    unit_pay: Decimal
    review_pay: Decimal
    claim_ttl_minutes: int
    rubric_version: str
    answer_schema: dict[str, Any] | None


class OpenBatchOut(BaseModel):
    """A published batch as the worker browses it: the pay, the count of units they may claim, never the price."""

    model_config = ConfigDict(extra="ignore")
    id: uuid.UUID
    project_id: uuid.UUID
    project_name: str
    title: str
    mode: str
    unit_pay: Decimal
    review_pay: Decimal
    currency: str
    claim_ttl_minutes: int
    rubric_version: str
    status: str
    available_units: int
    answer_schema: dict[str, Any] | None


class ActiveClaimOut(BaseModel):
    claim: ClaimOut | None
    unit: UnitOut | None
    batch: BatchBriefOut | None = None


class ManifestOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    batch_id: uuid.UUID
    project_id: uuid.UUID
    currency: str
    unit_price: Decimal
    accepted_units: int
    total_price: Decimal
    digest: str
    units: list[dict[str, Any]]
    created_at: datetime


# ---------- ops: projects, batches, workers ----------


class UnitCounts(BaseModel):
    """Units of a project or a batch by status. `total` counts every unit, drafts included."""

    total: int = 0
    available: int = 0
    claimed: int = 0
    submitted: int = 0
    in_review: int = 0
    accepted: int = 0
    rejected: int = 0
    needs_edits: int = 0


class ReasonRow(BaseModel):
    reason_code: str
    count: int
    billable: bool


class FeedbackOut(BaseModel):
    """One note of a project's thread. `author_kind` staff is Yantra's answer; `author_name` null when unknown."""

    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    author_id: uuid.UUID
    author_kind: Literal["client", "staff"] = "client"
    author_name: str | None = None
    body: str
    created_at: datetime


class RubricLogEntry(BaseModel):
    version: str
    note: str | None
    at: datetime


class ManifestBrief(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    digest: str
    accepted_units: int
    total_price: Decimal
    created_at: datetime


class ProjectSummary(BaseModel):
    id: uuid.UUID
    name: str
    currency: str
    status: str
    cert_gate: str | None
    rubric_version: str
    margin_floor: Decimal | None
    client_org_id: uuid.UUID | None
    batch_count: int
    units: UnitCounts
    created_at: datetime
    retention_days: int = 180
    closed_at: datetime | None = None


class BatchSummary(BaseModel):
    """The operator's view of a batch: pay and price side by side, the counts, the live claims, the manifest."""

    id: uuid.UUID
    project_id: uuid.UUID
    project_name: str
    title: str
    mode: str
    status: str
    unit_pay: Decimal
    unit_price: Decimal
    review_pay: Decimal
    currency: str
    claim_ttl_minutes: int
    rubric_version: str
    floor_approved_by: str | None
    published_at: datetime | None
    units: UnitCounts
    live_claims: int
    manifest: ManifestBrief | None
    due_at: datetime | None = None
    purged_at: datetime | None = None


class ProjectDetail(ProjectSummary):
    payload_schema: dict[str, Any]
    answer_schema: dict[str, Any] | None
    brief: str | None
    llm_policy: str | None
    sensitive: bool
    rubric_log: list[RubricLogEntry]
    batches: list[BatchSummary]
    reasons: list[ReasonRow]
    feedback: list[FeedbackOut]


class ProjectPatch(BaseModel):
    """Every field optional; only the ones sent change. A new `rubric_version` appends `{version, note, at}` to the
    project's rubric log, `rubric_note` being the why."""

    model_config = ConfigDict(extra="forbid")
    name: str | None = Field(default=None, min_length=1, max_length=200)
    status: ProjectStatus | None = None
    rubric_version: str | None = Field(default=None, min_length=1, max_length=40)
    rubric_note: str | None = Field(default=None, max_length=1000)
    margin_floor: Decimal | None = Field(default=None, ge=0, le=1, decimal_places=4)
    cert_gate: str | None = Field(default=None, max_length=80)
    brief: str | None = Field(default=None, max_length=20000)
    llm_policy: str | None = Field(default=None, max_length=4000)
    sensitive: bool | None = None
    client_org_id: uuid.UUID | None = None
    answer_schema: dict[str, Any] | None = None
    retention_days: int | None = Field(default=None, ge=1, le=3650)


class UnitRow(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    external_ref: str
    status: str
    assigned_worker_id: uuid.UUID | None
    current_claim_id: uuid.UUID | None
    created_at: datetime


class UnitPage(BaseModel):
    total: int
    items: list[UnitRow]


class WorkerRow(BaseModel):
    """`name` from talent's person events (null until seen); `onboarded` is true once the worker is past `unknown`;
    `held` and `hold_until` from payout's hold events."""

    id: uuid.UUID
    status: str
    cert_gates: list[str]
    partner_ref: int | None
    availability: AvailabilityOut | None
    updated_at: datetime
    name: str | None = None
    onboarded: bool = False
    held: bool = False
    hold_until: datetime | None = None


class WorkersSummaryOut(BaseModel):
    """The bench in numbers: profiles by status, paused (availability) and held (payout holds) right now."""

    total: int
    unknown: int
    eligible: int
    active: int
    suspended: int
    offboarded: int
    paused: int
    held: int


class WorkerPage(BaseModel):
    total: int
    items: list[WorkerRow]


# ---------- client orgs ----------


class ClientOrgIn(BaseModel):
    name: str = Field(min_length=1, max_length=200)


class ClientOrgOut(BaseModel):
    id: uuid.UUID
    name: str
    created_at: datetime
    members: list[uuid.UUID]


class MembershipOut(BaseModel):
    org_id: uuid.UUID
    user_id: uuid.UUID
    member: bool


# ---------- the client console: prices and invoice totals, never pay ----------


class OrgBrief(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    name: str


class NextDelivery(BaseModel):
    """The open batch due first across the client's projects."""

    batch_id: uuid.UUID
    title: str
    project_id: uuid.UUID
    project_name: str
    due_at: datetime
    accepted: int
    total: int


class ClientOverviewOut(BaseModel):
    orgs: list[OrgBrief]
    units: UnitCounts
    acceptance_rate: Decimal | None
    billable_rework: int
    deliveries: int
    invoice_total: dict[str, Decimal]
    next_delivery: NextDelivery | None = None


class ClientProjectOut(BaseModel):
    id: uuid.UUID
    name: str
    currency: str
    status: str
    rubric_version: str
    units: UnitCounts
    acceptance_rate: Decimal | None
    invoice_total: Decimal


class ClientBatchOut(BaseModel):
    id: uuid.UUID
    title: str
    status: str
    unit_price: Decimal
    units: UnitCounts
    manifest: ManifestBrief | None
    due_at: datetime | None = None


class ClientManifestOut(BaseModel):
    """A delivery as the client lists it: the totals and the digest, not the units (those are the manifest route)."""

    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    batch_id: uuid.UUID
    project_id: uuid.UUID
    currency: str
    unit_price: Decimal
    accepted_units: int
    total_price: Decimal
    digest: str
    created_at: datetime


class ClientProjectDetailOut(ClientProjectOut):
    rubric_log: list[RubricLogEntry]
    batches: list[ClientBatchOut]
    reasons: list[ReasonRow]
    deliveries: list[ClientManifestOut]
    feedback: list[FeedbackOut]


class FeedbackIn(BaseModel):
    body: str = Field(min_length=1, max_length=MAX_FEEDBACK_CHARS)


# ---------- stored media and deliverables ----------

MAX_UPLOAD_BYTES = 512 * 1024 * 1024
MEDIA_TYPES = r"^(audio|image|video)/[a-z0-9.+-]{1,60}$|^application/pdf$|^text/plain$"


class UploadFileIn(BaseModel):
    """`size_bytes` is exact: the presigned PUT is signed for it and the store refuses a body of any other size.
    SVG is refused: an image that can carry script has no place in a reviewer's browser."""

    name: str = Field(min_length=1, max_length=120)
    content_type: str = Field(pattern=MEDIA_TYPES)
    size_bytes: int = Field(ge=1, le=MAX_UPLOAD_BYTES)

    @field_validator("content_type")
    @classmethod
    def _no_svg(cls, value: str) -> str:
        if value.startswith("image/svg"):
            raise ValueError("image/svg+xml is not accepted")
        return value


class PayloadUploadsIn(BaseModel):
    files: list[UploadFileIn] = Field(min_length=1, max_length=500)


class UploadOut(BaseModel):
    """One presigned PUT: send `headers` with the body to `url` before `expires_at`, then put `ref` in the
    import line's payload."""

    name: str
    key: str
    ref: str
    url: str
    method: str
    headers: dict[str, str]
    expires_at: datetime
    max_bytes: int


class PayloadUploadsOut(BaseModel):
    uploads: list[UploadOut]


class UrlOut(BaseModel):
    url: str
    expires_at: datetime


class DeliverableFile(UrlOut):
    sha256: str
    bytes: int
    line_count: int


class DeliverableOut(BaseModel):
    """The batch's delivery as files: `units.jsonl` (one accepted unit per line) and `manifest.json`."""

    manifest_id: uuid.UUID
    batch_id: uuid.UUID
    digest: str
    jsonl: DeliverableFile
    manifest: UrlOut


# ---------- stuck work ----------


class ExpiredClaimRow(BaseModel):
    """A claim past its time that nobody has released yet (the expiry job releases it within a minute)."""

    claim_id: uuid.UUID
    unit_id: uuid.UUID
    external_ref: str
    batch_id: uuid.UUID
    batch_title: str
    project_id: uuid.UUID
    project_name: str
    worker_id: uuid.UUID
    worker_name: str | None
    expires_at: datetime
    minutes_overdue: int


class UnassignIn(BaseModel):
    """`assign_to` hands the unit to another worker; null returns it to the pool (an open batch only)."""

    assign_to: uuid.UUID | None = None


class UnassignedOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    batch_id: uuid.UUID
    status: str
    assigned_worker_id: uuid.UUID | None
    assigned_at: datetime | None
    unassigned_by: uuid.UUID | None
    unassigned_at: datetime | None


class StuckAssignedRow(BaseModel):
    """An available unit waiting for the one worker it is assigned to (a rework author who left, is held or paused)."""

    unit_id: uuid.UUID
    external_ref: str
    batch_id: uuid.UUID
    batch_title: str
    project_id: uuid.UUID
    project_name: str
    worker_id: uuid.UUID
    worker_name: str | None
    assigned_at: datetime
    days_waiting: int


class ReleasedClaimRow(BaseModel):
    """A claim that ended without a submission. `released_by` null is the expiry job; `status` released is the
    worker giving it back."""

    claim_id: uuid.UUID
    unit_id: uuid.UUID
    batch_id: uuid.UUID
    worker_id: uuid.UUID
    worker_name: str | None
    status: str
    expires_at: datetime
    released_at: datetime
    released_by: uuid.UUID | None
    released_by_name: str | None


class PersonOut(BaseModel):
    name: str | None
    kind: str
