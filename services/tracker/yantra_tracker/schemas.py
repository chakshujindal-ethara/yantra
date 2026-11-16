"""Request and response shapes of the tracker API (docs/PRODUCT.md section 5.7)."""

import uuid
from datetime import date, datetime
from decimal import Decimal
from typing import Any, Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field

DEVICE = r"^[A-Za-z0-9_-]{8,64}$"


class SessionIn(BaseModel):
    claim_id: uuid.UUID | None = None
    source: Literal["web", "desktop"] = "web"
    device_hash: str = Field(pattern=DEVICE)


class SessionOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    worker_id: uuid.UUID
    claim_id: uuid.UUID | None
    project_id: uuid.UUID | None
    source: str
    started_at: datetime
    ended_at: datetime | None
    last_sample_at: datetime | None
    active_seconds: int
    idle_seconds: int
    over_cap_at: datetime | None
    end_reason: str | None


class SampleIn(BaseModel):
    at: AwareDatetime
    kind: Literal["active", "idle", "focus_lost"]
    label: str | None = Field(default=None, min_length=1, max_length=80)


class SamplesIn(BaseModel):
    samples: list[SampleIn] = Field(min_length=1, max_length=500)


class WeekOut(BaseModel):
    starts_at: datetime
    ends_at: datetime
    active_seconds: int
    idle_seconds: int
    cap_hours: Decimal
    cap_source: Literal["worker", "project", "default"]
    over_cap: bool


class SamplesOut(BaseModel):
    accepted: int
    duplicates: int
    over_cap: bool
    active_seconds: int
    idle_seconds: int
    week: WeekOut


class MySessionsOut(BaseModel):
    open_session_id: uuid.UUID | None
    week: WeekOut
    sessions: list[SessionOut]


SCREENSHOT_MAX_BYTES = 5 << 20


class PresignIn(BaseModel):
    session_id: uuid.UUID
    content_type: Literal["image/png", "image/jpeg"]
    size_bytes: int = Field(gt=0, le=SCREENSHOT_MAX_BYTES)  # the exact size: the PUT is signed for it


class PresignOut(BaseModel):
    object_key: str
    put_url: str
    headers: dict[str, str]
    expires_at: datetime


class ScreenshotIn(BaseModel):
    object_key: str = Field(min_length=1, max_length=300)
    size_bytes: int = Field(gt=0, le=SCREENSHOT_MAX_BYTES)  # what was declared at presign; storage must agree
    taken_at: AwareDatetime


class ScreenshotOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    session_id: uuid.UUID
    object_key: str
    content_type: str
    taken_at: datetime
    retention_until: datetime


class AnomalyOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    worker_id: uuid.UUID
    session_id: uuid.UUID | None
    kind: str
    detail: dict[str, Any]
    week_start: date | None
    status: str
    note: str | None
    decided_by: uuid.UUID | None
    decided_at: datetime | None
    created_at: datetime


class DecideIn(BaseModel):
    note: str | None = Field(default=None, max_length=2000)


class CapIn(BaseModel):
    weekly_cap_hours: Decimal = Field(ge=0, le=168, max_digits=5, decimal_places=2)


class CapOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    scope: str
    scope_id: uuid.UUID
    weekly_cap_hours: Decimal
    set_by: uuid.UUID
    updated_at: datetime


class PolicySection(BaseModel):
    title: str
    paragraphs: list[str] = []
    bullets: list[str] = []


class PolicyOut(BaseModel):
    slug: str
    title: str
    summary: str
    version: str
    retention_days: int
    default_cap_hours: int
    sample_seconds: int
    sections: list[PolicySection]
