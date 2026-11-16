"""HTTP surface of the assess module (docs/PRODUCT.md section 5.3). The exam itself runs in the Assessment app
(Ethara's Assessment v2); these routes manage papers, put a worker on the right cohort and hand back a one-time URL
into their exam, and report what the sync learned from the engine."""

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, Request, status
from pydantic import BaseModel, ConfigDict, Field

from yantra_assess import service
from yantra_assess.config import AssessSettings
from yantra_assess.engine import Engine, EngineAssessment, QuickQuestion, Ticket
from yantra_assess.models import Cohort, Paper, Sitting
from yantra_common.deps import DB, CallerEmail, Ops, Worker, WorkerId, require_any
from yantra_common.people import Name

router = APIRouter(prefix="/v1/assess", tags=["assess"])
OpsOrAdmin = Depends(require_any("ops", "admin", message="ops or admin role required"))


def engine(request: Request) -> Engine:
    chosen: Engine = request.app.state.assess_engine
    return chosen


def assess_settings(request: Request) -> AssessSettings:
    chosen: AssessSettings = request.app.state.assess_settings
    return chosen


EngineDep = Annotated[Engine, Depends(engine)]
Settings = Annotated[AssessSettings, Depends(assess_settings)]


class QuickQuestionIn(BaseModel):
    id: str = Field(min_length=1, max_length=40)
    prompt: str = Field(min_length=1, max_length=4000)
    kind: Literal["single", "multi"]
    options: list[str] = Field(min_length=2, max_length=20)
    answer: str | list[str]


class LinkSource(BaseModel):
    kind: Literal["assessment"]
    assessment_id: int = Field(gt=0)


class QuickSource(BaseModel):
    kind: Literal["quick"]
    duration_minutes: int
    pass_mark: Decimal
    questions: list[QuickQuestionIn] = Field(min_length=1, max_length=100)


class PaperIn(BaseModel):
    gate: str = Field(min_length=1, max_length=80)
    title: str = Field(min_length=1, max_length=200)
    description: str = Field(default="", max_length=4000)
    max_attempts: int = 2
    release_policy: Literal["manual", "auto_objective"] = "manual"
    assigned_ttl_days: int = 14
    source: LinkSource | QuickSource = Field(discriminator="kind")


class Stats(BaseModel):
    total: int
    passed: int
    pass_rate: Decimal | None
    awaiting_result: int
    held: int


class CohortOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    attempt_no: int
    generation: int
    engine_assessment_id: int
    state: str


class PaperOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    gate: str
    title: str
    description: str
    max_attempts: int
    status: str
    engine: str
    engine_assessment_id: int | None
    release_policy: str
    assigned_ttl_days: int
    generation: int
    snapshot: dict[str, Any] | None
    created_at: datetime
    published_at: datetime | None
    created_by: uuid.UUID | None
    published_by: uuid.UUID | None
    stats: Stats
    cohorts: list[CohortOut] = Field(default_factory=list)


class EngineAssessmentOut(BaseModel):
    id: int
    name: str
    state: str
    duration_minutes: int
    pass_threshold: float
    question_count: int
    question_types: list[str]


class SittingOut(BaseModel):
    """One attempt as Yantra tracks it; `score` (0..1) only once the result is released."""

    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    paper_id: uuid.UUID
    worker_id: uuid.UUID
    attempt_no: int | None
    status: str
    held_reason: str | None
    result: str | None
    released: bool
    score: Decimal | None
    deadline: datetime | None
    started_at: datetime | None
    submitted_at: datetime | None
    created_at: datetime
    flags: dict[str, Any] | None


class MySittingOut(SittingOut):
    paper_title: str
    gate: str


class BriefOut(BaseModel):
    id: uuid.UUID
    gate: str
    title: str
    description: str
    status: str
    duration_minutes: int | None
    pass_mark: Decimal | None
    question_count: int | None
    question_types: list[str]
    proctoring: dict[str, Any]
    attempts_used: int
    attempts_left: int
    certified: bool
    current: SittingOut | None


class LaunchOut(BaseModel):
    launch_url: str
    expires_at: datetime
    sitting: SittingOut | None = None


