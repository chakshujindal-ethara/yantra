"""HTTP surface of analytics (docs/PRODUCT.md section 5.8): read-only numbers for operators, finance and admins;
baselines for operators; the rebuild drill for admins."""

import uuid
from datetime import date
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Query, Request, status
from sqlalchemy import Table

from yantra_analytics import leadership, service
from yantra_analytics.models import Baseline
from yantra_analytics.schemas import (
    BaselineIn,
    BaselineOut,
    FunnelOut,
    LeadershipOut,
    RebuildOut,
    TrendOut,
    WorkforceOut,
)
from yantra_common.deps import DB, Admin, Ops, WorkerId, require_any
from yantra_common.errors import NotFound

router = APIRouter(prefix="/v1/analytics", tags=["analytics"])
Leadership = Depends(require_any("ops", "finance", "admin", message="operator, finance or admin role required"))
IST = ZoneInfo("Asia/Kolkata")


def dead_tables(request: Request) -> list[Table]:
    """The deployable's dead-letter tables (`app.state.dead_tables`), for the incidents tile."""
    return list(getattr(request.app.state, "dead_tables", []))


def today() -> date:
    return service.now_utc().astimezone(IST).date()


@router.get("/leadership", response_model=LeadershipOut, dependencies=[Leadership])
def get_leadership(request: Request, session: DB, days: int = Query(default=30, ge=1, le=365)) -> LeadershipOut:
    return leadership.leadership(session, service.now_utc(), days, dead_tables(request))


@router.get("/projects/{project_id}/trend", response_model=TrendOut, dependencies=[Leadership])
def get_trend(project_id: uuid.UUID, session: DB, days: int = Query(default=30, ge=1, le=365)) -> TrendOut:
    return leadership.trend(session, project_id, today(), days)


@router.get("/funnel", response_model=FunnelOut, dependencies=[Leadership])
def get_funnel(
    session: DB, listing_id: Annotated[uuid.UUID | None, Query()] = None, days: int = Query(default=30, ge=1, le=365)
) -> FunnelOut:
    return leadership.funnel(session, listing_id, today(), days)


@router.get("/workforce", response_model=WorkforceOut, dependencies=[Leadership])
def get_workforce(session: DB, week: Annotated[date | None, Query()] = None) -> WorkforceOut:
    return leadership.workforce(session, week or today())


@router.get("/baselines", response_model=BaselineOut, dependencies=[Leadership])
def get_baseline(session: DB) -> Baseline:
    row = service.latest_baseline(session)
    if row is None:
        raise NotFound("no baseline has been set")
    return row


@router.put("/baselines", response_model=BaselineOut, dependencies=[Ops])
def put_baseline(body: BaselineIn, worker_id: WorkerId, session: DB) -> Baseline:
    """A new row every time: the history of what leadership compared against stays."""
    return service.set_baseline(session, body, worker_id, service.now_utc())


@router.get("/rebuild", response_model=RebuildOut, dependencies=[Leadership])
def get_rebuild(session: DB) -> RebuildOut:
    return service.rebuild_state(session)


@router.post("/rebuild", response_model=RebuildOut, status_code=status.HTTP_202_ACCEPTED, dependencies=[Admin])
def post_rebuild(
    worker_id: WorkerId, session: DB, mode: Literal["repair", "purge"] = Query(default="repair")
) -> RebuildOut:
    return service.request_rebuild(session, mode, worker_id, service.now_utc())
