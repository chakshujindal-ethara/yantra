"""HTTP surface of the market module. The gateway authenticates; this layer trusts two headers from it:
`X-Worker-Id` (the caller's subject) and `X-Role` (the caller's realm roles). Every handler is one unit of work.
Three audiences: workers (pay, never price), operators (everything), clients (price and invoice totals, never
pay; only their own orgs, and a project outside them is 404 so nothing leaks)."""

import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Header, Query, status

from yantra_common.deps import DB, AdminOrOps, ClientRole, MaybeStorage, Ops, Roles, StorageDep, Worker, WorkerId
from yantra_common.errors import Forbidden, Invalid, NotFound
from yantra_market import service
from yantra_market.models import (
    UNIT_STATUSES,
    UNKNOWN,
    Claim,
    ClientOrg,
    ClientProject,
    DeliveryManifest,
    WorkBatch,
    WorkerAvailability,
    WorkerProfile,
    WorkUnit,
)
from yantra_market.rules import MAX_JSON_BYTES, MAX_SCHEMA_BYTES, check_schema, depth, json_size
from yantra_market.schemas import (
    ActiveClaimOut,
    AvailabilityIn,
    AvailabilityOut,
    BatchBriefOut,
    BatchIn,
    BatchOut,
    BatchPatch,
    BatchSummary,
    ClaimOut,
    ClientBatchOut,
    ClientManifestOut,
    ClientOrgIn,
    ClientOrgOut,
    ClientOverviewOut,
    ClientProjectDetailOut,
    ClientProjectOut,
    DeliverableFile,
    DeliverableOut,
    ExpiredClaimRow,
    FeedbackIn,
    FeedbackOut,
    ImportIn,
    ImportOut,
    ManifestBrief,
    ManifestOut,
    MembershipOut,
    NextDelivery,
    OpenBatchOut,
    OrgBrief,
    PayloadUploadsIn,
    PayloadUploadsOut,
    PersonOut,
    ProjectDetail,
    ProjectIn,
    ProjectOut,
    ProjectPatch,
    ProjectSummary,
    PublishIn,
    ReleasedClaimRow,
    ReleasedOut,
    RubricLogEntry,
    StuckAssignedRow,
    SubmissionIn,
    SubmissionOut,
    UnassignedOut,
    UnassignIn,
    UnitCounts,
    UnitOut,
    UnitPage,
    UnitRow,
    UploadOut,
    UrlOut,
    WorkerIn,
    WorkerMeOut,
    WorkerOut,
    WorkerPage,
    WorkerRow,
    WorkersSummaryOut,
)

# the caller when the gateway sent one; a release signed by nobody reads as the expiry job
Caller = Annotated[uuid.UUID | None, Header(alias="X-Worker-Id")]

router = APIRouter(prefix="/v1", tags=["market"])


IdempotencyKey = Annotated[str, Header(alias="Idempotency-Key", min_length=8, max_length=200)]
Limit = Annotated[int, Query(ge=1, le=200)]
Offset = Annotated[int, Query(ge=0)]


def check_project_schema(name: str, schema: dict[str, Any] | None) -> None:
    """A schema is capped at 64 KB before it is checked: the size test is cheap, the schema walk is not."""
    if schema is None:
        return
    if json_size(schema) > MAX_SCHEMA_BYTES:
        raise Invalid(f"{name}: over 64 KB")
    problem = check_schema(schema)
    if problem:
        raise Invalid(f"{name}: {problem}")


@router.post("/projects", response_model=ProjectOut, status_code=status.HTTP_201_CREATED, dependencies=[Ops])
def create_project(body: ProjectIn, session: DB) -> ClientProject:
    check_project_schema("payload_schema", body.payload_schema)
    check_project_schema("answer_schema", body.answer_schema)
    project = ClientProject(**body.model_dump(), status="active")
    session.add(project)
    session.flush()
    return project


@router.post(
    "/projects/{project_id}/batches", response_model=BatchOut, status_code=status.HTTP_201_CREATED, dependencies=[Ops]
)
def create_batch(project_id: uuid.UUID, body: BatchIn, session: DB) -> WorkBatch:
    project = service.get_project(session, project_id)
    batch = WorkBatch(
        project_id=project.id, currency=project.currency, rubric_version=project.rubric_version, **body.model_dump()
    )
    session.add(batch)
    session.flush()
    return batch


