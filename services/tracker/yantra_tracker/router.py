"""HTTP surface of the tracker (docs/PRODUCT.md section 5.7). The gateway authenticates; this layer trusts
`X-Worker-Id` and `X-Role`. Every handler is one unit of work."""

import uuid
from datetime import datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Query, Request, status

from yantra_common.deps import DB, Ops, Worker, WorkerId
from yantra_tracker import service
from yantra_tracker.config import tracker_settings
from yantra_tracker.models import ActivitySession, AnomalyFlag, HourCap, ScreenshotRef
from yantra_tracker.schemas import (
    AnomalyOut,
    CapIn,
    CapOut,
    DecideIn,
    MySessionsOut,
    PolicyOut,
    PresignIn,
    PresignOut,
    SamplesIn,
    SamplesOut,
    ScreenshotIn,
    ScreenshotOut,
    SessionIn,
    SessionOut,
)

router = APIRouter(prefix="/v1/tracker", tags=["tracker"])


def presigner(request: Request) -> service.Presigner | None:
    """The deployable's object storage (`app.state.storage`), when it has one."""
    return getattr(request.app.state, "storage", None)


@router.get("/policy", response_model=PolicyOut)
def get_policy() -> PolicyOut:
    """Readable by anyone signed in: what is collected, what is not, how long it is kept."""
    s = tracker_settings()
    return service.policy(s.retention_days, s.default_cap_hours)


# ---------- the worker's own sessions ----------


@router.post("/sessions", response_model=SessionOut, status_code=status.HTTP_201_CREATED, dependencies=[Worker])
def start_session(body: SessionIn, worker_id: WorkerId, session: DB) -> ActivitySession:
    return service.start_session(session, worker_id, body, service.now_utc())


@router.post("/sessions/{session_id}/samples", response_model=SamplesOut, dependencies=[Worker])
def add_samples(session_id: uuid.UUID, body: SamplesIn, worker_id: WorkerId, session: DB) -> SamplesOut:
    s = tracker_settings()
    return service.add_samples(
        session, session_id, worker_id, body.samples, service.now_utc(), s.skew_seconds, s.default_cap_hours
    )


@router.post("/sessions/{session_id}/end", response_model=SessionOut, dependencies=[Worker])
def end_session(session_id: uuid.UUID, worker_id: WorkerId, session: DB) -> ActivitySession:
    return service.end_session(session, session_id, worker_id, service.now_utc())


@router.get("/sessions/me", response_model=MySessionsOut, dependencies=[Worker])
def my_sessions(
    worker_id: WorkerId,
    session: DB,
    from_: Annotated[datetime | None, Query(alias="from")] = None,
    to: Annotated[datetime | None, Query()] = None,
) -> MySessionsOut:
    return service.my_sessions(session, worker_id, service.now_utc(), tracker_settings().default_cap_hours, from_, to)


@router.post("/screenshots/presign", response_model=PresignOut, dependencies=[Worker])
def presign_screenshot(body: PresignIn, request: Request, worker_id: WorkerId, session: DB) -> PresignOut:
    key, signed = service.presign_screenshot(
        session, presigner(request), worker_id, body.session_id, body.content_type, body.size_bytes
    )
    return PresignOut(object_key=key, put_url=signed.url, headers=dict(signed.headers), expires_at=signed.expires_at)


@router.post(
    "/sessions/{session_id}/screenshots",
    response_model=ScreenshotOut,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Worker],
)
def register_screenshot(
    session_id: uuid.UUID, body: ScreenshotIn, request: Request, worker_id: WorkerId, session: DB
) -> ScreenshotRef:
    s = tracker_settings()
    return service.register_screenshot(
        session,
        presigner(request),
        session_id,
        worker_id,
        body.object_key,
        body.size_bytes,
        body.taken_at,
        service.now_utc(),
        s.retention_days,
        s.skew_seconds,
    )


# ---------- operations ----------


@router.get("/sessions", response_model=list[SessionOut], dependencies=[Ops])
def list_sessions(
    session: DB,
    worker_id: Annotated[uuid.UUID | None, Query()] = None,
    from_: Annotated[datetime | None, Query(alias="from")] = None,
    to: Annotated[datetime | None, Query()] = None,
    limit: int = Query(default=100, ge=1, le=500),
) -> list[ActivitySession]:
    return service.list_sessions(session, worker_id, from_, to, limit)


@router.get("/anomalies", response_model=list[AnomalyOut], dependencies=[Ops])
def list_anomalies(
    session: DB,
    status: Literal["open", "dismissed", "upheld"] | None = Query(default="open"),
    limit: int = Query(default=200, ge=1, le=500),
) -> list[AnomalyFlag]:
    return service.list_anomalies(session, status, limit)


@router.post("/anomalies/{anomaly_id}/dismiss", response_model=AnomalyOut, dependencies=[Ops])
def dismiss(anomaly_id: uuid.UUID, body: DecideIn, worker_id: WorkerId, session: DB) -> AnomalyFlag:
    return service.decide_anomaly(session, anomaly_id, worker_id, "dismissed", body.note, service.now_utc())


@router.post("/anomalies/{anomaly_id}/uphold", response_model=AnomalyOut, dependencies=[Ops])
def uphold(anomaly_id: uuid.UUID, body: DecideIn, worker_id: WorkerId, session: DB) -> AnomalyFlag:
    return service.decide_anomaly(session, anomaly_id, worker_id, "upheld", body.note, service.now_utc())


@router.get("/caps", response_model=list[CapOut], dependencies=[Ops])
def list_caps(session: DB) -> list[HourCap]:
    return service.list_caps(session)


@router.put("/caps/{scope}/{scope_id}", response_model=CapOut, dependencies=[Ops])
def set_cap(
    scope: Literal["worker", "project"], scope_id: uuid.UUID, body: CapIn, worker_id: WorkerId, session: DB
) -> HourCap:
    return service.set_cap(session, scope, scope_id, body.weekly_cap_hours, worker_id, service.now_utc())
