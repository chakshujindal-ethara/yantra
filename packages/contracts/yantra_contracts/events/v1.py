"""Version 1 of the events. The CloudEvents `type` is the class's TYPE; the payload is the model.
Rule: fields are added, never removed or renamed, within v1."""

import uuid
from decimal import Decimal
from typing import Any, ClassVar, Literal

from pydantic import BaseModel, ConfigDict


class Event(BaseModel):
    model_config = ConfigDict(frozen=True)
    TYPE: ClassVar[str]


# ---------- work (market) ----------


class WorkUnitPublished(Event):
    TYPE = "work.unit.published.v1"
    batch_id: uuid.UUID
    unit_count: int
    unit_pay: Decimal
    unit_price: Decimal
    review_pay: Decimal
    currency: str
    mode: str
    project_id: uuid.UUID | None = None  # added: lets read models attribute a batch to its project


class WorkUnitClaimed(Event):
    TYPE = "work.unit.claimed.v1"
    unit_id: uuid.UUID
    claim_id: uuid.UUID
    worker_id: uuid.UUID
    expires_at: str
    batch_id: uuid.UUID | None = None  # added: the claim's batch and project, for tracker caps and analytics
    project_id: uuid.UUID | None = None


class WorkClaimExpired(Event):
    TYPE = "work.claim.expired.v1"
    unit_id: uuid.UUID
    claim_id: uuid.UUID
    worker_id: uuid.UUID


class WorkUnitSubmitted(Event):
    """Carries the unit's payload and the answer, so a reviewer reads them from quality's own copy."""

    TYPE = "work.unit.submitted.v1"
    unit_id: uuid.UUID
    batch_id: uuid.UUID
    claim_id: uuid.UUID
    submission_id: uuid.UUID
    worker_id: uuid.UUID
    rubric_version: str
    payload: dict[str, Any] | None = None  # added in Stage 1; older events have none
    answer: dict[str, Any] | None = None
    # added: who may review it. Older events carry none and their tasks stay open to every reviewer.
    project_id: uuid.UUID | None = None
    cert_gate: str | None = None
    sensitive: bool = False


class WorkClaimReleased(Event):
    """The worker gave a live claim back before its time ran out; the unit is available again."""

    TYPE = "work.claim.released.v1"
    unit_id: uuid.UUID
    claim_id: uuid.UUID
    worker_id: uuid.UUID


class WorkBatchPurged(Event):
    """The batch's retention ran out: unit payloads, answers and stored media are gone; counts and digests stay.
    Quality drops its own copies on this event."""

    TYPE = "work.batch.purged.v1"
    batch_id: uuid.UUID
    project_id: uuid.UUID
    unit_count: int


class WorkerGatesSet(Event):
    """An operator (or Odoo) set a worker's certification gates by hand (`PUT /v1/workers/{id}`). `gates` is the
    full hand-set list: quality replaces its ops-sourced copy with it and keeps the gates papers and offers granted."""

    TYPE = "worker.gates.set.v1"
    worker_id: uuid.UUID
    gates: list[str]
    source: Literal["ops"] = "ops"
    # added: market's per-worker counter, one up on every hand-set; quality ignores an event older than the last
    # one it applied, so a late redelivery never brings back a revoked gate. None on events from before it.
    seq: int | None = None


# ---------- quality ----------

ReasonCode = Literal[
    "guideline_miss",
    "incomplete",
    "wrong_language",
    "low_quality",
    "client_glossary_change",
    "client_ambiguous_instruction",
]
BILLABLE_REASONS: frozenset[str] = frozenset({"client_glossary_change", "client_ambiguous_instruction"})


class QualityVerdictAccepted(Event):
    """The canonical accept: the only event that creates money."""

    TYPE = "quality.verdict.accepted.v1"
    unit_id: uuid.UUID
    batch_id: uuid.UUID
    submission_id: uuid.UUID
    worker_id: uuid.UUID
    reviewer_id: uuid.UUID
    auditor_id: uuid.UUID | None
    rubric_version: str