class ReleaseIn(BaseModel):
    sitting_ids: list[uuid.UUID] | None = Field(default=None, max_length=500)


class ReleaseOut(BaseModel):
    released: int


class SyncOut(BaseModel):
    changed: int


class ExamIn(BaseModel):
    exam_token: str = Field(min_length=1, max_length=128)


class AdminLaunchIn(BaseModel):
    next: str = Field(default="/", max_length=300)


def _paper(paper: Paper, stats: dict[str, Any], cohorts: list[Cohort] | None = None) -> PaperOut:
    return PaperOut(
        id=paper.id,
        gate=paper.gate,
        title=paper.title,
        description=paper.description,
        max_attempts=paper.max_attempts,
        status=paper.status,
        engine=paper.engine,
        engine_assessment_id=paper.engine_base_id,
        release_policy=paper.release_policy,
        assigned_ttl_days=paper.assigned_ttl_days,
        generation=paper.generation,
        snapshot=paper.snapshot,
        created_at=paper.created_at,
        published_at=paper.published_at,
        created_by=paper.created_by,
        published_by=paper.published_by,
        stats=Stats.model_validate(stats),
        cohorts=[CohortOut.model_validate(c) for c in cohorts or []],
    )


def _one(session: Any, paper: Paper) -> PaperOut:
    return _paper(paper, service.paper_stats(session, [paper.id])[paper.id], service.cohorts_of(session, paper.id))


def _assessment(a: EngineAssessment) -> EngineAssessmentOut:
    return EngineAssessmentOut(
        id=a.id,
        name=a.name,
        state=a.state,
        duration_minutes=a.duration_minutes,
        pass_threshold=a.pass_threshold,
        question_count=a.question_count,
        question_types=a.question_types,
    )


def _launch(ticket: Ticket, sitting: Sitting | None = None) -> LaunchOut:
    return LaunchOut(
        launch_url=ticket.launch_url,
        expires_at=ticket.expires_at,
        sitting=SittingOut.model_validate(sitting) if sitting else None,
    )


# ---------- ops ----------


@router.get("/engine/assessments", response_model=list[EngineAssessmentOut], dependencies=[Ops])
def engine_assessments(engine: EngineDep, state: str | None = "draft") -> list[EngineAssessmentOut]:
    """Assessments built in the Assessment admin that a paper may link (drafts unless `state` says otherwise)."""
    return [_assessment(a) for a in service.engine_assessments(engine, state or None)]


@router.post("/papers", response_model=PaperOut, status_code=status.HTTP_201_CREATED, dependencies=[Ops])
def create_paper(body: PaperIn, worker_id: WorkerId, session: DB, engine: EngineDep) -> PaperOut:
    source: dict[str, Any] = body.source.model_dump()
    if isinstance(body.source, QuickSource):
        source["questions"] = [QuickQuestion(**q.model_dump()) for q in body.source.questions]
    paper = service.create_paper(
        session,
        engine,
        gate=body.gate,
        title=body.title,
        description=body.description,
        max_attempts=body.max_attempts,
        source=source,
        release_policy=body.release_policy,
        assigned_ttl_days=body.assigned_ttl_days,
        created_by=worker_id,
    )
    return _one(session, paper)


@router.get("/papers", response_model=list[PaperOut], dependencies=[Ops])
def list_papers(session: DB) -> list[PaperOut]:
    return [_paper(paper, stats) for paper, stats in service.list_papers(session)]


@router.get("/papers/{paper_id}", response_model=PaperOut, dependencies=[Ops])
def get_paper(paper_id: uuid.UUID, session: DB) -> PaperOut:
    return _one(session, service.get_paper(session, paper_id))


@router.post("/papers/{paper_id}/publish", response_model=PaperOut, dependencies=[Ops])
def publish_paper(paper_id: uuid.UUID, worker_id: WorkerId, session: DB, engine: EngineDep) -> PaperOut:
    return _one(session, service.publish_paper(session, engine, paper_id, worker_id))


