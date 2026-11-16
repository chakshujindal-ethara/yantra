"""The market operations. Each function works inside the caller's session and never commits or rolls back
the whole unit of work: the HTTP layer owns it. Pure rules live in `rules.py`; this file is the thin shell."""

import hashlib
import json
import logging
import uuid
from collections.abc import Iterable
from datetime import UTC, datetime, timedelta
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

from sqlalchemy import String, and_, cast, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.orm import Session

from yantra_common.errors import Conflict, DomainError, Forbidden, Invalid, NotFound
from yantra_common.outbox import emit
from yantra_common.people import Person
from yantra_common.people import names_of as _names_of
from yantra_common.storage import Storage, deliverable_key, project_prefix, unit_key
from yantra_contracts.events.v1 import (
    DeliveryManifestCreated,
    WorkBatchPurged,
    WorkClaimExpired,
    WorkClaimReleased,
    WorkerGatesSet,
    WorkUnitClaimed,
    WorkUnitPublished,
    WorkUnitSubmitted,
)
from yantra_market.models import (
    OUTBOX,
    PERSON,
    UNKNOWN,
    Claim,
    ClientMember,
    ClientOrg,
    ClientProject,
    DeliveryManifest,
    ProjectFeedback,
    Submission,
    VerdictLog,
    WorkBatch,
    WorkerAvailability,
    WorkerHold,
    WorkerProfile,
    WorkUnit,
)
from yantra_market.rules import ImportReport, check_answer, margin, validate_lines
from yantra_market.schemas import ReasonRow, UnitCounts

log = logging.getLogger("yantra.market")
PAGE = 200
MAX_PAUSE = timedelta(days=90)  # a pause is a short break, not a resignation: the app asks again after it
PURGE_PASS = 500  # batches one retention pass may purge; each is its own transaction
STUCK_ASSIGNED_DAYS = 3  # an assigned unit waiting longer than this for its worker shows on the attention list


class BatchPurged(DomainError):
    """The batch's retention ran out: its answers are gone, so its deliverable cannot be written any more."""

    status = 410
    code = "batch_purged"


def constraint_name(error: IntegrityError) -> str:
    diag = getattr(error.orig, "diag", None)
    return str(getattr(diag, "constraint_name", "") or "")


def get_batch(session: Session, batch_id: uuid.UUID, lock: bool = False, shared: bool = False) -> WorkBatch:
    """`lock` takes the row FOR UPDATE (publish, pause, cancel: one at a time); `lock, shared` takes it FOR SHARE
    (a claim: many at once, but none while a lifecycle move holds the row, and no move while a claim is in flight)."""
    stmt = select(WorkBatch).where(WorkBatch.id == batch_id)
    batch = session.scalar(stmt.with_for_update(read=shared) if lock else stmt)
    if batch is None:
        raise NotFound("batch not found", batch_id=str(batch_id))
    return batch


def get_project(session: Session, project_id: uuid.UUID) -> ClientProject:
    project = session.get(ClientProject, project_id)
    if project is None:
        raise NotFound("project not found", project_id=str(project_id))
    return project


def projects_of(session: Session, batches: list[WorkBatch]) -> dict[uuid.UUID, ClientProject]:
    """The projects behind a page of batches, in one query, for the brief a worker sees (name, answer schema)."""
    ids = {b.project_id for b in batches}
    return {p.id: p for p in session.scalars(select(ClientProject).where(ClientProject.id.in_(ids)))} if ids else {}


# ---------- availability ----------


def upsert_availability(
    session: Session, worker_id: uuid.UUID, weekly_hours: int, paused_until: datetime | None
) -> WorkerAvailability:
    """The worker's weekly check-in. Their own statement, so it needs no profile row; the range check is the
    table's. One INSERT ... ON CONFLICT DO UPDATE, so two first-time check-ins at once both land on the one row.
    A pause already behind now is stored as none; one more than MAX_PAUSE ahead is refused. `updated_at` moves
    on every write so the app can show when they last checked in."""
    now = datetime.now(UTC)
    if paused_until is not None and paused_until <= now:
        paused_until = None
    if paused_until is not None and paused_until > now + MAX_PAUSE:
        raise Invalid(f"paused_until: more than {MAX_PAUSE.days} days ahead", worker_id=str(worker_id))
    values = {"weekly_hours": weekly_hours, "paused_until": paused_until, "updated_at": now}
    stmt = (
        pg_insert(WorkerAvailability)
        .values(worker_id=worker_id, **values)
        .on_conflict_do_update(index_elements=["worker_id"], set_=values)
        .returning(WorkerAvailability)
    )
    return session.scalars(stmt, execution_options={"populate_existing": True}).one()


def is_paused(session: Session, worker_id: uuid.UUID, now: datetime) -> bool:
    """A worker is paused while their `paused_until` lies ahead of `now`; no row or a lapsed pause is not paused."""
    row = session.get(WorkerAvailability, worker_id)
    return row is not None and row.paused_until is not None and row.paused_until > now


# ---------- import and publish ----------


def import_units(
    session: Session, batch_id: uuid.UUID, lines: list[dict[str, Any]], dry_run: bool, bucket: str | None = None
) -> ImportReport:
    """Validate every line against the project's payload schema. A dry run writes nothing and reports every bad
    line. A real import with any bad line writes nothing either: the caller fixes the file and retries.
    A payload that names stored media must name an object under the project's prefix (in `bucket`, when the
    deployment has storage); the first such key is kept on the unit. The batch row is locked so an import cannot
    race a publish."""
    batch = get_batch(session, batch_id, lock=True)
    if batch.status != "draft":
        raise Conflict("units can only be imported into a draft batch", batch_id=str(batch_id), status=batch.status)
    project = get_project(session, batch.project_id)
    existing = set(session.scalars(select(WorkUnit.external_ref).where(WorkUnit.batch_id == batch_id)).all())
    report, accepted = validate_lines(project.payload_schema, lines, existing, project_prefix(project.id), bucket)
    if dry_run:
        return report
    if report.errors:
        raise Invalid(
            "import rejected: fix the reported lines and retry", errors=[e.model_dump() for e in report.errors]
        )
    now = datetime.now(UTC)
    session.add_all(
        WorkUnit(
            batch_id=batch_id,
            external_ref=line.external_ref,
            payload=line.payload,
            payload_uri=line.payload_uri,
            assigned_worker_id=line.assigned_worker_id,
            assigned_at=now if line.assigned_worker_id else None,
            status="draft",
        )
        for line in accepted
    )
    session.flush()
    return report


def publish_batch(
    session: Session, batch_id: uuid.UUID, approved_by: str | None = None, approval_note: str | None = None
) -> WorkBatch:
    """Freeze pay and price on every unit and open the batch. A batch below its project's margin floor
    publishes only with a recorded approval."""
    batch = get_batch(session, batch_id, lock=True)
    if batch.status != "draft":
        raise Conflict("batch is not a draft", batch_id=str(batch_id), status=batch.status)
    project = get_project(session, batch.project_id)
    if session.scalar(select(WorkUnit.id).where(WorkUnit.batch_id == batch_id).limit(1)) is None:
        raise Invalid("a batch with no units cannot be published", batch_id=str(batch_id))
    m = margin(batch.unit_price, batch.unit_pay, batch.review_pay)
    if project.margin_floor is not None and m < project.margin_floor:
        if not approved_by:
            raise Conflict(
                "batch is below its margin floor; a recorded approval is required",
                margin=str(m),
                floor=str(project.margin_floor),
                batch_id=str(batch_id),
            ).with_code("below_margin_floor")
        batch.floor_approved_by = approved_by
        batch.floor_approval_note = approval_note
    unit_count = session.execute(
        update(WorkUnit)
        .where(WorkUnit.batch_id == batch_id, WorkUnit.status == "draft")
        .values(
            status="available",
            unit_pay=batch.unit_pay,
            unit_price=batch.unit_price,
            rubric_version=batch.rubric_version,
        )
    ).rowcount
    batch.status = "published"
    batch.published_at = datetime.now(UTC)
    emit(
        session,
        OUTBOX,
        f"batch/{batch.id}",
        WorkUnitPublished(
            batch_id=batch.id,
            unit_count=unit_count,
            unit_pay=batch.unit_pay,
            unit_price=batch.unit_price,
            review_pay=batch.review_pay,
            currency=batch.currency,
            mode=batch.mode,
            project_id=batch.project_id,
        ),
    )
    session.flush()
    return batch


