"""What the warehouse keeps of an event: an explicit allowlist per event type. Ids, amounts, counts, statuses,
codes and timestamps stay; names, unit payloads and answers, documents, digests of personal data, bank details and
free text never land. A type not listed keeps only its well-formed ids (`id` and every `*_id`): a new event type is
safe by default, and the marts that want more of it list it here first.

Free text that a number reads only as present or absent (a manual hold's reason) is kept as `has_<field>`."""

import uuid
from typing import Any

KEEP: dict[str, frozenset[str]] = {
    t: frozenset(fields.split())
    for t, fields in {
        "work.unit.published.v1": "batch_id unit_count unit_pay unit_price review_pay currency mode project_id",
        "work.unit.claimed.v1": "unit_id claim_id worker_id expires_at batch_id project_id",
        "work.claim.expired.v1": "unit_id claim_id worker_id",
        "work.claim.released.v1": "unit_id claim_id worker_id",
        "work.unit.submitted.v1": (
            "unit_id batch_id claim_id submission_id worker_id rubric_version project_id cert_gate sensitive"
        ),
        "work.batch.purged.v1": "batch_id project_id unit_count",
        "worker.gates.set.v1": "worker_id gates source",
        "quality.verdict.accepted.v1": "unit_id batch_id submission_id worker_id reviewer_id auditor_id rubric_version",
        "quality.verdict.rejected.v1": (
            "unit_id batch_id submission_id worker_id reviewer_id auditor_id rubric_version "
            "verdict reason_code billable"
        ),
        "delivery.manifest.created.v1": (
            "manifest_id batch_id project_id currency unit_price accepted_units total_price"
        ),
        "payout.window.closed.v1": "window_id starts_at ends_at currency line_count gross_total held_total",
        "payout.paid.v1": "window_id worker_id amount currency line_id",
        "payout.adjustment.approved.v1": "adjustment_id worker_id amount currency kind",
        "payout.account.verified.v1": "worker_id verification",
        "payout.account.rejected.v1": "worker_id reason",  # a code: invalid_account | name_mismatch | rail_error
        "payout.line.failed.v1": "window_id line_id worker_id amount currency status",
        "payout.reconciliation.delta.v1": (
            "run_id window_id currency earnings_total lines_total paid_total rail_total delta_lines delta_rail "
            "failed_lines processing_lines"
        ),
        "payout.hold.set.v1": "worker_id until source",
        "assess.certified.v1": "worker_id gate paper_id score",
        "assess.failed.v1": "worker_id gate paper_id score attempts_left",
        "talent.offer.accepted.v1": "application_id listing_id worker_id gate",
        "talent.application.decided.v1": "application_id listing_id worker_id decision offer_expires_at",
        "talent.application.moved.v1": "application_id listing_id worker_id from_status to_status",
        "talent.person.seen.v1": "id kind",
        "worker.eligible.v1": "worker_id",
        "worker.consent.withdrawn.v1": "worker_id",
        "worker.consent.given.v1": "worker_id",
        "worker.erasure.requested.v1": "worker_id due_at",
        "worker.erasure.completed.v1": "worker_id",
        "tracking.session.ended.v1": (
            "session_id worker_id claim_id project_id source started_at ended_at active_seconds idle_seconds"
        ),
        "tracking.cap.exceeded.v1": "worker_id session_id week_start cap_hours active_seconds",
        "tracking.anomaly.flagged.v1": "anomaly_id worker_id session_id kind",
        "tracking.anomaly.upheld.v1": "anomaly_id worker_id session_id kind decided_by",
    }.items()
}
PRESENCE: dict[str, tuple[str, ...]] = {"payout.hold.set.v1": ("reason",)}
# the fields that name a person: an erased worker's id is replaced in each of them
PERSON_FIELDS = ("worker_id", "reviewer_id", "auditor_id", "decided_by", "id")


def _is_uuid(value: Any) -> bool:
    if not isinstance(value, str | uuid.UUID):
        return False
    try:
        uuid.UUID(str(value))
    except ValueError:
        return False
    return True


def is_id_field(key: str) -> bool:
    return key == "id" or key.endswith("_id")


def minimise(type_: str, data: dict[str, Any]) -> dict[str, Any]:
    """The part of `data` the warehouse may keep for an event of `type_`."""
    keep = KEEP.get(type_)
    if keep is None:
        return {k: v for k, v in data.items() if is_id_field(k) and _is_uuid(v)}
    out = {k: v for k, v in data.items() if k in keep}
    for field in PRESENCE.get(type_, ()):
        out[f"has_{field}"] = data.get(field) not in (None, "")
    return out