@router.post("/batches/{batch_id}/units/import", response_model=ImportOut, dependencies=[Ops])
def import_units(
    batch_id: uuid.UUID, body: ImportIn, session: DB, store: MaybeStorage, dry_run: bool = Query(default=True)
) -> ImportOut:
    """A payload string naming stored media (`s3://<bucket>/projects/<project>/...`) must stay in the project."""
    report = service.import_units(
        session, batch_id, body.lines, dry_run=dry_run, bucket=store.bucket if store is not None else None
    )
    return ImportOut(**report.model_dump(), dry_run=dry_run)


@router.post("/batches/{batch_id}/publish", response_model=BatchOut, dependencies=[Ops])
def publish(batch_id: uuid.UUID, body: PublishIn, session: DB) -> WorkBatch:
    return service.publish_batch(session, batch_id, approved_by=body.approved_by, approval_note=body.approval_note)


@router.get("/batches", response_model=list[OpenBatchOut], dependencies=[Worker])
def open_batches(worker_id: WorkerId, session: DB) -> list[OpenBatchOut]:
    """What a worker can claim right now. Never carries the client's price."""
    rows = service.open_batches(session, worker_id)
    projects = service.projects_of(session, [b for b, _ in rows])
    return [
        OpenBatchOut(
            **BatchOut.model_validate(b).model_dump(),
            available_units=n,
            project_name=projects[b.project_id].name,
            answer_schema=projects[b.project_id].answer_schema,
        )
        for b, n in rows
    ]


def batch_brief(session: DB, batch_id: uuid.UUID) -> BatchBriefOut:
    batch = service.get_batch(session, batch_id)
    project = service.get_project(session, batch.project_id)
    return BatchBriefOut(
        **BatchOut.model_validate(batch).model_dump(exclude={"unit_price"}),
        project_name=project.name,
        answer_schema=project.answer_schema,
    )


@router.get("/batches/{batch_id}/manifest", response_model=ManifestOut, dependencies=[Ops])
def manifest(batch_id: uuid.UUID, session: DB) -> ManifestOut:
    """The delivery gate: 409 `batch_held` with the counts until every unit is accepted; then the manifest."""
    return ManifestOut.model_validate(service.build_manifest(session, batch_id))


@router.get("/claims/active", response_model=ActiveClaimOut, dependencies=[Worker])
def active_claim(worker_id: WorkerId, session: DB) -> ActiveClaimOut:
    found = service.active_claim(session, worker_id)
    if found is None:
        return ActiveClaimOut(claim=None, unit=None, batch=None)
    claim, unit = found
    return ActiveClaimOut(
        claim=ClaimOut.model_validate(claim),
        unit=UnitOut.model_validate(unit),
        batch=batch_brief(session, unit.batch_id),
    )


@router.post(
    "/batches/{batch_id}/claims", response_model=ClaimOut, status_code=status.HTTP_201_CREATED, dependencies=[Worker]
)
def claim(batch_id: uuid.UUID, worker_id: WorkerId, idempotency_key: IdempotencyKey, session: DB) -> ClaimOut:
    return ClaimOut.model_validate(service.claim_unit(session, batch_id, worker_id, idempotency_key))


@router.post(
    "/claims/{claim_id}/submission",
    response_model=SubmissionOut,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Worker],
)
def submit(claim_id: uuid.UUID, body: SubmissionIn, worker_id: WorkerId, session: DB) -> SubmissionOut:
    if depth(body.answer) > 32:
        raise Invalid("answer: nests deeper than 32 levels")
    if json_size(body.answer) > MAX_JSON_BYTES:
        raise Invalid("answer: over 256 KB")
    return SubmissionOut.model_validate(service.submit(session, claim_id, worker_id, body.answer))


@router.post("/claims/{claim_id}/release", response_model=ClaimOut, dependencies=[Worker])
def release_claim(claim_id: uuid.UUID, worker_id: WorkerId, session: DB) -> ClaimOut:
    """The worker gives the claim back: the unit is available again (an assignment stays with them)."""
    return ClaimOut.model_validate(service.release_claim(session, claim_id, worker_id))


