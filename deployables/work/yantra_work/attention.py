"""`GET /v1/attention`: what waits on an operator across the work deployable's modules, in one call. Each module
counts its own share (`<module>.service.attention`); this router only composes them with the dead letters per
schema. Payout's share is on the money deployable (`GET /v1/payout/attention`)."""

from datetime import UTC, datetime
from typing import Any

from fastapi import APIRouter
from sqlalchemy import Table, func, select

from yantra_common.deps import DB, AdminOrOps
from yantra_market import service as market_service
from yantra_notify import service as notify_service
from yantra_quality import service as quality_service
from yantra_talent import service as talent_service


def attention_router(dead_tables: list[Table]) -> APIRouter:
    router = APIRouter(prefix="/v1", tags=["attention"])

    @router.get("/attention", dependencies=[AdminOrOps])
    def attention(session: DB) -> dict[str, Any]:
        now = datetime.now(UTC)
        dead = {str(t.schema): int(session.scalar(select(func.count()).select_from(t)) or 0) for t in dead_tables}
        return {
            **market_service.attention(session, now),
            **quality_service.attention(session, now),
            **talent_service.attention(session, now),
            **notify_service.attention(session),
            "dead_letters": dead,
        }

    return router