# ---------- claims ----------


def claimable_by(worker_id: uuid.UUID, mode: str) -> Any:
    """One rule for claiming and for browsing: an assigned unit belongs to its worker in every mode; an unassigned
    one is open to anyone in open mode and to nobody in assigned mode."""
    if mode == "assigned":
        return WorkUnit.assigned_worker_id == worker_id
    return or_(WorkUnit.assigned_worker_id.is_(None), WorkUnit.assigned_worker_id == worker_id)


def _eligible(session: Session, worker_id: uuid.UUID, project: ClientProject) -> None:
    worker = session.get(WorkerProfile, worker_id)
    if worker is not None and worker.consent_withdrawn_at is not None:
        raise Forbidden("worker withdrew their data-processing consent", worker_id=str(worker_id)).with_code(
            "consent_withdrawn"
        )
    if worker is None or worker.status not in ("eligible", "active"):
        raise Forbidden("worker is not eligible", worker_id=str(worker_id))
    if project.cert_gate and project.cert_gate not in worker.cert_gates:
        raise Forbidden(
            "worker lacks the certification for this project", worker_id=str(worker_id), gate=project.cert_gate
        )


def _existing_claim(session: Session, worker_id: uuid.UUID, idempotency_key: str) -> Claim | None:
    return session.scalar(select(Claim).where(Claim.worker_id == worker_id, Claim.idempotency_key == idempotency_key))


def _same_batch_or_conflict(session: Session, claim: Claim, batch_id: uuid.UUID) -> Claim:
    unit = session.get(WorkUnit, claim.unit_id)
    if unit is None or unit.batch_id != batch_id:
        raise Conflict("idempotency key was used for another batch", claim_id=str(claim.id)).with_code("key_reused")
    return claim


def claim_unit(session: Session, batch_id: uuid.UUID, worker_id: uuid.UUID, idempotency_key: str) -> Claim:
    """One short transaction: a retried key returns the worker's first claim; one live claim per worker;
    the unit is picked with SKIP LOCKED so two workers never get the same one. The batch row is held FOR SHARE
    until the commit, so a pause or cancel (FOR UPDATE) runs strictly before or after the claim, never between
    its status check and its insert."""
    existing = _existing_claim(session, worker_id, idempotency_key)
    if existing is not None:
        return _same_batch_or_conflict(session, existing, batch_id)
    if is_paused(session, worker_id, datetime.now(UTC)):
        raise Forbidden("worker has paused their availability", worker_id=str(worker_id)).with_code(
            "availability_paused"
        )
    batch = get_batch(session, batch_id, lock=True, shared=True)
    if batch.status == "paused":
        raise Conflict("batch is paused", batch_id=str(batch_id), status=batch.status).with_code("batch_paused")
    if batch.status != "published":
        raise Conflict("batch is not open for claims", batch_id=str(batch_id), status=batch.status)
    _eligible(session, worker_id, get_project(session, batch.project_id))
    pick = (
        select(WorkUnit)
        .where(WorkUnit.batch_id == batch_id, WorkUnit.status == "available", claimable_by(worker_id, batch.mode))
        .order_by(WorkUnit.id)
        .limit(1)
        .with_for_update(skip_locked=True)
    )
    unit = session.scalar(pick)
    if unit is None:
        raise NotFound("no unit available for this worker", batch_id=str(batch_id))
    claim = Claim(
        unit_id=unit.id,
        worker_id=worker_id,
        idempotency_key=idempotency_key,
        status="active",
        expires_at=datetime.now(UTC) + timedelta(minutes=batch.claim_ttl_minutes),
    )
    try:
        with session.begin_nested():  # a savepoint: a refused insert never discards the caller's other work
            session.add(claim)
            session.flush()
    except IntegrityError as e:
        # the same worker raced itself: the first writer's claim is the answer, whichever index fired first
        raced = _existing_claim(session, worker_id, idempotency_key)
        if raced is not None:
            return _same_batch_or_conflict(session, raced, batch_id)
        name = constraint_name(e)
        if name == "ix_claim_one_live_per_worker":
            raise Conflict("worker already has a live claim", worker_id=str(worker_id)).with_code(
                "one_live_claim"
            ) from e
        log.warning("claim insert refused constraint=%s worker_id=%s batch_id=%s", name, worker_id, batch_id)
        raise
    unit.status = "claimed"
    unit.current_claim_id = claim.id
    emit(
        session,
        OUTBOX,
        f"unit/{unit.id}",
        WorkUnitClaimed(
            unit_id=unit.id,
            claim_id=claim.id,
            worker_id=worker_id,
            expires_at=claim.expires_at.isoformat(),
            batch_id=batch.id,
            project_id=batch.project_id,
        ),
    )
    session.flush()
    return claim


def release_expired_claims(
    session: Session, now: datetime | None = None, limit: int = 500, released_by: uuid.UUID | None = None
) -> tuple[list[uuid.UUID], bool]:
    """Expired claims return their units to the pool. Run by a scheduled job (`released_by` None) or by an operator
    pressing "release all" (their id); safe to run concurrently. Returns the released claim ids and whether more
    remain beyond `limit`."""
    now = now or datetime.now(UTC)
    claims = session.scalars(
        select(Claim)
        .where(Claim.status == "active", Claim.expires_at < now)
        .order_by(Claim.expires_at)
        .limit(limit + 1)
        .with_for_update(skip_locked=True)
    ).all()
    more = len(claims) > limit
    released: list[uuid.UUID] = []
    for claim in claims[:limit]:
        _end_claim(session, claim, "expired", now, released_by)
        emit(
            session,
            OUTBOX,
            f"unit/{claim.unit_id}",
            WorkClaimExpired(unit_id=claim.unit_id, claim_id=claim.id, worker_id=claim.worker_id),
        )
        released.append(claim.id)
    session.flush()
    return released, more


def _end_claim(session: Session, claim: Claim, status: str, now: datetime, released_by: uuid.UUID | None) -> None:
    """Close a claim without a submission and give its unit back to the pool (an assignment stays)."""
    claim.status = status
    claim.released_at = now
    claim.released_by = released_by
    flipped = session.execute(
        update(WorkUnit)
        .where(WorkUnit.id == claim.unit_id, WorkUnit.current_claim_id == claim.id)
        .values(status="available", current_claim_id=None)
    ).rowcount
    if flipped != 1:
        log.warning("ended claim no longer current claim_id=%s unit_id=%s", claim.id, claim.unit_id)


def release_claim(session: Session, claim_id: uuid.UUID, worker_id: uuid.UUID, now: datetime | None = None) -> Claim:
    """The worker gives their live claim back before it runs out: the unit is available again at once."""
    now = now or datetime.now(UTC)
    claim = session.scalar(select(Claim).where(Claim.id == claim_id).with_for_update())
    if claim is None:
        raise NotFound("claim not found", claim_id=str(claim_id))
    if claim.worker_id != worker_id:
        raise Forbidden("claim belongs to another worker", claim_id=str(claim_id))
    if claim.status != "active":
        raise Conflict("claim is not live", claim_id=str(claim_id), status=claim.status).with_code("claim_not_live")
    _end_claim(session, claim, "released", now, worker_id)
    emit(
        session,
        OUTBOX,
        f"unit/{claim.unit_id}",
        WorkClaimReleased(unit_id=claim.unit_id, claim_id=claim.id, worker_id=worker_id),
    )
    session.flush()
    return claim