# ---------- stuck work: claims past their time ----------


@router.post("/claims/release-expired", response_model=ReleasedOut, dependencies=[AdminOrOps])
def release_expired(session: DB, worker_id: Caller = None) -> ReleasedOut:
    """Release every claim past its time now (the expiry job does the same every 30 s), signed by the caller."""
    released, more = service.release_expired_claims(session, released_by=worker_id)
    return ReleasedOut(released=len(released), more=more)


@router.get("/claims/expired", response_model=list[ExpiredClaimRow], dependencies=[AdminOrOps])
def expired_claims(session: DB) -> list[ExpiredClaimRow]:
    """Live claims past their time, oldest first (200 at most)."""
    now = datetime.now(UTC)
    rows = service.expired_claims(session, now)
    names = service.names_of(session, [c.worker_id for c, _, _, _ in rows])
    return [
        ExpiredClaimRow(
            claim_id=c.id,
            unit_id=u.id,
            external_ref=u.external_ref,
            batch_id=b.id,
            batch_title=b.title,
            project_id=p.id,
            project_name=p.name,
            worker_id=c.worker_id,
            worker_name=names.get(c.worker_id),
            expires_at=c.expires_at,
            minutes_overdue=int((now - c.expires_at).total_seconds() // 60),
        )
        for c, u, b, p in rows
    ]


@router.post("/claims/{claim_id}/release-expired", response_model=ClaimOut, dependencies=[AdminOrOps])
def release_expired_claim(claim_id: uuid.UUID, worker_id: WorkerId, session: DB) -> ClaimOut:
    """One stuck claim back to the pool, signed by the caller. 409 `claim_not_expired` unless live and past time."""
    return ClaimOut.model_validate(service.release_expired_claim(session, claim_id, worker_id))


@router.get("/claims/released", response_model=list[ReleasedClaimRow], dependencies=[AdminOrOps])
def released_claims(session: DB, days: Annotated[int, Query(ge=1, le=90)] = 7) -> list[ReleasedClaimRow]:
    """Claims that ended without a submission in the last `days`, newest first: `released_by` null is the job."""
    rows = service.released_claims(session, datetime.now(UTC) - timedelta(days=days))
    names = service.names_of(session, [i for c, _ in rows for i in (c.worker_id, c.released_by)])
    return [
        ReleasedClaimRow(
            claim_id=c.id,
            unit_id=u.id,
            batch_id=u.batch_id,
            worker_id=c.worker_id,
            worker_name=names.get(c.worker_id),
            status=c.status,
            expires_at=c.expires_at,
            released_at=c.released_at or c.expires_at,
            released_by=c.released_by,
            released_by_name=names.get(c.released_by) if c.released_by else None,
        )
        for c, u in rows
    ]


@router.post("/units/{unit_id}/unassign", response_model=UnassignedOut, dependencies=[AdminOrOps])
def unassign_unit(unit_id: uuid.UUID, worker_id: WorkerId, session: DB, body: UnassignIn | None = None) -> WorkUnit:
    """Take an available unit off the worker it waits for: back to the pool, or to `assign_to`. Signed by the caller.
    409 `unit_not_assigned`, 409 `assignment_required` (an assigned batch has no pool)."""
    return service.unassign_unit(session, unit_id, worker_id, body.assign_to if body else None)


@router.get("/units/stuck-assigned", response_model=list[StuckAssignedRow], dependencies=[AdminOrOps])
def stuck_assigned(
    session: DB, days: Annotated[int, Query(ge=0, le=90)] = service.STUCK_ASSIGNED_DAYS
) -> list[StuckAssignedRow]:
    """Available units waiting more than `days` for their one assigned worker, longest first (200 at most)."""
    now = datetime.now(UTC)
    rows = service.stuck_assigned_units(session, days, now)
    names = service.names_of(session, [u.assigned_worker_id for u, _, _ in rows])
    out = []
    for u, b, p in rows:
        assert u.assigned_worker_id is not None and u.assigned_at is not None  # the query's condition
        out.append(
            StuckAssignedRow(
                unit_id=u.id,
                external_ref=u.external_ref,
                batch_id=b.id,
                batch_title=b.title,
                project_id=p.id,
                project_name=p.name,
                worker_id=u.assigned_worker_id,
                worker_name=names.get(u.assigned_worker_id),
                assigned_at=u.assigned_at,
                days_waiting=(now - u.assigned_at).days,
            )
        )
    return out


# ---------- stored media ----------


@router.post("/batches/{batch_id}/payload-uploads", response_model=PayloadUploadsOut, dependencies=[Ops])
def payload_uploads(batch_id: uuid.UUID, body: PayloadUploadsIn, session: DB, store: StorageDep) -> PayloadUploadsOut:
    """Presigned PUTs for a draft batch's media; each `ref` goes into an import line's payload."""
    files = [(f.name, f.content_type, f.size_bytes) for f in body.files]
    return PayloadUploadsOut(uploads=[UploadOut(**u) for u in service.payload_uploads(session, store, batch_id, files)])


@router.get("/units/{unit_id}/payload-url", response_model=UrlOut, dependencies=[Worker])
def payload_url(unit_id: uuid.UUID, worker_id: WorkerId, roles: Roles, session: DB, store: StorageDep) -> UrlOut:
    """A five-minute link to the unit's media: for an operator, or the worker holding a live claim on it."""
    key = service.payload_object(session, unit_id, worker_id, staff="ops" in roles)
    p = store.presign_get(key)
    return UrlOut(url=p.url, expires_at=p.expires_at)


def deliverable_out(session: DB, store: StorageDep, manifest: DeliveryManifest) -> DeliverableOut:
    m = service.deliverable(session, store, manifest.id)
    assert m.deliverable_key is not None and m.deliverable_sha256 is not None  # set by service.deliverable
    jsonl = store.presign_get(m.deliverable_key)
    head = store.presign_get(m.deliverable_key.rsplit("/", 1)[0] + "/manifest.json")
    return DeliverableOut(
        manifest_id=m.id,
        batch_id=m.batch_id,
        digest=m.digest,
        jsonl=DeliverableFile(
            url=jsonl.url,
            expires_at=jsonl.expires_at,
            sha256=m.deliverable_sha256,
            bytes=m.deliverable_bytes or 0,
            line_count=m.deliverable_lines or 0,
        ),
        manifest=UrlOut(url=head.url, expires_at=head.expires_at),
    )


@router.get("/batches/{batch_id}/deliverable", response_model=DeliverableOut, dependencies=[Ops])
def deliverable(batch_id: uuid.UUID, session: DB, store: StorageDep) -> DeliverableOut:
    """The delivery as files (JSONL + manifest), behind the same gate as the manifest: 409 `batch_held` first."""
    return deliverable_out(session, store, service.build_manifest(session, batch_id))


@router.get("/units/{unit_id}", response_model=UnitOut, dependencies=[Worker])
def get_unit(unit_id: uuid.UUID, worker_id: WorkerId, session: DB) -> WorkUnit:
    """A worker sees a unit only while holding its claim or having submitted it."""
    unit = session.get(WorkUnit, unit_id)
    if unit is None or unit.current_claim_id is None:
        raise NotFound("unit not found", unit_id=str(unit_id))
    claim = session.get(Claim, unit.current_claim_id)
    if claim is None or claim.worker_id != worker_id:
        raise NotFound("unit not found", unit_id=str(unit_id))
    return unit


@router.get("/people", response_model=dict[str, PersonOut])
def people(
    session: DB,
    roles: Roles,
    ids: Annotated[str, Query(min_length=1, max_length=7600)],
    worker_id: Annotated[uuid.UUID | None, Header(alias="X-Worker-Id")] = None,
) -> dict[str, PersonOut]:
    """Display names for up to 200 ids: every id for staff, only fellow members of their orgs for a client.
    Unknown ids are left out."""
    try:
        wanted = [uuid.UUID(p.strip()) for p in ids.split(",") if p.strip()]
    except ValueError as e:
        raise Invalid("ids must be a comma-separated list of UUIDs") from e
    if len(wanted) > 200:
        raise Invalid("at most 200 ids", given=len(wanted))
    if not roles & {"ops", "finance", "admin"}:
        if "client" not in roles or worker_id is None:
            raise Forbidden("staff or client role required")
        scope: service.Scope = service.orgs_of_user(session, worker_id)
    else:
        scope = None
    found = service.people(session, wanted, scope, worker_id)
    return {str(i): PersonOut(name=p.name, kind=p.kind) for i, p in found.items()}


@router.get("/workers/me", response_model=WorkerMeOut, dependencies=[Worker])
def me(worker_id: WorkerId, session: DB) -> WorkerMeOut:
    """The caller's own profile and availability. Never 404: a worker Odoo has not pushed yet is `unknown`."""
    worker = session.get(WorkerProfile, worker_id)
    availability = session.get(WorkerAvailability, worker_id)
    return WorkerMeOut(
        id=worker_id,
        status=worker.status if worker else "unknown",
        cert_gates=list(worker.cert_gates) if worker else [],
        partner_ref=worker.partner_ref if worker else None,
        updated_at=worker.updated_at if worker else None,
        availability=AvailabilityOut.model_validate(availability) if availability else None,
    )


@router.put("/workers/me/availability", response_model=AvailabilityOut, dependencies=[Worker])
def set_availability(body: AvailabilityIn, worker_id: WorkerId, session: DB) -> WorkerAvailability:
    """The weekly check-in; a pause in the future hides every pool and refuses claims until it lapses."""
    return service.upsert_availability(session, worker_id, body.weekly_hours, body.paused_until)


@router.put("/workers/{worker_id}", response_model=WorkerOut, dependencies=[Ops])
def upsert_worker(worker_id: uuid.UUID, body: WorkerIn, session: DB, caller: Caller = None) -> WorkerProfile:
    """Odoo's or an operator's view of the worker: status and partner as sent; `cert_gates` replaces the hand-set
    gates and keeps the ones events granted (`assess.certified`, `talent.offer.accepted`), so a push never wipes a
    certification. Never one's own record (403 `self_action`)."""
    worker = service.set_worker_by_hand(session, worker_id, body.status, body.partner_ref, body.cert_gates, caller)
    session.refresh(worker)
    return worker


# ---------- ops: projects, batches, units, workers ----------


def project_summary(session: DB, project: ClientProject) -> ProjectSummary:
    return _summaries(session, [project])[0]


def _summaries(session: DB, projects: list[ClientProject]) -> list[ProjectSummary]:
    ids = [p.id for p in projects]
    counts = service.unit_counts_by_project(session, ids)
    batches = service.batch_count_by_project(session, ids)
    return [
        ProjectSummary(
            id=p.id,
            name=p.name,
            currency=p.currency,
            status=p.status,
            cert_gate=p.cert_gate,
            rubric_version=p.rubric_version,
            margin_floor=p.margin_floor,
            client_org_id=p.client_org_id,
            batch_count=batches[p.id],
            units=counts[p.id],
            created_at=p.created_at,
            retention_days=p.retention_days,
            closed_at=p.closed_at,
        )
        for p in projects
    ]


def batch_summaries(session: DB, batches: list[WorkBatch]) -> list[BatchSummary]:
    ids = [b.id for b in batches]
    counts = service.unit_counts_by_batch(session, ids)
    live = service.live_claims_by_batch(session, ids)
    manifests = service.manifests_by_batch(session, ids)
    projects = service.projects_of(session, batches)
    return [
        BatchSummary(
            **BatchOut.model_validate(b).model_dump(),
            project_name=projects[b.project_id].name,
            units=counts[b.id],
            live_claims=live[b.id],
            manifest=ManifestBrief.model_validate(manifests[b.id]) if b.id in manifests else None,
        )
        for b in batches
    ]


def project_detail(session: DB, project: ClientProject) -> ProjectDetail:
    return ProjectDetail(
        **project_summary(session, project).model_dump(),
        payload_schema=project.payload_schema,
        answer_schema=project.answer_schema,
        brief=project.brief,
        llm_policy=project.llm_policy,
        sensitive=project.sensitive,
        rubric_log=[RubricLogEntry.model_validate(e) for e in project.rubric_log],
        batches=batch_summaries(session, service.batches_of(session, project.id)),
        reasons=service.reasons_for(session, [project.id]),
        feedback=feedback_out(session, project.id),
    )


def feedback_out(session: DB, project_id: uuid.UUID) -> list[FeedbackOut]:
    rows = service.feedback_of(session, project_id)
    names = service.names_of(session, [f.author_id for f in rows])
    return [FeedbackOut.model_validate(f).model_copy(update={"author_name": names.get(f.author_id)}) for f in rows]


@router.get("/projects", response_model=list[ProjectSummary], dependencies=[Ops])
def list_projects(session: DB) -> list[ProjectSummary]:
    return _summaries(session, service.list_projects(session))


@router.get("/projects/{project_id}", response_model=ProjectDetail, dependencies=[Ops])
def get_project(project_id: uuid.UUID, session: DB) -> ProjectDetail:
    return project_detail(session, service.get_project(session, project_id))


@router.patch("/projects/{project_id}", response_model=ProjectDetail, dependencies=[Ops])
def patch_project(project_id: uuid.UUID, body: ProjectPatch, session: DB) -> ProjectDetail:
    """Only the fields sent change. An answer schema is checked exactly as on creation."""
    changes = body.model_dump(exclude_unset=True)
    if "answer_schema" in changes:
        check_project_schema("answer_schema", changes["answer_schema"])
    return project_detail(session, service.patch_project(session, project_id, changes))


@router.post(
    "/projects/{project_id}/feedback",
    response_model=FeedbackOut,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Ops],
)
def ops_feedback(project_id: uuid.UUID, body: FeedbackIn, worker_id: WorkerId, session: DB) -> FeedbackOut:
    """An operator's answer on the client's thread (`author_kind` staff)."""
    project = service.get_project(session, project_id)
    row = service.add_feedback(session, project, worker_id, body.body, author_kind="staff")
    return FeedbackOut.model_validate(row).model_copy(
        update={"author_name": service.names_of(session, [worker_id]).get(worker_id)}
    )