@router.get("/papers/{paper_id}/sittings", response_model=list[SittingOut], dependencies=[Ops])
def paper_sittings(paper_id: uuid.UUID, session: DB) -> list[SittingOut]:
    return [SittingOut.model_validate(s) for s in service.paper_sittings(session, paper_id)]


@router.post("/papers/{paper_id}/release", response_model=ReleaseOut, dependencies=[Ops])
def release(paper_id: uuid.UUID, body: ReleaseIn, session: DB, engine: EngineDep) -> ReleaseOut:
    return ReleaseOut(released=service.release(session, engine, paper_id, body.sitting_ids))


@router.post("/papers/{paper_id}/rotate", response_model=PaperOut, dependencies=[Ops])
def rotate(paper_id: uuid.UUID, session: DB, engine: EngineDep) -> PaperOut:
    return _one(session, service.rotate(session, engine, paper_id))


@router.post("/sync", response_model=SyncOut, dependencies=[Ops])
def sync(session: DB, engine: EngineDep) -> SyncOut:
    """A by-hand pass of the sync the work events process runs every few seconds."""
    return SyncOut(changed=service.sync(session, engine))


@router.post("/admin-launch", response_model=LaunchOut, dependencies=[OpsOrAdmin])
def admin_launch(
    body: AdminLaunchIn, worker_id: WorkerId, email: CallerEmail, name: Name, engine: EngineDep, settings: Settings
) -> LaunchOut:
    """A one-time URL that signs the operator into the Assessment admin at `next`."""
    ticket = service.admin_launch(engine, settings, worker_id, email.address, email.verified, name or "", body.next)
    return _launch(ticket)


# ---------- the worker ----------


@router.get("/papers/{paper_id}/brief", response_model=BriefOut, dependencies=[Worker])
def brief(paper_id: uuid.UUID, worker_id: WorkerId, session: DB) -> BriefOut:
    b = service.brief(session, paper_id, worker_id)
    snap = b.paper.snapshot or {}
    threshold = snap.get("pass_threshold")
    return BriefOut(
        id=b.paper.id,
        gate=b.paper.gate,
        title=b.paper.title,
        description=b.paper.description,
        status=b.paper.status,
        duration_minutes=snap.get("duration_minutes", b.paper.duration_minutes),
        pass_mark=(Decimal(str(threshold)) / 100).quantize(service.PLACES) if threshold else b.paper.pass_mark,
        question_count=snap.get("question_count", len(b.paper.questions or []) or None),
        question_types=list(snap.get("question_types") or []),
        proctoring=dict(snap.get("rules") or {}),
        attempts_used=b.attempts_used,
        attempts_left=b.attempts_left,
        certified=b.certified,
        current=SittingOut.model_validate(b.current) if b.current else None,
    )


@router.post("/papers/{paper_id}/launch", response_model=LaunchOut, dependencies=[Worker])
def launch(
    paper_id: uuid.UUID,
    worker_id: WorkerId,
    email: CallerEmail,
    name: Name,
    session: DB,
    engine: EngineDep,
    settings: Settings,
) -> LaunchOut:
    """A one-time URL (two minutes) into the worker's exam in the Assessment app; open it in this tab."""
    ticket, sitting = service.launch(
        session, engine, settings, paper_id, worker_id, email.address, email.verified, name or ""
    )
    return _launch(ticket, sitting)


@router.post("/launch-by-exam", response_model=LaunchOut, dependencies=[Worker])
def launch_by_exam(
    body: ExamIn, worker_id: WorkerId, email: CallerEmail, name: Name, engine: EngineDep, settings: Settings
) -> LaunchOut:
    ticket = service.launch_by_exam(
        engine, settings, worker_id, body.exam_token, email.address, email.verified, name or ""
    )
    return _launch(ticket)


@router.get("/sittings/me", response_model=list[MySittingOut], dependencies=[Worker])
def my_sittings(worker_id: WorkerId, session: DB) -> list[MySittingOut]:
    """The caller's sittings, newest first (200 at most)."""
    return [
        MySittingOut(**SittingOut.model_validate(s).model_dump(), paper_title=p.title, gate=p.gate)
        for s, p in service.my_sittings(session, worker_id)
    ]