class QualityVerdictRejected(Event):
    TYPE = "quality.verdict.rejected.v1"
    unit_id: uuid.UUID
    batch_id: uuid.UUID
    submission_id: uuid.UUID
    worker_id: uuid.UUID
    reviewer_id: uuid.UUID
    auditor_id: uuid.UUID | None
    rubric_version: str
    verdict: Literal["reject", "needs_edits"]
    reason_code: str
    billable: bool


# ---------- delivery (market) ----------


class DeliveryManifestCreated(Event):
    """The delivery gate passed: every unit of the batch is accepted. What the client invoice is built from."""

    TYPE = "delivery.manifest.created.v1"
    manifest_id: uuid.UUID
    batch_id: uuid.UUID
    project_id: uuid.UUID
    currency: str
    unit_price: Decimal
    accepted_units: int
    total_price: Decimal
    digest: str


# ---------- payout ----------


class PayoutWindowClosed(Event):
    TYPE = "payout.window.closed.v1"
    window_id: uuid.UUID
    starts_at: str
    ends_at: str
    currency: str
    line_count: int
    gross_total: Decimal
    held_total: Decimal


class PayoutPaid(Event):
    TYPE = "payout.paid.v1"
    window_id: uuid.UUID
    worker_id: uuid.UUID
    amount: Decimal
    currency: str
    rail_reference: str
    line_id: uuid.UUID | None = None  # added: the window line the rail paid
    utr: str | None = None  # added: the bank's transfer reference, when the rail reports one


# ---------- assess ----------


class AssessCertified(Event):
    """A passed paper: the only thing that grants a certification gate without an operator."""

    TYPE = "assess.certified.v1"
    worker_id: uuid.UUID
    gate: str
    paper_id: uuid.UUID
    score: Decimal


class AssessFailed(Event):
    TYPE = "assess.failed.v1"
    worker_id: uuid.UUID
    gate: str
    paper_id: uuid.UUID
    score: Decimal
    attempts_left: int


# ---------- talent ----------


class TalentOfferAccepted(Event):
    """The worker took the offer: the listing's gate opens to them when the listing asks for no paper."""

    TYPE = "talent.offer.accepted.v1"
    application_id: uuid.UUID
    listing_id: uuid.UUID
    worker_id: uuid.UUID
    gate: str | None


class TalentApplicationDecided(Event):
    TYPE = "talent.application.decided.v1"
    application_id: uuid.UUID
    listing_id: uuid.UUID
    listing_title: str
    worker_id: uuid.UUID
    decision: Literal["offer", "reject"]
    offer_expires_at: str | None = None


class WorkerEligible(Event):
    """The onboarding checklist is complete: identity, documents and the payout account are bound. No PII beyond
    what reconciliation needs."""

    TYPE = "worker.eligible.v1"
    worker_id: uuid.UUID
    legal_name_hash: str
    pan_last4: str


class TalentApplicationMoved(Event):
    """Every status change of an application, the first one included (`from_status` null on apply): the funnel
    analytics counts from these."""

    TYPE = "talent.application.moved.v1"
    application_id: uuid.UUID
    listing_id: uuid.UUID
    worker_id: uuid.UUID
    from_status: str | None
    to_status: str


class TalentPersonSeen(Event):
    """A person's display name as talent knows it: the token's name on first sight, the legal name once the
    worker's profile gives one. `name` null means forget it (erasure). Modules that show names keep a copy."""

    TYPE = "talent.person.seen.v1"
    id: uuid.UUID
    name: str | None
    kind: Literal["worker", "staff", "client"]


class WorkerConsentWithdrawn(Event):
    """The worker withdrew the data-processing consent: processing stops except what a legal duty needs."""

    TYPE = "worker.consent.withdrawn.v1"
    worker_id: uuid.UUID


class WorkerConsentGiven(Event):
    """The worker gave the data-processing consent (the first time, or again after withdrawing it): every block
    the withdrawal put on (tracker sessions, claims, payout holds) lifts."""

    TYPE = "worker.consent.given.v1"
    worker_id: uuid.UUID


