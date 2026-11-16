"""The tracker operations. Each function works inside the caller's session and leaves the commit to the caller.
Pure rules (the IST week, the 30-second bucket, the label rule, the cap) sit at the top; the database shell below.

What a sample means: the client sends one sample per 30 seconds while a claim is open on screen. The server
quantises `at` to the bucket start and keys the row by (session, bucket), so a batch sent twice counts once,
two samples in one bucket count once, and active time can never exceed the wall clock."""

import logging
import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Any, Literal, Protocol
from zoneinfo import ZoneInfo

from sqlalchemy import String, delete, distinct, func, literal, select, tuple_, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session

from yantra_common.errors import Conflict, DomainError, Forbidden, Invalid, NotFound
from yantra_common.outbox import emit
from yantra_common.pii import pii_hash
from yantra_contracts.events.v1 import (
    TrackingAnomalyFlagged,
    TrackingAnomalyUpheld,
    TrackingCapExceeded,
    TrackingSessionEnded,
)
from yantra_tracker.models import (
    OUTBOX,
    ActivitySample,
    ActivitySession,
    AnomalyFlag,
    ConsentWithdrawal,
    Erasure,
    HourCap,
    LiveClaim,
    ScreenshotRef,
)
from yantra_tracker.schemas import (
    SCREENSHOT_MAX_BYTES,
    MySessionsOut,
    PolicyOut,
    PolicySection,
    SampleIn,
    SamplesOut,
    SessionIn,
    SessionOut,
    WeekOut,
)

log = logging.getLogger("yantra.tracker")
IST = ZoneInfo("Asia/Kolkata")
SAMPLE_SECONDS = 30
WEB_LABEL = "yantra-web"
IMPOSSIBLE_SECONDS = 20 * 3600  # more active time than this in any 24 hours is not one person
AFTER_CLAIM_GRACE = timedelta(minutes=10)
DEVICE_WINDOW = timedelta(days=7)
POLICY_VERSION = "2026-11"
ERASED_DEVICE = "erased"
CapSource = Literal["worker", "project", "default"]


class StorageUnconfigured(DomainError):
    status = 503
    code = "storage_unconfigured"


class Presigned(Protocol):
    @property
    def url(self) -> str: ...
    @property
    def headers(self) -> dict[str, str]: ...
    @property
    def expires_at(self) -> datetime: ...


class Stored(Protocol):
    @property
    def size(self) -> int: ...


class Presigner(Protocol):
    """What the tracker needs from object storage (`yantra_common.storage` meets it)."""

    def presign_put(
        self, key: str, content_type: str, max_bytes: int, *, size_bytes: int | None = None
    ) -> Presigned: ...

    def head(self, key: str) -> Stored | None: ...

    def delete(self, keys: Sequence[str]) -> int: ...

    def list_keys(self, prefix: str) -> list[str]: ...


def now_utc() -> datetime:
    return datetime.now(UTC)


# ---------- pure rules ----------


