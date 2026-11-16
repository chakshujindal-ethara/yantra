"""Request and response shapes of the analytics API (docs/PRODUCT.md section 5.8). Money is a string, as
everywhere else."""

import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


class Tile(BaseModel):
    """One number on the leadership page: its value now, its baseline, which way is better, what it is made of,
    and the destination that explains it."""

    key: str
    label: str
    value: str | None
    baseline: str | None
    unit: Literal["days", "money", "ratio", "count", "per_1000"]
    better: Literal["lower", "higher"]
    currency: str | None = None
    basis: dict[str, Any] = {}
    href: str
    note: str | None = None


class MarginRow(BaseModel):
    project_id: uuid.UUID
    currency: str
    accepted: int
    price: str
    pay: str
    review: str
    audit: str
    margin: str
    margin_per_unit: str | None
    margin_fraction: str | None


class LeadershipOut(BaseModel):
    as_of: datetime
    window_days: int
    currency: str
    baseline_set_at: datetime | None
    numbers: list[Tile]
    margin: list[MarginRow]
    watch: list[Tile]


class TrendDay(BaseModel):
    day: date
    published: int
    claimed: int
    submitted: int
    accepted: int
    rejected: int
    first_pass_rate: str | None
    pay: str
    price: str
    review_cost: str
    margin: str


class TrendOut(BaseModel):
    project_id: uuid.UUID
    currency: str | None
    days: list[TrendDay]


class FunnelOut(BaseModel):
    listing_id: uuid.UUID | None
    window_days: int
    stages_available: list[str]
    stages: dict[str, int]
    by_day: list[dict[str, Any]]


class WorkforceRow(BaseModel):
    worker_id: uuid.UUID
    active_hours: str
    units_accepted: int
    units_judged: int
    acceptance_rate: str | None
    earnings: dict[str, str]


class WorkforceOut(BaseModel):
    week_start: date
    workers: list[WorkforceRow]
    totals: dict[str, Any]


class BaselineIn(BaseModel):
    currency: str = Field(default="INR", pattern=r"^[A-Z]{3}$")
    days_to_staff: Decimal | None = Field(default=None, ge=0, max_digits=8, decimal_places=2)
    idle_cost_weekly: Decimal | None = Field(default=None, ge=0)
    first_pass_acceptance: Decimal | None = Field(default=None, ge=0, le=1)
    cost_per_accepted_unit: Decimal | None = Field(default=None, ge=0)
    idle_hourly_cost: Decimal = Field(default=Decimal("0"), ge=0)
    idle_hours_per_week: int = Field(default=10, ge=0, le=168)
    staffing_workers: int = Field(default=5, ge=1, le=10000)
    rail_fee_per_payout: Decimal = Field(default=Decimal("0"), ge=0)
    levy_rate: Decimal = Field(default=Decimal("0"), ge=0, le=1)
    payout_sla_days: int = Field(default=7, ge=0, le=60)
    note: str | None = Field(default=None, max_length=2000)


class BaselineOut(BaselineIn):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    set_by: uuid.UUID
    set_at: datetime


class RebuildOut(BaseModel):
    generation: int
    status: Literal["idle", "requested", "running", "done"]
    mode: Literal["repair", "purge"] | None = None
    requested_by: str | None = None
    requested_at: str | None = None
    started_at: str | None = None
    finished_at: str | None = None
    events: int | None = None