class WorkerErasureRequested(Event):
    TYPE = "worker.erasure.requested.v1"
    worker_id: uuid.UUID
    due_at: str


class WorkerErasureCompleted(Event):
    """Talent erased the worker's personal data; notify clears the email, payout erases the bank account once every
    window holding the worker is paid. Ids and ledger amounts stay (legal retention)."""

    TYPE = "worker.erasure.completed.v1"
    worker_id: uuid.UUID


# ---------- payout adjustments ----------


class PayoutAdjustmentApproved(Event):
    TYPE = "payout.adjustment.approved.v1"
    adjustment_id: uuid.UUID
    worker_id: uuid.UUID
    amount: Decimal
    currency: str
    kind: Literal["bonus", "correction"]


class PayoutAccountVerified(Event):
    """The worker's bank account is registered with the rail and (where the rail can) verified by a penny drop.
    Talent completes the onboarding `bank` step when the name digest equals the worker's legal-name digest."""

    TYPE = "payout.account.verified.v1"
    worker_id: uuid.UUID
    account_name_hash: str  # pii_hash(normalise_name(account_name)) under YANTRA_PII_KEY
    account_last4: str
    ifsc: str
    verification: Literal["penny_drop", "none"]


class PayoutAccountRejected(Event):
    TYPE = "payout.account.rejected.v1"
    worker_id: uuid.UUID
    reason: str  # invalid_account | name_mismatch | rail_error


class PayoutLineFailed(Event):
    """A window line the rail could not deliver (failed) or the bank sent back (returned). Finance retries or
    releases it; the worker is told to check their bank account."""

    TYPE = "payout.line.failed.v1"
    window_id: uuid.UUID
    line_id: uuid.UUID
    worker_id: uuid.UUID
    amount: Decimal
    currency: str
    status: Literal["failed", "returned"]
    reason: str


class PayoutReconciliationDelta(Event):
    """A reconciliation run that did not balance. Nothing is adjusted; notify opens a payment ticket."""

    TYPE = "payout.reconciliation.delta.v1"
    run_id: uuid.UUID
    window_id: uuid.UUID
    currency: str
    earnings_total: Decimal
    lines_total: Decimal
    paid_total: Decimal
    rail_total: Decimal
    delta_lines: Decimal
    delta_rail: Decimal
    failed_lines: int
    processing_lines: int


# ---------- tracking ----------


class TrackingSessionEnded(Event):
    """One activity session closed (by the worker, by staleness or because its claim ended). Analytics sums it."""

    TYPE = "tracking.session.ended.v1"
    session_id: uuid.UUID
    worker_id: uuid.UUID
    claim_id: uuid.UUID | None
    project_id: uuid.UUID | None
    source: str
    started_at: str
    ended_at: str
    active_seconds: int
    idle_seconds: int


class TrackingCapExceeded(Event):
    TYPE = "tracking.cap.exceeded.v1"
    worker_id: uuid.UUID
    session_id: uuid.UUID
    week_start: str
    cap_hours: Decimal
    active_seconds: int


class TrackingAnomalyFlagged(Event):
    TYPE = "tracking.anomaly.flagged.v1"
    anomaly_id: uuid.UUID
    worker_id: uuid.UUID
    session_id: uuid.UUID | None
    kind: str
    detail: dict[str, Any]


class TrackingAnomalyUpheld(Event):
    """An operator upheld an anomaly: payout puts an integrity hold on the worker's account."""

    TYPE = "tracking.anomaly.upheld.v1"
    anomaly_id: uuid.UUID
    worker_id: uuid.UUID
    session_id: uuid.UUID | None
    kind: str
    decided_by: uuid.UUID


class PayoutHoldSet(Event):
    """A hold was put on (or lifted from: `until` is None) a worker's payouts, by hand or from an upheld anomaly."""

    TYPE = "payout.hold.set.v1"
    worker_id: uuid.UUID
    reason: str | None
    until: str | None
    source: Literal["manual", "anomaly"]
