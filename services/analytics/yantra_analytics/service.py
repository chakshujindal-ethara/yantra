"""Ingest, the control documents and the baselines. Every event lands in `analytics.event` once (its id is the
key) with a minimised payload (`minimise.py`: no names, unit payloads, answers or free text); the ids a mart groups
by are pulled out of it; two dimensions learn what the payloads leave out (a claim names only its unit; the batch's
project comes with its publication or its manifest). An erased worker's id is replaced by a pseudonym everywhere,
and the warehouse keeps `YANTRA_ANALYTICS_RETENTION_DAYS` (400) of events."""

import logging
import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Any, Literal

from sqlalchemy import Text, and_, case, delete, func, or_, select, update
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session

from yantra_analytics.minimise import KEEP, PERSON_FIELDS, minimise
from yantra_analytics.models import Baseline, Control, DimBatch, DimUnit, ErasedWorker, Event, MartWorkerWeek
from yantra_analytics.schemas import BaselineIn, RebuildOut
from yantra_common.errors import Conflict
from yantra_common.events import Envelope
from yantra_common.pii import pii_hash

log = logging.getLogger("yantra.analytics")
ID_FIELDS = ("worker_id", "project_id", "batch_id", "unit_id", "listing_id", "window_id")
EPOCH = datetime(1970, 1, 1, tzinfo=UTC)
DURABLE = "analytics-all"
ERASED = "worker.erasure.completed.v1"
# the event types whose payload may name a person beside `worker_id` (a reviewer, an auditor, an operator)
PERSON_TYPES = sorted(t for t, keep in KEEP.items() if keep & set(PERSON_FIELDS) - {"worker_id"})
PRUNE_CHUNK = 5000
PRUNE_CHUNKS = 20
Mode = Literal["repair", "purge"]


def now_utc() -> datetime:
    return datetime.now(UTC)


def durable_name(generation: int) -> str:
    """The JetStream durable of a generation. A rebuild moves to the next one, which starts at sequence 1."""
    return f"{DURABLE}-g{generation}"


def _uuid(value: Any) -> uuid.UUID | None:
    try:
        return uuid.UUID(str(value)) if value else None
    except ValueError:
        return None


def extract_ids(data: dict[str, Any]) -> dict[str, uuid.UUID | None]:
    """The ids a mart groups by, when the payload carries them and they are well formed."""
    return {f: _uuid(data.get(f)) for f in ID_FIELDS}


def _dec(data: dict[str, Any], key: str) -> Decimal | None:
    v = data.get(key)
    return Decimal(str(v)) if v is not None else None


# ---------- ingest ----------


def ingest(session: Session, env: Envelope) -> None:
    """Store the event once, minimised and with any erased worker's id replaced by their pseudonym, and learn the
    dimensions it carries. `worker.erasure.completed.v1` first pseudonymises every row already stored."""
    if env.type == ERASED:
        worker = _uuid(env.data.get("worker_id"))
        if worker is not None:
            erase_worker(session, worker, env.occurred_at)
    data, subject = _pseudonymised(session, minimise(env.type, env.data), env.subject)
    ids = extract_ids(data)
    session.execute(
        pg_insert(Event)
        .values(
            id=env.id,
            type=env.type,
            subject=subject,
            time=env.occurred_at,
            payload=data,
            ingested_at=now_utc(),
            **ids,
        )
        .on_conflict_do_nothing(index_elements=["id"])
    )
    if ids["unit_id"] and ids["batch_id"]:
        session.execute(
            pg_insert(DimUnit)
            .values(unit_id=ids["unit_id"], batch_id=ids["batch_id"])
            .on_conflict_do_nothing(index_elements=["unit_id"])
        )
    if env.type == "work.unit.published.v1" and ids["batch_id"]:
        _learn_batch(session, ids["batch_id"], data, env.occurred_at, ids["project_id"])
    elif env.type == "delivery.manifest.created.v1" and ids["batch_id"] and ids["project_id"]:
        session.execute(
            pg_insert(DimBatch)
            .values(batch_id=ids["batch_id"], project_id=ids["project_id"], currency=data.get("currency"))
            .on_conflict_do_update(index_elements=["batch_id"], set_={"project_id": ids["project_id"]})
        )


# ---------- erasure and retention ----------


def _id_hash(person_id: uuid.UUID | str) -> str:
    return pii_hash(f"analytics-person:{person_id}")


def _pseudonymised(session: Session, data: dict[str, Any], subject: str) -> tuple[dict[str, Any], str]:
    """`data` and the subject with every erased person's id swapped for their pseudonym."""
    named = {str(data[f]) for f in PERSON_FIELDS if _uuid(data.get(f)) is not None}
    if not named:
        return data, subject
    hashes = {_id_hash(n): n for n in named}
    swaps = {
        hashes[h]: str(p)
        for h, p in session.execute(
            select(ErasedWorker.id_hash, ErasedWorker.pseudonym).where(ErasedWorker.id_hash.in_(hashes))
        ).tuples()
    }
    if not swaps:
        return data, subject
    out = {k: swaps.get(str(v), v) if k in PERSON_FIELDS else v for k, v in data.items()}
    for real, pseudonym in swaps.items():
        subject = subject.replace(real, pseudonym)
    return out, subject