@router.patch("/batches/{batch_id}", response_model=BatchSummary, dependencies=[Ops])
def patch_batch(batch_id: uuid.UUID, body: BatchPatch, session: DB) -> BatchSummary:
    """The title and the delivery date (`due_at` null clears it)."""
    return batch_summaries(session, [service.patch_batch(session, batch_id, body.model_dump(exclude_unset=True))])[0]


@router.get("/batches/{batch_id}", response_model=BatchSummary, dependencies=[Ops])
def get_batch(batch_id: uuid.UUID, session: DB) -> BatchSummary:
    return batch_summaries(session, [service.get_batch(session, batch_id)])[0]


@router.get("/batches/{batch_id}/units", response_model=UnitPage, dependencies=[Ops])
def list_units(
    batch_id: uuid.UUID, session: DB, status: str | None = None, limit: Limit = 50, offset: Offset = 0
) -> UnitPage:
    if status is not None and status not in UNIT_STATUSES:
        raise Invalid(f"status: not one of {', '.join(UNIT_STATUSES)}")
    total, items = service.list_units(session, batch_id, status, limit, offset)
    return UnitPage(total=total, items=[UnitRow.model_validate(u) for u in items])


@router.post("/batches/{batch_id}/pause", response_model=BatchSummary, dependencies=[Ops])
def pause_batch(batch_id: uuid.UUID, session: DB) -> BatchSummary:
    return batch_summaries(session, [service.pause_batch(session, batch_id)])[0]