def release_expired_claim(
    session: Session, claim_id: uuid.UUID, released_by: uuid.UUID, now: datetime | None = None
) -> Claim:
    """An operator releases one stuck claim from the stuck-work list. Only an active claim past its time."""
    now = now or datetime.now(UTC)
    claim = session.scalar(select(Claim).where(Claim.id == claim_id).with_for_update())
    if claim is None:
        raise NotFound("claim not found", claim_id=str(claim_id))
    if claim.status != "active" or claim.expires_at >= now:
        raise Conflict(
            "only a live claim past its time can be released here", claim_id=str(claim_id), status=claim.status
        ).with_code("claim_not_expired")
    _end_claim(session, claim, "expired", now, released_by)
    emit(
        session,
        OUTBOX,
        f"unit/{claim.unit_id}",
        WorkClaimExpired(unit_id=claim.unit_id, claim_id=claim.id, worker_id=claim.worker_id),
    )
    session.flush()
    log.info("expired claim released by hand claim_id=%s released_by=%s", claim.id, released_by)
    return claim


def expired_claims(
    session: Session, now: datetime | None = None, limit: int = 200
) -> list[tuple[Claim, WorkUnit, WorkBatch, ClientProject]]:
    """Live claims past their time, oldest first: what the stuck-work list shows."""
    now = now or datetime.now(UTC)
    rows = session.execute(
        select(Claim, WorkUnit, WorkBatch, ClientProject)
        .join(WorkUnit, WorkUnit.id == Claim.unit_id)
        .join(WorkBatch, WorkBatch.id == WorkUnit.batch_id)
        .join(ClientProject, ClientProject.id == WorkBatch.project_id)
        .where(Claim.status == "active", Claim.expires_at < now)
        .order_by(Claim.expires_at, Claim.id)
        .limit(limit)
    ).all()
    return [(c, u, b, p) for c, u, b, p in rows]


def released_claims(session: Session, since: datetime, limit: int = 200) -> list[tuple[Claim, WorkUnit]]:
    """Claims that ended without a submission since `since`, newest first: the expiry job's and people's releases."""
    rows = session.execute(
        select(Claim, WorkUnit)
        .join(WorkUnit, WorkUnit.id == Claim.unit_id)
        .where(Claim.released_at.is_not(None), Claim.released_at >= since)
        .order_by(Claim.released_at.desc(), Claim.id)
        .limit(limit)
    ).all()
    return [(c, u) for c, u in rows]


# ---------- submissions ----------


def submit(
    session: Session, claim_id: uuid.UUID, worker_id: uuid.UUID, answer: dict[str, Any], now: datetime | None = None
) -> Submission:
    """A retry returns the first submission unchanged. The claim must be live, unexpired and the worker's own, and
    the answer must satisfy the project's answer schema when it has one: a bad answer writes nothing."""
    now = now or datetime.now(UTC)
    claim = session.scalar(select(Claim).where(Claim.id == claim_id).with_for_update())
    if claim is None:
        raise NotFound("claim not found", claim_id=str(claim_id))
    if claim.worker_id != worker_id:
        raise Forbidden("claim belongs to another worker", claim_id=str(claim_id))
    previous = session.scalar(select(Submission).where(Submission.claim_id == claim_id))
    if previous is not None:
        return previous
    if claim.status != "active":
        raise Conflict("claim is not live", claim_id=str(claim_id), status=claim.status).with_code("claim_not_live")
    if claim.expires_at < now:
        raise Conflict("claim has expired", claim_id=str(claim_id), status="expired").with_code("claim_expired")
    unit = session.get(WorkUnit, claim.unit_id)
    if unit is None:  # pragma: no cover - the foreign key makes this unreachable; kept for the type checker
        raise NotFound("unit not found", unit_id=str(claim.unit_id))
    batch = get_batch(session, unit.batch_id)
    if batch.status == "cancelled":
        raise Conflict("batch was cancelled", claim_id=str(claim_id), batch_id=str(batch.id)).with_code(
            "batch_cancelled"
        )
    project = get_project(session, batch.project_id)
    if project.answer_schema is not None:
        problem = check_answer(project.answer_schema, answer)
        if problem:
            raise Invalid(f"answer: {problem}", claim_id=str(claim_id))
    submission = Submission(
        claim_id=claim.id,
        unit_id=unit.id,
        worker_id=worker_id,
        answer=answer,
        rubric_version=unit.rubric_version or "v1",
    )
    session.add(submission)
    claim.status = "submitted"
    unit.status = "submitted"
    session.flush()
    emit(
        session,
        OUTBOX,
        f"unit/{unit.id}",
        WorkUnitSubmitted(
            unit_id=unit.id,
            batch_id=unit.batch_id,
            claim_id=claim.id,
            submission_id=submission.id,
            worker_id=worker_id,
            rubric_version=submission.rubric_version,
            payload=unit.payload,
            answer=answer,
            project_id=project.id,
            cert_gate=project.cert_gate,
            sensitive=project.sensitive,
        ),
    )
    return submission


# ---------- what a worker browses ----------


def open_batches(session: Session, worker_id: uuid.UUID) -> list[tuple[WorkBatch, int]]:
    """Published batches with at least one unit this worker could claim (open units, or units assigned to them),
    each with that count. A paused worker sees none; a project behind a certification gate shows only to workers
    who hold it, so the list is exactly what a claim would accept. The router shapes it for the worker: the pay,
    never the price."""
    if is_paused(session, worker_id, datetime.now(UTC)):
        return []
    worker = session.get(WorkerProfile, worker_id)
    gates: list[str] = list(worker.cert_gates) if worker is not None else []
    rows = session.execute(
        select(WorkBatch, func.count(WorkUnit.id))
        .join(WorkUnit, WorkUnit.batch_id == WorkBatch.id)
        .join(ClientProject, ClientProject.id == WorkBatch.project_id)
        .where(
            WorkBatch.status == "published",
            WorkUnit.status == "available",
            or_(ClientProject.cert_gate.is_(None), ClientProject.cert_gate.in_(gates)),
            or_(
                and_(WorkBatch.mode == "assigned", WorkUnit.assigned_worker_id == worker_id),
                and_(WorkBatch.mode != "assigned", claimable_by(worker_id, "open")),
            ),
        )
        .group_by(WorkBatch.id)
        .order_by(WorkBatch.published_at.desc())
        .limit(PAGE)
    ).all()
    return [(batch, int(n)) for batch, n in rows]


def active_claim(session: Session, worker_id: uuid.UUID) -> tuple[Claim, WorkUnit] | None:
    """The worker's live claim: active and not past its TTL (an expired one is gone even before the release job)."""
    claim = session.scalar(
        select(Claim).where(
            Claim.worker_id == worker_id, Claim.status == "active", Claim.expires_at > datetime.now(UTC)
        )
    )
    if claim is None:
        return None
    unit = session.get(WorkUnit, claim.unit_id)
    if unit is None:  # pragma: no cover - the foreign key makes this unreachable; kept for the type checker
        raise NotFound("unit not found", unit_id=str(claim.unit_id))
    return claim, unit


# ---------- delivery ----------


def _manifest_units(session: Session, batch_id: uuid.UUID) -> list[dict[str, Any]]:
    rows = session.execute(
        select(WorkUnit, Submission)
        .join(Submission, Submission.unit_id == WorkUnit.id)
        .where(WorkUnit.batch_id == batch_id, WorkUnit.status == "accepted")
        .order_by(WorkUnit.external_ref, Submission.submitted_at.desc())
    ).all()
    units: list[dict[str, Any]] = []
    for unit, sub in rows:  # the first row per unit is its latest submission: the delivered answer
        if units and units[-1]["unit_id"] == str(unit.id):
            continue
        units.append(
            {
                "unit_id": str(unit.id),
                "external_ref": unit.external_ref,
                "answer": sub.answer,
                "rubric_version": sub.rubric_version,
                "submitted_at": sub.submitted_at.isoformat(),
            }
        )
    return units