def erase_worker(session: Session, worker_id: uuid.UUID, now: datetime) -> uuid.UUID:
    """Replace the worker's id with a random pseudonym in every stored row (the id column, the payload's person
    fields, the subject) and in the worker-week mart, once. Counts, sums and marts are unchanged: the rows stay,
    they no longer lead back to the person. Returns the pseudonym."""
    id_hash = _id_hash(worker_id)
    session.execute(
        pg_insert(ErasedWorker)
        .values(id_hash=id_hash, pseudonym=uuid.uuid4(), erased_at=now)
        .on_conflict_do_nothing(index_elements=["id_hash"])
    )
    pseudonym = session.execute(select(ErasedWorker.pseudonym).where(ErasedWorker.id_hash == id_hash)).scalar_one()
    real, alias = str(worker_id), str(pseudonym)
    text_payload = func.cast(Event.payload, Text)
    session.execute(
        update(Event)
        .where(or_(Event.worker_id == worker_id, and_(Event.type.in_(PERSON_TYPES), text_payload.contains(real))))
        .values(
            worker_id=case((Event.worker_id == worker_id, pseudonym), else_=Event.worker_id),
            payload=func.cast(func.replace(text_payload, real, alias), JSONB),
            subject=func.replace(Event.subject, real, alias),
        )
        .execution_options(synchronize_session=False)
    )
    session.execute(
        update(MartWorkerWeek)
        .where(MartWorkerWeek.worker_id == worker_id)
        .values(worker_id=pseudonym)
        .execution_options(synchronize_session=False)
    )
    log.info("analytics pseudonymised an erased worker")
    return pseudonym


def prune_events(session: Session, now: datetime, retention_days: int) -> int:
    """Delete warehouse events older than the retention, in bounded chunks. The marts keep the aggregates they
    already hold (a rebuild after this recomputes only what is left)."""
    cutoff = now - timedelta(days=retention_days)
    gone = 0
    for _ in range(PRUNE_CHUNKS):
        old = select(Event.id).where(Event.time < cutoff).limit(PRUNE_CHUNK).scalar_subquery()
        n = int(session.execute(delete(Event).where(Event.id.in_(old))).rowcount or 0)
        gone += n
        if n < PRUNE_CHUNK:
            break
    if gone:
        log.info("analytics retention pruned events=%d", gone)
    return gone


def _learn_batch(
    session: Session, batch_id: uuid.UUID, d: dict[str, Any], at: datetime, project_id: uuid.UUID | None
) -> None:
    values: dict[str, Any] = {
        "currency": d.get("currency"),
        "unit_pay": _dec(d, "unit_pay"),
        "unit_price": _dec(d, "unit_price"),
        "review_pay": _dec(d, "review_pay"),
        "unit_count": d.get("unit_count"),
        "mode": d.get("mode"),
        "published_at": at,
    }
    update = dict(values)
    if project_id is not None:
        values["project_id"] = update["project_id"] = project_id
    session.execute(
        pg_insert(DimBatch)
        .values(batch_id=batch_id, **values)
        .on_conflict_do_update(index_elements=["batch_id"], set_=update)
    )


# ---------- control documents ----------


def read_control(session: Session, key: str, lock: bool = False) -> dict[str, Any]:
    q = select(Control.value).where(Control.key == key)
    if lock:
        q = q.with_for_update()
    value = session.scalar(q)
    return dict(value or {})


def write_control(session: Session, key: str, value: dict[str, Any], now: datetime) -> None:
    session.execute(
        pg_insert(Control)
        .values(key=key, value=value, updated_at=now)
        .on_conflict_do_update(index_elements=["key"], set_={"value": value, "updated_at": now})
    )


def rebuild_state(session: Session) -> RebuildOut:
    doc = read_control(session, "rebuild")
    return RebuildOut(**{"generation": 0, "status": "idle", **doc})


def request_rebuild(session: Session, mode: Mode, by: uuid.UUID, now: datetime) -> RebuildOut:
    """Record the request; the events process carries it out on its next round (it owns the subscription)."""
    doc = {"generation": 0, "status": "idle", **read_control(session, "rebuild", lock=True)}
    if doc["status"] in ("requested", "running"):
        raise Conflict("a rebuild is already under way", status=doc["status"]).with_code("rebuild_running")
    doc.update(
        status="requested",
        mode=mode,
        requested_by=str(by),
        requested_at=now.isoformat(),
        started_at=None,
        finished_at=None,
        events=None,
    )
    write_control(session, "rebuild", doc, now)
    log.info("rebuild requested mode=%s by=%s", mode, by)
    return RebuildOut(**doc)


# ---------- baselines ----------


def latest_baseline(session: Session) -> Baseline | None:
    return session.scalar(select(Baseline).order_by(Baseline.set_at.desc()).limit(1))


def set_baseline(session: Session, body: BaselineIn, by: uuid.UUID, now: datetime) -> Baseline:
    row = Baseline(**body.model_dump(), set_by=by, set_at=now)
    session.add(row)
    session.flush()
    session.refresh(row)  # the stored scale ("4.00"), not the value as typed
    return row