@router.post("/batches/{batch_id}/resume", response_model=BatchSummary, dependencies=[Ops])
def resume_batch(batch_id: uuid.UUID, session: DB) -> BatchSummary:
    return batch_summaries(session, [service.resume_batch(session, batch_id)])[0]


@router.post("/batches/{batch_id}/cancel", response_model=BatchSummary, dependencies=[Ops])
def cancel_batch(batch_id: uuid.UUID, session: DB) -> BatchSummary:
    """409 `batch_has_live_claims` while any claim is still inside its TTL."""
    return batch_summaries(session, [service.cancel_batch(session, batch_id)])[0]


def worker_rows(session: DB, rows: list[tuple[WorkerProfile, WorkerAvailability | None]]) -> list[WorkerRow]:
    """The bench rows with their names and holds, two queries for the page."""
    ids = [w.id for w, _ in rows]
    names = service.names_of(session, ids)
    holds = service.holds_of(session, ids, datetime.now(UTC))
    return [
        WorkerRow(
            id=w.id,
            status=w.status,
            cert_gates=list(w.cert_gates),
            partner_ref=w.partner_ref,
            availability=AvailabilityOut.model_validate(a) if a else None,
            updated_at=w.updated_at,
            name=names.get(w.id),
            onboarded=w.status != UNKNOWN,
            held=w.id in holds,
            hold_until=holds.get(w.id),
        )
        for w, a in rows
    ]