def week_bounds(now: datetime) -> tuple[datetime, datetime]:
    """The ISO week (Monday 00:00 to the next Monday 00:00) in IST that holds `now`, in UTC."""
    local = now.astimezone(IST)
    monday = (local - timedelta(days=local.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
    return monday.astimezone(UTC), (monday + timedelta(days=7)).astimezone(UTC)


def bucket(at: datetime) -> datetime:
    """The start of the 30-second bucket that holds `at`, in UTC."""
    at = at.astimezone(UTC)
    return at.replace(second=at.second - at.second % SAMPLE_SECONDS, microsecond=0)


def stored_label(label: str | None) -> str | None:
    """The web client's own label is stored as is; any other (a desktop window or app name) only as a keyed digest,
    so a window title never lands in the database."""
    if label is None or label == WEB_LABEL:
        return label
    return pii_hash(label)


def over_cap(active_seconds: int, cap_hours: Decimal) -> bool:
    return Decimal(active_seconds) > cap_hours * 3600


def policy(retention_days: int, default_cap_hours: int) -> PolicyOut:
    """What the tracker collects, in words a worker reads before their first claim."""
    return PolicyOut(
        slug="tracking",
        title="What we track while you work",
        summary="Only while a claim is open on your screen, and only whether you are active.",
        version=POLICY_VERSION,
        retention_days=retention_days,
        default_cap_hours=default_cap_hours,
        sample_seconds=SAMPLE_SECONDS,
        sections=[
            PolicySection(
                title="What is collected",
                bullets=[
                    "Every 30 seconds while a claim is open: active (you typed, clicked or scrolled in the last "
                    "minute), idle, or away (the tab was hidden).",
                    "Which claim the time belongs to, and a random device id kept in your browser.",
                    "The label 'yantra-web'. Nothing about other tabs or windows.",
                ],
            ),
            PolicySection(
                title="What is not collected",
                bullets=[
                    "Keystrokes, what you type, or what is on your screen.",
                    "Window titles or other applications.",
                    "Screenshots: the web app never takes them. A desktop agent may in future, and only with a new "
                    "version of this policy that you accept first.",
                ],
            ),
            PolicySection(
                title="How it is used",
                paragraphs=[
                    f"Your active hours count against a weekly cap (default {default_cap_hours} hours). Going over the "
                    "cap is recorded and shown to operations; work keeps being recorded.",
                    "Patterns that cannot come from one person working (more than 20 active hours in a day, activity "
                    "on a claim that has ended, one device used by several accounts) are flagged for a human to "
                    "review. A flag an operator upholds may hold your payouts while it is looked into.",
                    "You are paid per accepted unit, never per hour tracked.",
                ],
            ),
            PolicySection(
                title="How long it is kept",
                paragraphs=[f"Samples are deleted after {retention_days} days. Session totals stay with your work."],
            ),
        ],
    )


# ---------- sessions ----------


def require_consent(session: Session, worker_id: uuid.UUID) -> None:
    """Nothing is collected from a worker who withdrew the data-processing consent: 403 `consent_withdrawn`."""
    if session.get(ConsentWithdrawal, worker_id) is not None:
        raise Forbidden("you withdrew your consent to data processing; give it again in onboarding").with_code(
            "consent_withdrawn"
        )


def _claim_problem(claim: LiveClaim | None, worker_id: uuid.UUID, now: datetime) -> str | None:
    """Why a session cannot start on this claim, or None. An unknown claim is accepted: the claim event may not
    have arrived yet, and the anomaly scan judges the samples later."""
    if claim is None:
        return None
    if claim.worker_id != worker_id:
        return "the claim belongs to someone else"
    if claim.ended_at is not None:
        return "the claim has ended"
    if claim.expires_at is not None and claim.expires_at < now:
        return "the claim has expired"
    return None


def start_session(session: Session, worker_id: uuid.UUID, body: SessionIn, now: datetime) -> ActivitySession:
    require_consent(session, worker_id)
    claim = session.get(LiveClaim, body.claim_id) if body.claim_id else None
    problem = _claim_problem(claim, worker_id, now)
    if problem:
        raise Conflict(problem, claim_id=str(body.claim_id)).with_code("claim_not_live")
    open_id = session.scalar(
        select(ActivitySession.id).where(ActivitySession.worker_id == worker_id, ActivitySession.ended_at.is_(None))
    )
    if open_id is not None:
        raise Conflict("a session is already open", session_id=str(open_id)).with_code("session_open")
    row = ActivitySession(
        worker_id=worker_id,
        claim_id=body.claim_id,
        project_id=claim.project_id if claim else None,
        source=body.source,
        device_hash=body.device_hash,
        started_at=now,
        active_seconds=0,
        idle_seconds=0,
    )
    session.add(row)
    session.flush()
    return row


def _own_session(session: Session, session_id: uuid.UUID, worker_id: uuid.UUID, lock: bool = False) -> ActivitySession:
    q = select(ActivitySession).where(ActivitySession.id == session_id)
    if lock:
        q = q.with_for_update()
    row = session.scalar(q)
    if row is None or row.worker_id != worker_id:
        raise NotFound("no such session", id=str(session_id))
    return row


def resolve_cap(
    session: Session, worker_id: uuid.UUID, project_id: uuid.UUID | None, default: int
) -> tuple[Decimal, CapSource]:
    """The worker's own cap wins over the project's, which wins over the default."""
    worker_cap = session.get(HourCap, ("worker", worker_id))
    if worker_cap is not None:
        return worker_cap.weekly_cap_hours, "worker"
    if project_id is not None:
        project_cap = session.get(HourCap, ("project", project_id))
        if project_cap is not None:
            return project_cap.weekly_cap_hours, "project"
    return Decimal(default), "default"


def week_seconds(session: Session, worker_id: uuid.UUID, now: datetime) -> tuple[int, int]:
    """Active and idle seconds of the worker's samples in the current IST week."""
    starts, ends = week_bounds(now)
    rows = session.execute(
        select(ActivitySample.kind, func.count())
        .join(ActivitySession, ActivitySession.id == ActivitySample.session_id)
        .where(ActivitySession.worker_id == worker_id, ActivitySample.at >= starts, ActivitySample.at < ends)
        .group_by(ActivitySample.kind)
    ).all()
    counts = {kind: int(n) for kind, n in rows}
    active = counts.get("active", 0) * SAMPLE_SECONDS
    idle = (counts.get("idle", 0) + counts.get("focus_lost", 0)) * SAMPLE_SECONDS
    return active, idle


def week_out(
    session: Session, worker_id: uuid.UUID, project_id: uuid.UUID | None, now: datetime, default_cap: int
) -> WeekOut:
    starts, ends = week_bounds(now)
    active, idle = week_seconds(session, worker_id, now)
    cap, source = resolve_cap(session, worker_id, project_id, default_cap)
    return WeekOut(
        starts_at=starts,
        ends_at=ends,
        active_seconds=active,
        idle_seconds=idle,
        cap_hours=cap,
        cap_source=source,
        over_cap=over_cap(active, cap),
    )


def add_samples(
    session: Session,
    session_id: uuid.UUID,
    worker_id: uuid.UUID,
    samples: list[SampleIn],
    now: datetime,
    skew_seconds: int,
    default_cap: int,
) -> SamplesOut:
    require_consent(session, worker_id)
    row = _own_session(session, session_id, worker_id, lock=True)
    if row.ended_at is not None:
        raise Conflict("the session has ended", id=str(session_id)).with_code("session_ended")
    skew = timedelta(seconds=skew_seconds)
    earliest, latest = row.started_at - skew, now + skew
    buckets: dict[datetime, SampleIn] = {}
    for i, s in enumerate(samples):
        if not earliest <= s.at <= latest:
            raise Invalid("a sample is outside the session or too far in the future", index=i).with_code(
                "sample_out_of_range"
            )
        buckets.setdefault(bucket(s.at), s)
    inserted = session.execute(
        pg_insert(ActivitySample)
        .values(
            [
                {
                    "session_id": row.id,
                    "at": at,
                    "kind": s.kind,
                    "label": stored_label(s.label),
                    "over_cap": False,
                    "received_at": now,
                }
                for at, s in buckets.items()
            ]
        )
        .on_conflict_do_nothing(index_elements=["session_id", "at"])
        .returning(ActivitySample.at, ActivitySample.kind)
    ).all()
    active = sum(1 for _, kind in inserted if kind == "active") * SAMPLE_SECONDS
    row.active_seconds += active
    row.idle_seconds += len(inserted) * SAMPLE_SECONDS - active
    if inserted:
        newest = max(at for at, _ in inserted)
        row.last_sample_at = newest if row.last_sample_at is None else max(row.last_sample_at, newest)
    session.flush()
    week = week_out(session, worker_id, row.project_id, now, default_cap)
    if week.over_cap and inserted:
        _record_over_cap(session, row, [at for at, _ in inserted], week, now)
    return SamplesOut(
        accepted=len(inserted),
        duplicates=len(samples) - len(inserted),
        over_cap=week.over_cap,
        active_seconds=row.active_seconds,
        idle_seconds=row.idle_seconds,
        week=week,
    )


def _record_over_cap(session: Session, row: ActivitySession, ats: list[datetime], week: WeekOut, now: datetime) -> None:
    """Mark the batch's samples over the cap; the first time in a week, flag it and tell everyone once."""
    session.execute(
        update(ActivitySample)
        .where(ActivitySample.session_id == row.id, ActivitySample.at.in_(ats))
        .values(over_cap=True)
    )
    if row.over_cap_at is None:
        row.over_cap_at = now
    week_start = week.starts_at.astimezone(IST).date()
    new = session.execute(
        pg_insert(AnomalyFlag)
        .values(
            id=uuid.uuid4(),
            worker_id=row.worker_id,
            session_id=row.id,
            kind="over_cap",
            detail={"cap_hours": str(week.cap_hours), "active_seconds": week.active_seconds},
            week_start=week_start,
            status="open",
            created_at=now,
        )
        .on_conflict_do_nothing()
        .returning(AnomalyFlag.id)
    ).first()
    if new is not None:
        emit(
            session,
            OUTBOX,
            str(row.worker_id),
            TrackingCapExceeded(
                worker_id=row.worker_id,
                session_id=row.id,
                week_start=week_start.isoformat(),
                cap_hours=week.cap_hours,
                active_seconds=week.active_seconds,
            ),
        )
        log.info("over cap worker_id=%s session_id=%s", row.worker_id, row.id)


def end_session(
    session: Session, session_id: uuid.UUID, worker_id: uuid.UUID | None, now: datetime, reason: str = "client"
) -> ActivitySession:
    """Close a session once and say so; closing it again returns it unchanged. `worker_id` None is the system."""
    row = session.scalar(select(ActivitySession).where(ActivitySession.id == session_id).with_for_update())
    if row is None or (worker_id is not None and row.worker_id != worker_id):
        raise NotFound("no such session", id=str(session_id))
    if row.ended_at is not None:
        return row
    row.ended_at, row.end_reason = now, reason
    session.flush()
    emit(
        session,
        OUTBOX,
        str(row.worker_id),
        TrackingSessionEnded(
            session_id=row.id,
            worker_id=row.worker_id,
            claim_id=row.claim_id,
            project_id=row.project_id,
            source=row.source,
            started_at=row.started_at.isoformat(),
            ended_at=now.isoformat(),
            active_seconds=row.active_seconds,
            idle_seconds=row.idle_seconds,
        ),
    )
    return row


def my_sessions(
    session: Session,
    worker_id: uuid.UUID,
    now: datetime,
    default_cap: int,
    from_: datetime | None = None,
    to: datetime | None = None,
) -> MySessionsOut:
    """The worker's sessions (this week unless a range is given) with the week's totals. Never a 404."""
    starts, _ = week_bounds(now)
    rows = session.scalars(
        select(ActivitySession)
        .where(
            ActivitySession.worker_id == worker_id,
            ActivitySession.started_at >= (from_ or starts),
            ActivitySession.started_at < (to or now + timedelta(seconds=1)),
        )
        .order_by(ActivitySession.started_at.desc())
        .limit(200)
    ).all()
    open_id = session.scalar(
        select(ActivitySession.id).where(ActivitySession.worker_id == worker_id, ActivitySession.ended_at.is_(None))
    )
    return MySessionsOut(
        open_session_id=open_id,
        week=week_out(session, worker_id, None, now, default_cap),
        sessions=[SessionOut.model_validate(r) for r in rows],
    )


# ---------- screenshots (for a desktop agent; the web app takes none) ----------


def screenshot_prefix(worker_id: uuid.UUID, session_id: uuid.UUID) -> str:
    return f"tracker/{worker_id}/{session_id}/"


def presign_screenshot(
    session: Session,
    presigner: Presigner | None,
    worker_id: uuid.UUID,
    session_id: uuid.UUID,
    content_type: str,
    size_bytes: int,
) -> tuple[str, Presigned]:
    """A key under the session's prefix and a PUT signed for exactly `size_bytes` (at most 5 MiB): the store refuses
    a body of any other size, and registering checks it again."""
    if presigner is None:
        raise StorageUnconfigured("object storage is not configured")
    if not 0 < size_bytes <= SCREENSHOT_MAX_BYTES:
        raise Invalid(f"size_bytes: 1 to {SCREENSHOT_MAX_BYTES}").with_code("too_large")
    require_consent(session, worker_id)
    row = _own_session(session, session_id, worker_id)
    if row.ended_at is not None:
        raise Conflict("the session has ended", id=str(session_id)).with_code("session_ended")
    ext = "png" if content_type == "image/png" else "jpg"
    key = f"{screenshot_prefix(worker_id, session_id)}{uuid.uuid4()}.{ext}"
    return key, presigner.presign_put(key, content_type, size_bytes, size_bytes=size_bytes)


def register_screenshot(
    session: Session,
    presigner: Presigner | None,
    session_id: uuid.UUID,
    worker_id: uuid.UUID,
    object_key: str,
    size_bytes: int,
    taken_at: datetime,
    now: datetime,
    retention_days: int,
    skew_seconds: int,
) -> ScreenshotRef:
    """Record an uploaded screenshot after storage vouches for it: the object is there and is the size declared
    (otherwise it is deleted, 422 `size_mismatch`)."""
    if presigner is None:
        raise StorageUnconfigured("object storage is not configured")
    require_consent(session, worker_id)
    row = _own_session(session, session_id, worker_id)
    if not object_key.startswith(screenshot_prefix(worker_id, session_id)) or ".." in object_key:
        raise Invalid("the key is not under this session's prefix").with_code("key_not_yours")
    skew = timedelta(seconds=skew_seconds)
    if not row.started_at - skew <= taken_at <= (row.ended_at or now) + skew:
        raise Invalid("the screenshot was not taken during the session").with_code("taken_outside_session")
    if session.scalar(select(ScreenshotRef.id).where(ScreenshotRef.object_key == object_key)) is not None:
        raise Conflict("that key is already registered").with_code("already_registered")
    stored = presigner.head(object_key)
    if stored is None:
        raise Invalid("nothing was uploaded there").with_code("object_missing")
    if stored.size != size_bytes or stored.size > SCREENSHOT_MAX_BYTES:
        presigner.delete([object_key])
        raise Invalid("the upload is not the size declared").with_code("size_mismatch")
    ref = ScreenshotRef(
        session_id=row.id,
        object_key=object_key,
        content_type="image/png" if object_key.endswith(".png") else "image/jpeg",
        taken_at=taken_at,
        retention_until=taken_at + timedelta(days=retention_days),
    )
    session.add(ref)
    session.flush()
    return ref


# ---------- operations ----------


def list_sessions(
    session: Session,
    worker_id: uuid.UUID | None,
    from_: datetime | None,
    to: datetime | None,
    limit: int,
) -> list[ActivitySession]:
    q = select(ActivitySession)
    if worker_id is not None:
        q = q.where(ActivitySession.worker_id == worker_id)
    if from_ is not None:
        q = q.where(ActivitySession.started_at >= from_)
    if to is not None:
        q = q.where(ActivitySession.started_at < to)
    return list(session.scalars(q.order_by(ActivitySession.started_at.desc()).limit(limit)).all())


def list_anomalies(session: Session, status: str | None, limit: int) -> list[AnomalyFlag]:
    q = select(AnomalyFlag)
    if status is not None:
        q = q.where(AnomalyFlag.status == status)
    return list(session.scalars(q.order_by(AnomalyFlag.created_at, AnomalyFlag.id).limit(limit)).all())


def decide_anomaly(
    session: Session,
    anomaly_id: uuid.UUID,
    decided_by: uuid.UUID,
    outcome: Literal["dismissed", "upheld"],
    note: str | None,
    now: datetime,
) -> AnomalyFlag:
    flag = session.scalar(select(AnomalyFlag).where(AnomalyFlag.id == anomaly_id).with_for_update())
    if flag is None:
        raise NotFound("no such anomaly", id=str(anomaly_id))
    if flag.worker_id == decided_by:
        raise Forbidden("an anomaly about you is decided by another operator").with_code("self_action")
    if flag.status != "open":
        raise Conflict("the anomaly was already decided", status=flag.status).with_code("anomaly_decided")
    flag.status, flag.note, flag.decided_by, flag.decided_at = outcome, note, decided_by, now
    session.flush()
    if outcome == "upheld":
        emit(
            session,
            OUTBOX,
            str(flag.worker_id),
            TrackingAnomalyUpheld(
                anomaly_id=flag.id,
                worker_id=flag.worker_id,
                session_id=flag.session_id,
                kind=flag.kind,
                decided_by=decided_by,
            ),
        )
    log.info("anomaly decided id=%s outcome=%s", flag.id, outcome)
    return flag


def set_cap(
    session: Session, scope: str, scope_id: uuid.UUID, hours: Decimal, set_by: uuid.UUID, now: datetime
) -> HourCap:
    session.execute(
        pg_insert(HourCap)
        .values(scope=scope, scope_id=scope_id, weekly_cap_hours=hours, set_by=set_by, updated_at=now)
        .on_conflict_do_update(
            index_elements=["scope", "scope_id"],
            set_={"weekly_cap_hours": hours, "set_by": set_by, "updated_at": now},
        )
    )
    cap = session.get(HourCap, (scope, scope_id), populate_existing=True)
    assert cap is not None  # just written
    return cap


def list_caps(session: Session) -> list[HourCap]:
    return list(session.scalars(select(HourCap).order_by(HourCap.scope, HourCap.updated_at.desc())).all())


# ---------- the live-claim read model (consumers call these) ----------


def claim_started(
    session: Session,
    claim_id: uuid.UUID,
    unit_id: uuid.UUID,
    worker_id: uuid.UUID,
    batch_id: uuid.UUID | None,
    project_id: uuid.UUID | None,
    claimed_at: datetime,
    expires_at: datetime | None,
) -> None:
    session.execute(
        pg_insert(LiveClaim)
        .values(
            claim_id=claim_id,
            unit_id=unit_id,
            worker_id=worker_id,
            batch_id=batch_id,
            project_id=project_id,
            claimed_at=claimed_at,
            expires_at=expires_at,
        )
        .on_conflict_do_update(
            index_elements=["claim_id"],
            set_={"batch_id": batch_id, "project_id": project_id, "claimed_at": claimed_at, "expires_at": expires_at},
        )
    )


def claim_ended(
    session: Session, claim_id: uuid.UUID, unit_id: uuid.UUID, worker_id: uuid.UUID, at: datetime, kind: str
) -> None:
    """The claim is over. A claim the tracker never saw start gets an ended row, so later samples on it are judged."""
    session.execute(
        pg_insert(LiveClaim)
        .values(claim_id=claim_id, unit_id=unit_id, worker_id=worker_id, ended_at=at, end_kind=kind)
        .on_conflict_do_update(
            index_elements=["claim_id"],
            set_={"ended_at": at, "end_kind": kind},
            where=LiveClaim.ended_at.is_(None),
        )
    )


# ---------- consent and erasure (consumers call these) ----------


def consent_withdrawn(session: Session, worker_id: uuid.UUID, at: datetime) -> int:
    """Stop collecting: record the withdrawal and end the worker's open session (said, like any other end).
    Returns how many sessions ended."""
    session.execute(
        pg_insert(ConsentWithdrawal)
        .values(worker_id=worker_id, withdrawn_at=at)
        .on_conflict_do_nothing(index_elements=["worker_id"])
    )
    open_ids = session.scalars(
        select(ActivitySession.id).where(ActivitySession.worker_id == worker_id, ActivitySession.ended_at.is_(None))
    ).all()
    for sid in open_ids:
        end_session(session, sid, None, at, reason="consent")
    log.info("consent withdrawn worker_id=%s sessions_ended=%d", worker_id, len(open_ids))
    return len(open_ids)


def consent_given(session: Session, worker_id: uuid.UUID) -> None:
    session.execute(delete(ConsentWithdrawal).where(ConsentWithdrawal.worker_id == worker_id))


def erase_worker(session: Session, worker_id: uuid.UUID, at: datetime) -> None:
    """The worker's personal data in the tracker goes: their samples and screenshot references, the device id on
    every session (`erased`), the device id in their anomaly details. Session totals and decided flags stay (they
    are the record of paid work and of integrity decisions). The objects under `tracker/<worker>/` go on the next
    hourly purge (`purge_erased`), which has the storage."""
    sessions = select(ActivitySession.id).where(ActivitySession.worker_id == worker_id)
    session.execute(delete(ActivitySample).where(ActivitySample.session_id.in_(sessions)))
    session.execute(delete(ScreenshotRef).where(ScreenshotRef.session_id.in_(sessions)))
    session.execute(
        update(ActivitySession).where(ActivitySession.worker_id == worker_id).values(device_hash=ERASED_DEVICE)
    )
    session.execute(
        update(AnomalyFlag)
        .where(AnomalyFlag.worker_id == worker_id)
        .values(detail=AnomalyFlag.detail.op("-")(literal("device_hash", String)))
    )
    session.execute(
        pg_insert(Erasure)
        .values(worker_id=worker_id, erased_at=at)
        .on_conflict_do_nothing(index_elements=["worker_id"])
    )
    log.info("tracker erased worker_id=%s", worker_id)


def purge_erased(session: Session, now: datetime, storage: Presigner | None, limit: int = 50) -> int:
    """Delete every object under an erased worker's prefix (listed: a screenshot never registered goes too). Waits
    while storage is not configured. Returns how many workers were done."""
    pending = session.scalars(
        select(Erasure)
        .where(Erasure.objects_purged_at.is_(None))
        .order_by(Erasure.erased_at)
        .limit(limit)
        .with_for_update(skip_locked=True)
    ).all()
    if not pending or storage is None:
        return 0
    for erasure in pending:
        keys = storage.list_keys(f"tracker/{erasure.worker_id}/")
        if keys:
            storage.delete(keys)
        erasure.objects_purged_at = now
        log.info("tracker erased objects worker_id=%s objects=%d", erasure.worker_id, len(keys))
    session.flush()
    return len(pending)


# ---------- jobs ----------


def end_stale_sessions(session: Session, now: datetime, stale_minutes: int, limit: int = 200) -> int:
    """Open sessions with no sample for `stale_minutes` (a closed tab, a lost connection) are ended."""
    cutoff = now - timedelta(minutes=stale_minutes)
    ids = session.scalars(
        select(ActivitySession.id)
        .where(
            ActivitySession.ended_at.is_(None),
            func.coalesce(ActivitySession.last_sample_at, ActivitySession.started_at) < cutoff,
        )
        .limit(limit)
        .with_for_update(skip_locked=True)
    ).all()
    for sid in ids:
        end_session(session, sid, None, now, reason="stale")
    return len(ids)


@dataclass(frozen=True)
class Finding:
    worker_id: uuid.UUID
    kind: str
    detail: dict[str, Any]
    session_id: uuid.UUID | None = None


def find_impossible_activity(session: Session, now: datetime) -> list[Finding]:
    rows = session.execute(
        select(ActivitySession.worker_id, func.count())
        .join(ActivitySample, ActivitySample.session_id == ActivitySession.id)
        .where(
            ActivitySample.kind == "active", ActivitySample.at >= now - timedelta(hours=24), ActivitySample.at <= now
        )
        .group_by(ActivitySession.worker_id)
        .having(func.count() * SAMPLE_SECONDS > IMPOSSIBLE_SECONDS)
    ).all()
    return [
        Finding(w, "impossible_activity", {"active_seconds": int(n) * SAMPLE_SECONDS, "window_hours": 24})
        for w, n in rows
    ]


def find_activity_after_claim(session: Session, now: datetime) -> list[Finding]:
    """Samples more than ten minutes after the session's claim ended (or lapsed)."""
    claim_end = func.coalesce(LiveClaim.ended_at, LiveClaim.expires_at)
    rows = session.execute(
        select(
            ActivitySession.worker_id, ActivitySession.id, LiveClaim.claim_id, func.max(ActivitySample.at), claim_end
        )
        .join(LiveClaim, LiveClaim.claim_id == ActivitySession.claim_id)
        .join(ActivitySample, ActivitySample.session_id == ActivitySession.id)
        .where(
            claim_end.is_not(None),
            ActivitySample.at > claim_end + AFTER_CLAIM_GRACE,
            ActivitySession.last_sample_at >= now - timedelta(hours=24),
        )
        .group_by(ActivitySession.worker_id, ActivitySession.id, LiveClaim.claim_id, claim_end)
    ).all()
    return [
        Finding(
            worker,
            "no_live_claim",
            {"claim_id": str(claim), "minutes_after": int((latest - ended).total_seconds() // 60)},
            session_id=sid,
        )
        for worker, sid, claim, latest, ended in rows
    ]


def find_shared_devices(session: Session, now: datetime) -> list[Finding]:
    """One device id on two or more workers' sessions in the last seven days: one finding per worker."""
    since = now - DEVICE_WINDOW
    shared = (
        select(ActivitySession.device_hash)
        .where(ActivitySession.started_at >= since, ActivitySession.device_hash != ERASED_DEVICE)
        .group_by(ActivitySession.device_hash)
        .having(func.count(distinct(ActivitySession.worker_id)) >= 2)
    )
    rows = session.execute(
        select(ActivitySession.device_hash, ActivitySession.worker_id)
        .where(ActivitySession.started_at >= since, ActivitySession.device_hash.in_(shared))
        .distinct()
        .order_by(ActivitySession.device_hash, ActivitySession.worker_id)
    ).all()
    workers: dict[str, list[uuid.UUID]] = {}
    for device, worker in rows:
        workers.setdefault(device, []).append(worker)
    return [
        Finding(w, "duplicate_device", {"device_hash": device, "worker_ids": [str(x) for x in ws]})
        for device, ws in workers.items()
        for w in ws
    ]


def scan_anomalies(session: Session, now: datetime) -> int:
    """Run every detector; insert a flag unless an open one of that kind already stands; announce each new one."""
    findings = [
        *find_impossible_activity(session, now),
        *find_activity_after_claim(session, now),
        *find_shared_devices(session, now),
    ]
    new = 0
    for f in findings:
        flag_id = session.execute(
            pg_insert(AnomalyFlag)
            .values(
                id=uuid.uuid4(),
                worker_id=f.worker_id,
                session_id=f.session_id,
                kind=f.kind,
                detail=f.detail,
                status="open",
                created_at=now,
            )
            .on_conflict_do_nothing()
            .returning(AnomalyFlag.id)
        ).scalar()
        if flag_id is None:
            continue
        new += 1
        emit(
            session,
            OUTBOX,
            str(f.worker_id),
            TrackingAnomalyFlagged(
                anomaly_id=flag_id, worker_id=f.worker_id, session_id=f.session_id, kind=f.kind, detail=f.detail
            ),
        )
        log.info("anomaly flagged id=%s kind=%s worker_id=%s", flag_id, f.kind, f.worker_id)
    return new


def purge_expired(
    session: Session, now: datetime, retention_days: int, storage: Presigner | None = None, limit: int = 5000
) -> int:
    """Delete samples older than the retention and screenshot references past theirs (and their objects when
    storage is configured). Bounded per pass; returns how many rows went."""
    cutoff = now - timedelta(days=retention_days)
    old = select(ActivitySample.session_id, ActivitySample.at).where(ActivitySample.received_at < cutoff).limit(limit)
    samples = session.execute(
        delete(ActivitySample).where(tuple_(ActivitySample.session_id, ActivitySample.at).in_(old)),
        execution_options={"synchronize_session": False},
    ).rowcount
    refs = session.execute(
        select(ScreenshotRef.id, ScreenshotRef.object_key).where(ScreenshotRef.retention_until < now).limit(limit)
    ).all()
    if refs and storage is not None:
        storage.delete([key for _, key in refs])
    if refs:
        session.execute(
            delete(ScreenshotRef).where(ScreenshotRef.id.in_([i for i, _ in refs])),
            execution_options={"synchronize_session": False},
        )
    gone = int(samples or 0) + len(refs)
    if gone:
        log.info("tracker purge samples=%d screenshots=%d", samples, len(refs))
    return gone
