"""Test helpers for analytics and every deployable that mounts it: the fixtures, and a small builder for a
coherent warehouse (events ingested through the real `ingest`)."""

import uuid
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

from sqlalchemy.orm import Session

from yantra_analytics.models import CONSUMED, DEAD, JOB_LEASE, TABLES
from yantra_analytics.service import ingest
from yantra_common.events import Envelope
from yantra_common.testing import database_fixtures as _database_fixtures

__all__ = ["ALEMBIC_INI", "CONSUMED", "DEAD", "JOB_LEASE", "TABLES", "Warehouse", "database_fixtures"]

ALEMBIC_INI = Path(__file__).resolve().parents[1] / "alembic.ini"


def database_fixtures(db_name: str, extra_inis: list[Path] | None = None, extra_tables: list[str] | None = None) -> Any:
    return _database_fixtures(db_name, [ALEMBIC_INI, *(extra_inis or [])], [*TABLES, *(extra_tables or [])])


class Warehouse:
    """Write events the way the consumer would. Each method returns the payload it ingested."""

    def __init__(self, session: Session) -> None:
        self.session = session

    def put(self, type_: str, at: datetime, data: dict[str, Any]) -> dict[str, Any]:
        doc = {k: str(v) if isinstance(v, uuid.UUID | Decimal) else v for k, v in data.items()}
        ingest(self.session, Envelope(id=uuid.uuid4(), type=type_, subject="s", occurred_at=at, data=doc))
        return doc

    def published(
        self,
        at: datetime,
        batch: uuid.UUID,
        project: uuid.UUID | None,
        units: int = 4,
        pay: str = "20",
        price: str = "50",
        review: str = "5",
        currency: str = "INR",
    ) -> dict[str, Any]:
        return self.put(
            "work.unit.published.v1",
            at,
            {
                "batch_id": batch,
                "unit_count": units,
                "unit_pay": pay,
                "unit_price": price,
                "review_pay": review,
                "currency": currency,
                "mode": "open",
                "project_id": project,
            },
        )

    def claimed(
        self, at: datetime, unit: uuid.UUID, worker: uuid.UUID, batch: uuid.UUID | None = None
    ) -> dict[str, Any]:
        data: dict[str, Any] = {
            "unit_id": unit,
            "claim_id": uuid.uuid4(),
            "worker_id": worker,
            "expires_at": at.isoformat(),
        }
        if batch is not None:
            data["batch_id"] = batch
        return self.put("work.unit.claimed.v1", at, data)

    def submitted(self, at: datetime, unit: uuid.UUID, batch: uuid.UUID, worker: uuid.UUID) -> dict[str, Any]:
        return self.put(
            "work.unit.submitted.v1",
            at,
            {
                "unit_id": unit,
                "batch_id": batch,
                "claim_id": uuid.uuid4(),
                "submission_id": uuid.uuid4(),
                "worker_id": worker,
                "rubric_version": "v1",
            },
        )

    def verdict(
        self,
        at: datetime,
        unit: uuid.UUID,
        batch: uuid.UUID,
        worker: uuid.UUID,
        reviewer: uuid.UUID,
        accept: bool = True,
        auditor: uuid.UUID | None = None,
        verdict: str = "reject",
        reason: str = "guideline_miss",
        billable: bool = False,
    ) -> dict[str, Any]:
        data: dict[str, Any] = {
            "unit_id": unit,
            "batch_id": batch,
            "submission_id": uuid.uuid4(),
            "worker_id": worker,
            "reviewer_id": reviewer,
            "auditor_id": auditor,
            "rubric_version": "v1",
        }
        if accept:
            return self.put("quality.verdict.accepted.v1", at, data)
        return self.put(
            "quality.verdict.rejected.v1",
            at,
            {**data, "verdict": verdict, "reason_code": reason, "billable": billable},
        )