@router.get("/workers", response_model=WorkerPage, dependencies=[Ops])
def list_workers(
    session: DB,
    status: str | None = None,
    gate: Annotated[str | None, Query(max_length=80)] = None,
    q: Annotated[str | None, Query(max_length=36, pattern=r"^[0-9a-fA-F-]+$")] = None,
    limit: Limit = 50,
    offset: Offset = 0,
) -> WorkerPage:
    """The bench: filter by status, by a held gate, by the start of the id. Joined with availability."""
    total, rows = service.list_workers(session, status, gate, q, limit, offset)
    return WorkerPage(total=total, items=worker_rows(session, rows))


@router.get("/workers/summary", response_model=WorkersSummaryOut, dependencies=[Ops])
def workers_summary(session: DB) -> WorkersSummaryOut:
    return WorkersSummaryOut(**service.workers_summary(session))


@router.get("/workers/{worker_id}", response_model=WorkerRow, dependencies=[Ops])
def get_worker(worker_id: uuid.UUID, session: DB) -> WorkerRow:
    return worker_rows(session, [service.get_worker(session, worker_id)])[0]


# ---------- client orgs ----------


def org_out(org: ClientOrg, members: list[uuid.UUID]) -> ClientOrgOut:
    return ClientOrgOut(id=org.id, name=org.name, created_at=org.created_at, members=members)