def build_manifest(session: Session, batch_id: uuid.UUID) -> DeliveryManifest:
    """The delivery gate. Every unit must be accepted; one unit short holds the whole batch, with the counts.
    Built once: a second call returns the same manifest. The batch completes when its manifest exists."""
    batch = get_batch(session, batch_id, lock=True)
    existing = session.scalar(select(DeliveryManifest).where(DeliveryManifest.batch_id == batch_id))
    if existing is not None:
        return existing
    if batch.status != "published":
        raise Conflict("batch is not published", batch_id=str(batch_id), status=batch.status)
    counts = {
        status: int(n)
        for status, n in session.execute(
            select(WorkUnit.status, func.count()).where(WorkUnit.batch_id == batch_id).group_by(WorkUnit.status)
        )
    }
    held = {k: v for k, v in counts.items() if k != "accepted"}
    if held:
        raise Conflict("batch is held: not every unit is accepted", batch_id=str(batch_id), held=held).with_code(
            "batch_held"
        )
    units = _manifest_units(session, batch_id)
    digest = hashlib.sha256(json.dumps(units, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    manifest = DeliveryManifest(
        batch_id=batch.id,
        project_id=batch.project_id,
        currency=batch.currency,
        unit_price=batch.unit_price,
        accepted_units=len(units),
        total_price=batch.unit_price * len(units),
        digest=digest,
        units=units,
    )
    session.add(manifest)
    batch.status = "completed"
    session.flush()
    emit(
        session,
        OUTBOX,
        f"batch/{batch.id}",
        DeliveryManifestCreated(
            manifest_id=manifest.id,
            batch_id=batch.id,
            project_id=batch.project_id,
            currency=batch.currency,
            unit_price=batch.unit_price,
            accepted_units=manifest.accepted_units,
            total_price=manifest.total_price,
            digest=digest,
        ),
    )
    log.info("manifest built batch_id=%s units=%s", batch.id, manifest.accepted_units)
    return manifest


# ---------- the operator's reads: counts by GROUP BY, never a row per unit ----------

Scope = frozenset[uuid.UUID] | None  # the client orgs a caller may read; None is every org (an operator)


def unit_counts_by_batch(session: Session, batch_ids: Iterable[uuid.UUID]) -> dict[uuid.UUID, UnitCounts]:
    """One GROUP BY for a page of batches. Every batch asked for gets a row, zeros included."""
    ids = list(batch_ids)
    counts = {b: UnitCounts() for b in ids}
    if not ids:
        return counts
    rows = session.execute(
        select(WorkUnit.batch_id, WorkUnit.status, func.count())
        .where(WorkUnit.batch_id.in_(ids))
        .group_by(WorkUnit.batch_id, WorkUnit.status)
    )
    for batch_id, status, n in rows:
        _tally(counts[batch_id], status, int(n))
    return counts


def unit_counts_by_project(session: Session, project_ids: Iterable[uuid.UUID]) -> dict[uuid.UUID, UnitCounts]:
    ids = list(project_ids)
    counts = {p: UnitCounts() for p in ids}
    if not ids:
        return counts
    rows = session.execute(
        select(WorkBatch.project_id, WorkUnit.status, func.count())
        .join(WorkBatch, WorkBatch.id == WorkUnit.batch_id)
        .where(WorkBatch.project_id.in_(ids))
        .group_by(WorkBatch.project_id, WorkUnit.status)
    )
    for project_id, status, n in rows:
        _tally(counts[project_id], status, int(n))
    return counts


def _tally(counts: UnitCounts, status: str, n: int) -> None:
    counts.total += n
    if hasattr(counts, status):  # a draft unit counts in the total only
        setattr(counts, status, getattr(counts, status) + n)


def sum_counts(parts: Iterable[UnitCounts]) -> UnitCounts:
    total = UnitCounts()
    for part in parts:
        for key, value in part.model_dump().items():
            setattr(total, key, getattr(total, key) + value)
    return total


def live_claims_by_batch(session: Session, batch_ids: Iterable[uuid.UUID]) -> dict[uuid.UUID, int]:
    """Claims still active and inside their TTL, the ones a worker could still submit on."""
    ids = list(batch_ids)
    live = dict.fromkeys(ids, 0)
    if not ids:
        return live
    rows = session.execute(
        select(WorkUnit.batch_id, func.count())
        .select_from(Claim)
        .join(WorkUnit, WorkUnit.id == Claim.unit_id)
        .where(WorkUnit.batch_id.in_(ids), Claim.status == "active", Claim.expires_at > datetime.now(UTC))
        .group_by(WorkUnit.batch_id)
    )
    for batch_id, n in rows:
        live[batch_id] = int(n)
    return live


def manifests_by_batch(session: Session, batch_ids: Iterable[uuid.UUID]) -> dict[uuid.UUID, DeliveryManifest]:
    ids = list(batch_ids)
    if not ids:
        return {}
    rows = session.scalars(select(DeliveryManifest).where(DeliveryManifest.batch_id.in_(ids)))
    return {m.batch_id: m for m in rows}


def batches_of(session: Session, project_id: uuid.UUID) -> list[WorkBatch]:
    stmt = select(WorkBatch).where(WorkBatch.project_id == project_id).order_by(WorkBatch.created_at, WorkBatch.id)
    return list(session.scalars(stmt))


def batch_count_by_project(session: Session, project_ids: Iterable[uuid.UUID]) -> dict[uuid.UUID, int]:
    ids = list(project_ids)
    counts = dict.fromkeys(ids, 0)
    if not ids:
        return counts
    rows = session.execute(
        select(WorkBatch.project_id, func.count()).where(WorkBatch.project_id.in_(ids)).group_by(WorkBatch.project_id)
    )
    for project_id, n in rows:
        counts[project_id] = int(n)
    return counts


def list_projects(session: Session, scope: Scope = None) -> list[ClientProject]:
    stmt = select(ClientProject).order_by(ClientProject.created_at.desc(), ClientProject.id)
    if scope is not None:
        stmt = stmt.where(ClientProject.client_org_id.in_(scope))
    return list(session.scalars(stmt))


def scoped_project(session: Session, project_id: uuid.UUID, scope: Scope) -> ClientProject:
    """A project the caller may read. Outside the scope it is 404, never 403: existence is not leaked."""
    project = session.get(ClientProject, project_id)
    if project is None or (scope is not None and project.client_org_id not in scope):
        raise NotFound("project not found", project_id=str(project_id))
    return project


def reasons_for(session: Session, project_ids: Iterable[uuid.UUID]) -> list[ReasonRow]:
    """The reason distribution of every rework verdict in the log, largest first."""
    ids = list(project_ids)
    if not ids:
        return []
    rows = session.execute(
        select(VerdictLog.reason_code, VerdictLog.billable, func.count())
        .where(VerdictLog.project_id.in_(ids), VerdictLog.reason_code.is_not(None))
        .group_by(VerdictLog.reason_code, VerdictLog.billable)
        .order_by(func.count().desc(), VerdictLog.reason_code)
    )
    return [ReasonRow(reason_code=str(code), count=int(n), billable=bool(billable)) for code, billable, n in rows]


def acceptance_rate(session: Session, project_ids: Iterable[uuid.UUID]) -> Decimal | None:
    """accepted / (accepted + rejected + needs_edits) over the verdict log; None when nothing has been decided."""
    ids = list(project_ids)
    if not ids:
        return None
    rows = session.execute(
        select(VerdictLog.verdict, func.count()).where(VerdictLog.project_id.in_(ids)).group_by(VerdictLog.verdict)
    )
    by_verdict = {str(v): int(n) for v, n in rows}
    decided = sum(by_verdict.values())
    if decided == 0:
        return None
    return (Decimal(by_verdict.get("accept", 0)) / Decimal(decided)).quantize(Decimal("0.0001"), rounding=ROUND_HALF_UP)


def billable_rework(session: Session, project_ids: Iterable[uuid.UUID]) -> int:
    ids = list(project_ids)
    if not ids:
        return 0
    where = (VerdictLog.project_id.in_(ids), VerdictLog.billable.is_(True))
    n = session.scalar(select(func.count()).select_from(VerdictLog).where(*where))
    return int(n or 0)


def deliveries_of(session: Session, project_ids: Iterable[uuid.UUID]) -> list[DeliveryManifest]:
    ids = list(project_ids)
    if not ids:
        return []
    stmt = select(DeliveryManifest).where(DeliveryManifest.project_id.in_(ids)).order_by(DeliveryManifest.created_at)
    return list(session.scalars(stmt))


def invoice_total(session: Session, project: ClientProject) -> Decimal:
    """What the client owes to date on one project, in the project's currency:

        sum over its manifests of accepted_units x unit_price (the delivered batches, frozen at delivery)
      + sum over its billable rework verdicts of the unit_price of the verdict's batch

    A billable rework (a reason the client caused: a glossary change, an ambiguous instruction) is charged once per
    verdict at the batch's price, on top of the delivered units.
    """
    delivered = session.scalar(
        select(func.coalesce(func.sum(DeliveryManifest.accepted_units * DeliveryManifest.unit_price), 0)).where(
            DeliveryManifest.project_id == project.id
        )
    )
    rework = session.scalar(
        select(func.coalesce(func.sum(WorkBatch.unit_price), 0))
        .select_from(VerdictLog)
        .join(WorkBatch, WorkBatch.id == VerdictLog.batch_id)
        .where(VerdictLog.project_id == project.id, VerdictLog.billable.is_(True))
    )
    return Decimal(delivered or 0) + Decimal(rework or 0)


def feedback_of(session: Session, project_id: uuid.UUID) -> list[ProjectFeedback]:
    stmt = select(ProjectFeedback).where(ProjectFeedback.project_id == project_id).order_by(ProjectFeedback.created_at)
    return list(session.scalars(stmt))


def add_feedback(
    session: Session, project: ClientProject, author_id: uuid.UUID, body: str, author_kind: str = "client"
) -> ProjectFeedback:
    """One note on the project's thread: a client's, or (`author_kind` staff) an operator's answer."""
    row = ProjectFeedback(project_id=project.id, author_id=author_id, body=body, author_kind=author_kind)
    session.add(row)
    session.flush()
    session.refresh(row)
    return row


# ---------- the operator's writes ----------


def patch_project(session: Session, project_id: uuid.UUID, changes: dict[str, Any]) -> ClientProject:
    """Apply the fields sent. A new rubric version appends `{version, note, at}` to the rubric log (the same
    version again appends nothing); a client org must exist. The schema check is the router's, as on creation."""
    project = get_project(session, project_id)
    note = changes.pop("rubric_note", None)
    version = changes.pop("rubric_version", None)
    org_id = changes.get("client_org_id")
    if org_id is not None and session.get(ClientOrg, org_id) is None:
        raise NotFound("client org not found", client_org_id=str(org_id))
    status = changes.get("status")
    if status is not None and status != project.status:
        project.closed_at = datetime.now(UTC) if status == "closed" else None
    for key, value in changes.items():
        setattr(project, key, value)
    if version is not None and version != project.rubric_version:
        project.rubric_version = version
        project.rubric_log = [
            *project.rubric_log,
            {"version": version, "note": note, "at": datetime.now(UTC).isoformat()},
        ]
    session.flush()
    return project


def pause_batch(session: Session, batch_id: uuid.UUID) -> WorkBatch:
    """Hide a published batch from workers. A claim in flight may still be submitted; a new claim is refused."""
    batch = get_batch(session, batch_id, lock=True)
    if batch.status != "published":
        raise Conflict("only a published batch can be paused", batch_id=str(batch_id), status=batch.status)
    batch.status = "paused"
    session.flush()
    return batch


def resume_batch(session: Session, batch_id: uuid.UUID) -> WorkBatch:
    batch = get_batch(session, batch_id, lock=True)
    if batch.status != "paused":
        raise Conflict("only a paused batch can be resumed", batch_id=str(batch_id), status=batch.status)
    batch.status = "published"
    session.flush()
    return batch


def cancel_batch(session: Session, batch_id: uuid.UUID) -> WorkBatch:
    """End a batch nobody is working on. A live claim blocks it: a worker mid-unit is never stranded."""
    batch = get_batch(session, batch_id, lock=True)
    if batch.status not in ("draft", "published", "paused"):
        raise Conflict("batch cannot be cancelled", batch_id=str(batch_id), status=batch.status)
    live = live_claims_by_batch(session, [batch_id])[batch_id]
    if live:
        raise Conflict("batch has live claims", batch_id=str(batch_id), live_claims=live).with_code(
            "batch_has_live_claims"
        )
    batch.status = "cancelled"
    session.flush()
    return batch


def list_units(
    session: Session, batch_id: uuid.UUID, status: str | None, limit: int, offset: int
) -> tuple[int, list[WorkUnit]]:
    get_batch(session, batch_id)
    where = [WorkUnit.batch_id == batch_id]
    if status is not None:
        where.append(WorkUnit.status == status)
    total = int(session.scalar(select(func.count()).select_from(WorkUnit).where(*where)) or 0)
    items = session.scalars(
        select(WorkUnit).where(*where).order_by(WorkUnit.external_ref, WorkUnit.id).limit(limit).offset(offset)
    ).all()
    return total, list(items)


def list_workers(
    session: Session, status: str | None, gate: str | None, q: str | None, limit: int, offset: int
) -> tuple[int, list[tuple[WorkerProfile, WorkerAvailability | None]]]:
    """The bench. `gate` is a JSONB containment test; `q` matches the start of the id's text."""
    where = []
    if status is not None:
        where.append(WorkerProfile.status == status)
    if gate is not None:
        where.append(WorkerProfile.cert_gates.contains([gate]))
    if q:
        where.append(cast(WorkerProfile.id, String).like(q.lower() + "%"))
    total = int(session.scalar(select(func.count()).select_from(WorkerProfile).where(*where)) or 0)
    rows = session.execute(
        select(WorkerProfile, WorkerAvailability)
        .outerjoin(WorkerAvailability, WorkerAvailability.worker_id == WorkerProfile.id)
        .where(*where)
        .order_by(WorkerProfile.updated_at.desc(), WorkerProfile.id)
        .limit(limit)
        .offset(offset)
    ).all()
    return total, [(w, a) for w, a in rows]


def get_worker(session: Session, worker_id: uuid.UUID) -> tuple[WorkerProfile, WorkerAvailability | None]:
    worker = session.get(WorkerProfile, worker_id)
    if worker is None:
        raise NotFound("worker not found", worker_id=str(worker_id))
    return worker, session.get(WorkerAvailability, worker_id)


# ---------- client orgs and membership ----------


def create_org(session: Session, name: str) -> ClientOrg:
    org = ClientOrg(name=name)
    session.add(org)
    session.flush()
    session.refresh(org)
    return org


def get_org(session: Session, org_id: uuid.UUID) -> ClientOrg:
    org = session.get(ClientOrg, org_id)
    if org is None:
        raise NotFound("client org not found", client_org_id=str(org_id))
    return org


def list_orgs(session: Session, scope: Scope = None) -> list[tuple[ClientOrg, list[uuid.UUID]]]:
    stmt = select(ClientOrg).order_by(ClientOrg.created_at, ClientOrg.id)
    if scope is not None:
        stmt = stmt.where(ClientOrg.id.in_(scope))
    orgs = list(session.scalars(stmt))
    members: dict[uuid.UUID, list[uuid.UUID]] = {o.id: [] for o in orgs}
    if orgs:
        rows = session.execute(
            select(ClientMember.org_id, ClientMember.user_id)
            .where(ClientMember.org_id.in_(list(members)))
            .order_by(ClientMember.created_at, ClientMember.user_id)
        )
        for org_id, user_id in rows:
            members[org_id].append(user_id)
    return [(o, members[o.id]) for o in orgs]


def add_member(session: Session, org_id: uuid.UUID, user_id: uuid.UUID) -> None:
    """Idempotent: a member added twice is a member once."""
    get_org(session, org_id)
    session.execute(
        pg_insert(ClientMember)
        .values(org_id=org_id, user_id=user_id, created_at=datetime.now(UTC))
        .on_conflict_do_nothing(index_elements=["org_id", "user_id"])
    )


def remove_member(session: Session, org_id: uuid.UUID, user_id: uuid.UUID) -> None:
    get_org(session, org_id)
    member = session.get(ClientMember, (org_id, user_id))
    if member is not None:
        session.delete(member)
        session.flush()


def orgs_of_user(session: Session, user_id: uuid.UUID) -> frozenset[uuid.UUID]:
    return frozenset(session.scalars(select(ClientMember.org_id).where(ClientMember.user_id == user_id)))


def client_manifest(session: Session, batch_id: uuid.UUID, scope: Scope) -> DeliveryManifest:
    """The delivery of a batch the caller's org owns. No manifest yet, or another org's batch: 404 alike."""
    batch = session.get(WorkBatch, batch_id)
    if batch is None:
        raise NotFound("manifest not found", batch_id=str(batch_id))
    scoped_project(session, batch.project_id, scope)
    manifest = session.scalar(select(DeliveryManifest).where(DeliveryManifest.batch_id == batch_id))
    if manifest is None:
        raise NotFound("manifest not found", batch_id=str(batch_id))
    return manifest


# ---------- gates and eligibility from events ----------


def _profile_for_update(session: Session, worker_id: uuid.UUID, status: str) -> WorkerProfile:
    """The locked profile row, created with `status` when absent. The insert is ON CONFLICT DO NOTHING so two
    events for a new worker at once both end up updating the one row instead of one of them failing."""
    session.execute(
        pg_insert(WorkerProfile)
        .values(id=worker_id, status=status, cert_gates=[], updated_at=datetime.now(UTC))
        .on_conflict_do_nothing(index_elements=["id"])
    )
    stmt = select(WorkerProfile).where(WorkerProfile.id == worker_id).with_for_update()
    return session.scalars(stmt, execution_options={"populate_existing": True}).one()


def grant_gate(session: Session, worker_id: uuid.UUID, gate: str) -> WorkerProfile:
    """Add a certification gate. A worker nobody has vouched for yet is born `unknown`: they hold the gate but
    cannot claim until eligibility arrives. Granting a gate twice changes nothing."""
    worker = _profile_for_update(session, worker_id, UNKNOWN)
    if gate not in worker.earned_gates:
        worker.earned_gates = [*worker.earned_gates, gate]
    if gate not in worker.cert_gates:
        worker.cert_gates = [*worker.cert_gates, gate]
        worker.updated_at = datetime.now(UTC)
    session.flush()
    return worker


def set_worker_by_hand(
    session: Session,
    worker_id: uuid.UUID,
    status: str,
    partner_ref: int | None,
    gates: list[str] | None,
    caller: uuid.UUID | None,
) -> WorkerProfile:
    """Odoo's or an operator's view of the worker: status and partner as sent. `gates`, when sent, replaces the
    gates set by hand before (a gate earned from a paper or an offer stays) and is announced with the next
    `gates_seq`, so quality applies hand-sets in the order they were made. Nobody sets their own (403 `self_action`).
    The profile row is locked, so two hand-sets at once get two sequence numbers in commit order."""
    if caller is not None and caller == worker_id:
        raise Forbidden("you cannot change your own worker record", worker_id=str(worker_id)).with_code("self_action")
    worker = _profile_for_update(session, worker_id, status)
    worker.status, worker.partner_ref = status, partner_ref
    if gates is not None:
        hand_set = sorted(set(gates))
        worker.ops_gates = hand_set
        worker.cert_gates = sorted(set(worker.earned_gates) | set(hand_set))
        worker.gates_seq += 1
        emit(
            session,
            OUTBOX,
            f"worker/{worker_id}",
            WorkerGatesSet(worker_id=worker_id, gates=hand_set, seq=worker.gates_seq),
        )
    worker.updated_at = datetime.now(UTC)
    session.flush()
    return worker


def set_consent(session: Session, worker_id: uuid.UUID, withdrawn: bool, at: datetime) -> None:
    """Consent withdrawn stops new claims; given again lifts that. Applied in event time: an event older than the
    newest one applied changes nothing. A worker market has not met yet gets an `unknown` profile holding it."""
    worker = _profile_for_update(session, worker_id, UNKNOWN)
    if worker.consent_at is not None and at <= worker.consent_at:
        log.info("older consent event ignored worker_id=%s", worker_id)
        return
    worker.consent_at = at
    worker.consent_withdrawn_at = at if withdrawn else None
    worker.updated_at = datetime.now(UTC)
    session.flush()


def mark_eligible(session: Session, worker_id: uuid.UUID) -> WorkerProfile:
    """Onboarding is complete. Only `unknown` (or no row) becomes `eligible`: an active, suspended or offboarded
    worker is never moved by a replayed or late event."""
    worker = _profile_for_update(session, worker_id, "eligible")
    if worker.status == UNKNOWN:
        worker.status = "eligible"
        worker.updated_at = datetime.now(UTC)
        session.flush()
    return worker


def patch_batch(session: Session, batch_id: uuid.UUID, changes: dict[str, Any]) -> WorkBatch:
    """The title and the delivery date; neither touches a unit, so any status but cancelled may change them."""
    batch = get_batch(session, batch_id, lock=True)
    if batch.status == "cancelled":
        raise Conflict("a cancelled batch cannot change", batch_id=str(batch_id), status=batch.status)
    for key, value in changes.items():
        setattr(batch, key, value)
    session.flush()
    return batch


# ---------- names and holds, from other modules' events ----------


def names_of(session: Session, ids: Iterable[uuid.UUID | None]) -> dict[uuid.UUID, str | None]:
    """Display names for a page of ids, in one query; an id nobody has seen is absent."""
    return {i: p.name for i, p in _names_of(session, PERSON, ids).items()}


def people(session: Session, ids: list[uuid.UUID], scope: Scope, caller: uuid.UUID | None) -> dict[uuid.UUID, Person]:
    """`GET /v1/people`: every id for staff (`scope` None); for a client only the members of their own orgs (and
    themselves), so a client never learns who works on their data."""
    wanted = set(ids)
    if scope is not None:
        members = set(session.scalars(select(ClientMember.user_id).where(ClientMember.org_id.in_(scope))))
        if caller is not None:
            members.add(caller)
        wanted &= members
    return _names_of(session, PERSON, wanted)


def set_hold(session: Session, worker_id: uuid.UUID, reason: str | None, until: datetime | None, at: datetime) -> None:
    values = {"reason": reason, "until": until, "updated_at": at}
    session.execute(
        pg_insert(WorkerHold)
        .values(worker_id=worker_id, **values)
        .on_conflict_do_update(index_elements=["worker_id"], set_=values)
    )


def holds_of(session: Session, ids: Iterable[uuid.UUID], now: datetime) -> dict[uuid.UUID, datetime]:
    """Workers held right now, with the hold's end."""
    wanted = list(ids)
    if not wanted:
        return {}
    rows = session.scalars(select(WorkerHold).where(WorkerHold.worker_id.in_(wanted), WorkerHold.until > now))
    return {h.worker_id: h.until for h in rows if h.until is not None}


def workers_summary(session: Session, now: datetime | None = None) -> dict[str, int]:
    now = now or datetime.now(UTC)
    counts: dict[str, int] = dict.fromkeys((UNKNOWN, "eligible", "active", "suspended", "offboarded"), 0)
    for status, n in session.execute(select(WorkerProfile.status, func.count()).group_by(WorkerProfile.status)):
        counts[str(status)] = int(n)
    paused = session.scalar(
        select(func.count()).select_from(WorkerAvailability).where(WorkerAvailability.paused_until > now)
    )
    held = session.scalar(select(func.count()).select_from(WorkerHold).where(WorkerHold.until > now))
    return {**counts, "total": sum(counts.values()), "paused": int(paused or 0), "held": int(held or 0)}


# ---------- the client's next delivery ----------


def next_delivery(session: Session, scope: Scope) -> tuple[WorkBatch, ClientProject, UnitCounts] | None:
    """The open batch (not completed, not cancelled) with the earliest delivery date across the caller's projects."""
    stmt = (
        select(WorkBatch, ClientProject)
        .join(ClientProject, ClientProject.id == WorkBatch.project_id)
        .where(WorkBatch.due_at.is_not(None), WorkBatch.status.not_in(("completed", "cancelled")))
        .order_by(WorkBatch.due_at, WorkBatch.id)
        .limit(1)
    )
    if scope is not None:
        stmt = stmt.where(ClientProject.client_org_id.in_(scope))
    row = session.execute(stmt).first()
    if row is None:
        return None
    batch, project = row
    return batch, project, unit_counts_by_batch(session, [batch.id])[batch.id]


# ---------- stored media and the deliverable ----------


def payload_uploads(
    session: Session, store: Storage, batch_id: uuid.UUID, files: list[tuple[str, str, int]]
) -> list[dict[str, Any]]:
    """Presigned PUTs for a draft batch's media, one per `(name, content_type, size_bytes)`, each signed for exactly
    that size (the store refuses another). The returned `ref` goes into the import line's payload; the import checks
    it stays under the project."""
    batch = get_batch(session, batch_id)
    if batch.status != "draft":
        raise Conflict("media can only be uploaded to a draft batch", batch_id=str(batch_id)).with_code(
            "batch_not_draft"
        )
    out = []
    for name, content_type, size in files:
        key = unit_key(batch.project_id, uuid.uuid4(), name)
        p = store.presign_put(key, content_type, size, size_bytes=size)  # a body of any other size is refused
        out.append(
            {
                "name": name,
                "key": key,
                "ref": f"s3://{store.bucket}/{key}",
                "url": p.url,
                "method": p.method,
                "headers": p.headers,
                "expires_at": p.expires_at,
                "max_bytes": size,
            }
        )
    log.info("payload uploads presigned batch_id=%s files=%s", batch_id, len(out))
    return out


def payload_object(
    session: Session, unit_id: uuid.UUID, caller: uuid.UUID, staff: bool, now: datetime | None = None
) -> str:
    """The key of a unit's stored media, for an operator or the worker holding a live claim on it. Anyone else,
    and a unit with no media, is 404 (existence is not leaked)."""
    now = now or datetime.now(UTC)
    unit = session.get(WorkUnit, unit_id)
    if unit is None:
        raise NotFound("unit not found", unit_id=str(unit_id))
    if not staff:
        claim = session.get(Claim, unit.current_claim_id) if unit.current_claim_id else None
        live = claim is not None and claim.worker_id == caller and claim.status == "active" and claim.expires_at > now
        if not live:
            raise NotFound("unit not found", unit_id=str(unit_id))
    if not unit.payload_uri:
        raise NotFound("this unit has no stored media", unit_id=str(unit_id)).with_code("no_payload_object")
    return unit.payload_uri


def _rework_by_unit(session: Session, unit_ids: list[uuid.UUID]) -> dict[uuid.UUID, list[dict[str, Any]]]:
    rework: dict[uuid.UUID, list[dict[str, Any]]] = {u: [] for u in unit_ids}
    rows = session.scalars(
        select(VerdictLog)
        .where(VerdictLog.unit_id.in_(unit_ids), VerdictLog.verdict != "accept")
        .order_by(VerdictLog.at, VerdictLog.id)
    )
    for v in rows:
        rework[v.unit_id].append(
            {"verdict": v.verdict, "reason_code": v.reason_code, "billable": v.billable, "at": v.at.isoformat()}
        )
    return rework


def deliverable_lines(session: Session, manifest: DeliveryManifest) -> list[dict[str, Any]]:
    """One line per delivered unit: what the client receives, with the payload's and the answer's digests."""
    ids = [uuid.UUID(u["unit_id"]) for u in manifest.units]
    units = {u.id: u for u in session.scalars(select(WorkUnit).where(WorkUnit.id.in_(ids)))} if ids else {}
    rework = _rework_by_unit(session, ids)
    lines = []
    for entry in manifest.units:
        unit_id = uuid.UUID(entry["unit_id"])
        unit = units.get(unit_id)
        payload = unit.payload if unit else {}
        lines.append(
            {
                "external_ref": entry["external_ref"],
                "unit_id": entry["unit_id"],
                "payload": payload,
                "payload_ref": unit.payload_uri if unit else None,
                "answer": entry["answer"],
                "rubric_version": entry["rubric_version"],
                "submitted_at": entry["submitted_at"],
                "rework": rework.get(unit_id, []),
                "payload_sha256": _digest(payload),
                "answer_sha256": _digest(entry["answer"]),
            }
        )
    return lines


def _digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def deliverable(session: Session, store: Storage, manifest_id: uuid.UUID) -> DeliveryManifest:
    """Write the batch's `units.jsonl` and `manifest.json` to storage once (the manifest row is locked so two first
    downloads write once), then reuse them. A storage failure records nothing, so the next try writes again.
    A purged batch's answers are gone: its deliverable is never written again (410 `batch_purged`)."""
    manifest = session.scalar(select(DeliveryManifest).where(DeliveryManifest.id == manifest_id).with_for_update())
    if manifest is None:  # pragma: no cover - callers pass a manifest they just read
        raise NotFound("manifest not found", manifest_id=str(manifest_id))
    if manifest.deliverable_key is not None:
        return manifest
    batch = get_batch(session, manifest.batch_id)
    if batch.purged_at is not None:
        raise BatchPurged("this batch's retention ran out; its deliverable is gone", batch_id=str(batch.id))
    lines = deliverable_lines(session, manifest)
    body = "".join(json.dumps(line, sort_keys=True, separators=(",", ":")) + "\n" for line in lines).encode()
    key = deliverable_key(manifest.project_id, manifest.id, "units.jsonl")
    sha = hashlib.sha256(body).hexdigest()
    store.put(key, body, "application/x-ndjson")
    head = {
        "manifest_id": str(manifest.id),
        "batch_id": str(manifest.batch_id),
        "project_id": str(manifest.project_id),
        "currency": manifest.currency,
        "unit_price": str(manifest.unit_price),
        "accepted_units": manifest.accepted_units,
        "total_price": str(manifest.total_price),
        "digest": manifest.digest,
        "created_at": manifest.created_at.isoformat(),
        "lines_sha256": sha,
        "line_count": len(lines),
    }
    store.put(
        deliverable_key(manifest.project_id, manifest.id, "manifest.json"),
        json.dumps(head, sort_keys=True, indent=2).encode(),
        "application/json",
    )
    manifest.deliverable_key = key
    manifest.deliverable_sha256 = sha
    manifest.deliverable_bytes = len(body)
    manifest.deliverable_lines = len(lines)
    manifest.deliverable_at = datetime.now(UTC)
    session.flush()
    log.info("deliverable written manifest_id=%s lines=%s bytes=%s", manifest.id, len(lines), len(body))
    return manifest


# ---------- retention ----------


def purge_due_batches(
    session: Session, store: Storage | None, now: datetime | None = None, limit: int = PURGE_PASS
) -> int:
    """Batches whose project's retention has run out since delivery (or since creation, for a cancelled batch) lose
    their unit payloads, answers, the manifest's unit list and their stored objects. Counts, digests and totals stay,
    so invoices and the verdict log still add up. Quality drops its own copies on `work.batch.purged.v1`.
    Each batch is its own transaction: one that fails (storage refuses, a row is locked) is rolled back, logged by
    id and left for the next run, and the pass goes on, up to `limit` batches. Without storage a batch with objects to
    delete is skipped (and logged), never purged half-way."""
    now = now or datetime.now(UTC)
    due = session.execute(
        select(WorkBatch.id, WorkBatch.created_at, ClientProject.retention_days, DeliveryManifest.created_at)
        .join(ClientProject, ClientProject.id == WorkBatch.project_id)
        .outerjoin(DeliveryManifest, DeliveryManifest.batch_id == WorkBatch.id)
        .where(WorkBatch.purged_at.is_(None), WorkBatch.status.in_(("completed", "cancelled")))
        .order_by(WorkBatch.created_at, WorkBatch.id)
    ).all()
    session.commit()  # the candidate read holds nothing while each batch is purged
    purged = 0
    for batch_id, created_at, retention_days, delivered_at in due:
        if (delivered_at or created_at) + timedelta(days=retention_days) > now:
            continue
        try:
            done = _purge_batch(session, store, batch_id, now)
            session.commit()
        except (DomainError, SQLAlchemyError) as e:
            session.rollback()
            log.error("retention purge failed batch_id=%s error=%s", batch_id, type(e).__name__)
            continue
        purged += done
        if purged >= limit:
            break
    return purged


def _lock_unpurged(session: Session, batch_id: uuid.UUID) -> WorkBatch | None:
    """The batch row, locked, while still unpurged; None when another run holds or already purged it."""
    return session.scalar(
        select(WorkBatch)
        .where(WorkBatch.id == batch_id, WorkBatch.purged_at.is_(None))
        .with_for_update(skip_locked=True)
    )


def _purge_batch(session: Session, store: Storage | None, batch_id: uuid.UUID, now: datetime) -> int:
    """Purge one due batch; 1 when purged, 0 when skipped. A media key another batch's unit still names stays in
    storage: imports may point two batches of a project at the same object."""
    batch = _lock_unpurged(session, batch_id)
    if batch is None:
        return 0
    manifest = session.scalar(select(DeliveryManifest).where(DeliveryManifest.batch_id == batch.id))
    media = {k for k in session.scalars(select(WorkUnit.payload_uri).where(WorkUnit.batch_id == batch.id)) if k}
    shared = set(
        session.scalars(
            select(WorkUnit.payload_uri).where(WorkUnit.payload_uri.in_(media), WorkUnit.batch_id != batch.id)
        )
    )
    keys = sorted(media - shared)
    if manifest is not None and manifest.deliverable_key:
        keys += [manifest.deliverable_key, deliverable_key(batch.project_id, manifest.id, "manifest.json")]
    if keys and store is None:
        log.warning("retention skipped: storage not configured batch_id=%s objects=%s", batch.id, len(keys))
        return 0
    if keys and store is not None:
        store.delete(keys)
    unit_count = session.execute(
        update(WorkUnit).where(WorkUnit.batch_id == batch.id).values(payload={}, payload_uri=None)
    ).rowcount
    session.execute(
        update(Submission)
        .where(Submission.unit_id.in_(select(WorkUnit.id).where(WorkUnit.batch_id == batch.id)))
        .values(answer={})
    )
    if manifest is not None:
        manifest.units = []
        manifest.deliverable_key = None
    batch.purged_at = now
    emit(
        session,
        OUTBOX,
        f"batch/{batch.id}",
        WorkBatchPurged(batch_id=batch.id, project_id=batch.project_id, unit_count=unit_count),
    )
    log.info(
        "batch purged batch_id=%s units=%s objects=%s shared_kept=%s", batch.id, unit_count, len(keys), len(shared)
    )
    return 1


# ---------- assigned units nobody is working on ----------


def unassign_unit(
    session: Session, unit_id: uuid.UUID, by: uuid.UUID, assign_to: uuid.UUID | None = None, now: datetime | None = None
) -> WorkUnit:
    """Ops take an available unit off the worker it waits for (a rework author who left or is held): back to the
    pool, or to `assign_to`. A unit of an assigned-mode batch has no pool, so it needs `assign_to` (409
    `assignment_required`). Signed: `unassigned_by`, `unassigned_at`. Anything but an available assigned unit is 409
    `unit_not_assigned`."""
    now = now or datetime.now(UTC)
    unit = session.scalar(select(WorkUnit).where(WorkUnit.id == unit_id).with_for_update())
    if unit is None:
        raise NotFound("unit not found", unit_id=str(unit_id))
    if unit.status != "available" or unit.assigned_worker_id is None:
        raise Conflict(
            "only an available unit assigned to a worker can be unassigned", unit_id=str(unit_id), status=unit.status
        ).with_code("unit_not_assigned")
    if assign_to is None and get_batch(session, unit.batch_id).mode == "assigned":
        raise Conflict("an assigned batch has no pool: name the worker to hand it to", unit_id=str(unit_id)).with_code(
            "assignment_required"
        )
    previous = unit.assigned_worker_id
    unit.assigned_worker_id = assign_to
    unit.assigned_at = now if assign_to else None
    unit.unassigned_by, unit.unassigned_at = by, now
    session.flush()
    log.info("unit unassigned unit_id=%s from=%s to=%s by=%s", unit.id, previous, assign_to, by)
    return unit


def _waiting_assigned(now: datetime, days: int) -> Any:
    return and_(
        WorkUnit.status == "available",
        WorkUnit.assigned_worker_id.is_not(None),
        WorkUnit.assigned_at < now - timedelta(days=days),
        WorkBatch.status.in_(("published", "paused")),
    )


def stuck_assigned_units(
    session: Session, days: int = STUCK_ASSIGNED_DAYS, now: datetime | None = None, limit: int = PAGE
) -> list[tuple[WorkUnit, WorkBatch, ClientProject]]:
    """Available units waiting more than `days` for the one worker they are assigned to, longest first."""
    now = now or datetime.now(UTC)
    rows = session.execute(
        select(WorkUnit, WorkBatch, ClientProject)
        .join(WorkBatch, WorkBatch.id == WorkUnit.batch_id)
        .join(ClientProject, ClientProject.id == WorkBatch.project_id)
        .where(_waiting_assigned(now, days))
        .order_by(WorkUnit.assigned_at, WorkUnit.id)
        .limit(limit)
    ).all()
    return [(u, b, p) for u, b, p in rows]


# ---------- what needs an operator ----------


def attention(session: Session, now: datetime | None = None) -> dict[str, int]:
    """Market's share of the ops attention list: claims past their time, live batches under their floor and
    assigned units waiting more than STUCK_ASSIGNED_DAYS for their worker."""
    now = now or datetime.now(UTC)
    expired = session.scalar(
        select(func.count()).select_from(Claim).where(Claim.status == "active", Claim.expires_at < now)
    )
    under = 0
    for batch, floor in session.execute(
        select(WorkBatch, ClientProject.margin_floor)
        .join(ClientProject, ClientProject.id == WorkBatch.project_id)
        .where(WorkBatch.status.in_(("draft", "published", "paused")), ClientProject.margin_floor.is_not(None))
    ):
        if margin(batch.unit_price, batch.unit_pay, batch.review_pay) < floor:
            under += 1
    stuck = session.scalar(
        select(func.count())
        .select_from(WorkUnit)
        .join(WorkBatch, WorkBatch.id == WorkUnit.batch_id)
        .where(_waiting_assigned(now, STUCK_ASSIGNED_DAYS))
    )
    return {"expired_claims": int(expired or 0), "batches_under_floor": under, "stuck_assigned_units": int(stuck or 0)}