@router.post("/client-orgs", response_model=ClientOrgOut, status_code=status.HTTP_201_CREATED, dependencies=[Ops])
def create_org(body: ClientOrgIn, session: DB) -> ClientOrgOut:
    return org_out(service.create_org(session, body.name), [])


@router.get("/client-orgs", response_model=list[ClientOrgOut], dependencies=[Ops])
def list_orgs(session: DB) -> list[ClientOrgOut]:
    return [org_out(o, m) for o, m in service.list_orgs(session)]


@router.put("/client-orgs/{org_id}/members/{user_id}", response_model=MembershipOut, dependencies=[Ops])
def add_member(org_id: uuid.UUID, user_id: uuid.UUID, session: DB) -> MembershipOut:
    service.add_member(session, org_id, user_id)
    return MembershipOut(org_id=org_id, user_id=user_id, member=True)


@router.delete("/client-orgs/{org_id}/members/{user_id}", response_model=MembershipOut, dependencies=[Ops])
def remove_member(org_id: uuid.UUID, user_id: uuid.UUID, session: DB) -> MembershipOut:
    service.remove_member(session, org_id, user_id)
    return MembershipOut(org_id=org_id, user_id=user_id, member=False)


# ---------- the client console ----------


def client_scope(
    session: DB, roles: Roles, worker_id: Annotated[uuid.UUID | None, Header(alias="X-Worker-Id")] = None
) -> service.Scope:
    """Which orgs the caller reads: every org for an operator, the orgs they are a member of for a client.
    A client with no subject header has no orgs to read."""
    if "ops" in roles:
        return None
    if worker_id is None:
        raise Forbidden("client identity required")
    return service.orgs_of_user(session, worker_id)


Scope = Annotated[service.Scope, Depends(client_scope)]


def client_project_out(session: DB, project: ClientProject, counts: UnitCounts) -> ClientProjectOut:
    return ClientProjectOut(
        id=project.id,
        name=project.name,
        currency=project.currency,
        status=project.status,
        rubric_version=project.rubric_version,
        units=counts,
        acceptance_rate=service.acceptance_rate(session, [project.id]),
        invoice_total=service.invoice_total(session, project),
    )


def client_batches(session: DB, batches: list[WorkBatch]) -> list[ClientBatchOut]:
    ids = [b.id for b in batches]
    counts = service.unit_counts_by_batch(session, ids)
    manifests = service.manifests_by_batch(session, ids)
    return [
        ClientBatchOut(
            id=b.id,
            title=b.title,
            status=b.status,
            unit_price=b.unit_price,
            units=counts[b.id],
            manifest=ManifestBrief.model_validate(manifests[b.id]) if b.id in manifests else None,
            due_at=b.due_at,
        )
        for b in batches
    ]


def next_delivery_out(session: DB, scope: service.Scope) -> NextDelivery | None:
    found = service.next_delivery(session, scope)
    if found is None:
        return None
    batch, project, counts = found
    assert batch.due_at is not None  # the query only picks dated batches
    return NextDelivery(
        batch_id=batch.id,
        title=batch.title,
        project_id=project.id,
        project_name=project.name,
        due_at=batch.due_at,
        accepted=counts.accepted,
        total=counts.total,
    )


@router.get("/client/overview", response_model=ClientOverviewOut, dependencies=[ClientRole])
def client_overview(session: DB, scope: Scope) -> ClientOverviewOut:
    """The numbers across the caller's orgs. Invoice totals are kept per currency: they never add across one."""
    orgs = [OrgBrief.model_validate(o) for o, _ in service.list_orgs(session, scope)]
    projects = service.list_projects(session, scope)
    ids = [p.id for p in projects]
    totals: dict[str, Any] = {}
    for p in projects:
        totals[p.currency] = totals.get(p.currency, 0) + service.invoice_total(session, p)
    return ClientOverviewOut(
        orgs=orgs,
        units=service.sum_counts(service.unit_counts_by_project(session, ids).values()),
        acceptance_rate=service.acceptance_rate(session, ids),
        billable_rework=service.billable_rework(session, ids),
        deliveries=len(service.deliveries_of(session, ids)),
        invoice_total=totals,
        next_delivery=next_delivery_out(session, scope),
    )


@router.get("/client/projects", response_model=list[ClientProjectOut], dependencies=[ClientRole])
def client_projects(session: DB, scope: Scope) -> list[ClientProjectOut]:
    projects = service.list_projects(session, scope)
    counts = service.unit_counts_by_project(session, [p.id for p in projects])
    return [client_project_out(session, p, counts[p.id]) for p in projects]


@router.get("/client/projects/{project_id}", response_model=ClientProjectDetailOut, dependencies=[ClientRole])
def client_project(project_id: uuid.UUID, session: DB, scope: Scope) -> ClientProjectDetailOut:
    project = service.scoped_project(session, project_id, scope)
    counts = service.unit_counts_by_project(session, [project.id])[project.id]
    return ClientProjectDetailOut(
        **client_project_out(session, project, counts).model_dump(),
        rubric_log=[RubricLogEntry.model_validate(e) for e in project.rubric_log],
        batches=client_batches(session, service.batches_of(session, project.id)),
        reasons=service.reasons_for(session, [project.id]),
        deliveries=[ClientManifestOut.model_validate(m) for m in service.deliveries_of(session, [project.id])],
        feedback=feedback_out(session, project.id),
    )


@router.post(
    "/client/projects/{project_id}/feedback",
    response_model=FeedbackOut,
    status_code=status.HTTP_201_CREATED,
    dependencies=[ClientRole],
)
def client_feedback(
    project_id: uuid.UUID, body: FeedbackIn, worker_id: WorkerId, session: DB, scope: Scope
) -> FeedbackOut:
    project = service.scoped_project(session, project_id, scope)
    row = service.add_feedback(session, project, worker_id, body.body)
    return FeedbackOut.model_validate(row).model_copy(
        update={"author_name": service.names_of(session, [worker_id]).get(worker_id)}
    )


@router.get("/client/batches/{batch_id}/manifest", response_model=ManifestOut, dependencies=[ClientRole])
def client_manifest(batch_id: uuid.UUID, session: DB, scope: Scope) -> DeliveryManifest:
    """The delivery itself, units included. Read-only: the ops gate builds it; here an unbuilt one is 404."""
    return service.client_manifest(session, batch_id, scope)


@router.get("/client/batches/{batch_id}/deliverable", response_model=DeliverableOut, dependencies=[ClientRole])
def client_deliverable(batch_id: uuid.UUID, session: DB, scope: Scope, store: StorageDep) -> DeliverableOut:
    """The delivery as files for a batch the caller's org owns; 404 until the manifest exists or for another org."""
    return deliverable_out(session, store, service.client_manifest(session, batch_id, scope))
