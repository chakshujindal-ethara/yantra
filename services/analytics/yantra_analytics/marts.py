"""The marts, recomputed from the warehouse for the keys that changed, never incremented: refreshing the same
day twice writes the same rows, and a replay can never double count. Days are IST dates; weeks start on an IST
Monday. The arithmetic of money mirrors payout's margin report: price and pay on an accept, review pay on every
verdict, review pay again for an audited verdict."""

import logging
import uuid
from collections import defaultdict
from collections.abc import Iterable
from datetime import date, datetime, timedelta
from decimal import Decimal
from typing import Any

from sqlalchemy import bindparam, delete, func, select, text
from sqlalchemy.orm import Session, sessionmaker

from yantra_analytics import service
from yantra_analytics.models import (
    Event,
    MartFunnelDay,
    MartPayoutWindow,
    MartProjectDay,
    MartQualityDay,
    MartWorkerWeek,
)
from yantra_common.db import unit_of_work

log = logging.getLogger("yantra.analytics")
ZERO = Decimal("0")
CHUNK_DAYS = 31
OVERLAP = timedelta(minutes=2)  # a transaction may commit after a later one: re-read a short tail every pass
ACCEPTED = "quality.verdict.accepted.v1"
REJECTED = "quality.verdict.rejected.v1"
FUNNEL_STAGES = (
    "applied",
    "assessment",
    "screening",
    "offered",
    "accepted",
    "rejected",
    "declined",
    "withdrawn",
    "expired",
)
DAY = "(e.time at time zone 'Asia/Kolkata')::date"


def week_start(day: date) -> date:
    return day - timedelta(days=day.weekday())


def chunks(days: list[date], size: int = CHUNK_DAYS) -> Iterable[list[date]]:
    for i in range(0, len(days), size):
        yield days[i : i + size]


# Every event with the batch and project it belongs to and the batch's rates; verdict rows carry their rank
# among the unit's verdicts (1 = the first pass).
EVENTS_WITH_BATCH = f"""
with ev as (
    select e.id, e.type, e.time, {DAY} as day, e.unit_id, e.worker_id, e.payload,
           coalesce(e.batch_id, u.batch_id) as batch_id, e.project_id as own_project
    from analytics.event e left join analytics.dim_unit u on u.unit_id = e.unit_id
),
evb as (
    select ev.*, coalesce(ev.own_project, b.project_id) as project_id,
           coalesce(b.currency, ev.payload->>'currency') as currency,
           b.unit_pay, b.unit_price, b.review_pay
    from ev left join analytics.dim_batch b on b.batch_id = ev.batch_id
),
ranked as (
    select evb.*, case when type in ('{ACCEPTED}', '{REJECTED}')
        then row_number() over (partition by unit_id, type in ('{ACCEPTED}', '{REJECTED}') order by time, id)
    end as verdict_rank
    from evb
)
"""

PROJECT_DAY = text(
    EVENTS_WITH_BATCH
    + f"""
select project_id, day, currency,
    coalesce(sum((payload->>'unit_count')::int) filter (where type = 'work.unit.published.v1'), 0) as published,
    count(*) filter (where type = 'work.unit.claimed.v1') as claimed,
    count(*) filter (where type = 'work.unit.submitted.v1') as submitted,
    count(*) filter (where type = '{ACCEPTED}') as accepted,
    count(*) filter (where type = '{REJECTED}') as rejected,
    count(*) filter (where verdict_rank = 1 and type = '{ACCEPTED}') as fp_num,
    count(*) filter (where verdict_rank = 1) as fp_den,
    coalesce(sum(unit_pay) filter (where type = '{ACCEPTED}'), 0) as pay,
    coalesce(sum(unit_price) filter (where type = '{ACCEPTED}'), 0) as price,
    coalesce(sum(review_pay) filter (where type in ('{ACCEPTED}', '{REJECTED}')), 0) as review,
    coalesce(sum(review_pay) filter (
        where type in ('{ACCEPTED}', '{REJECTED}') and payload->>'auditor_id' is not null), 0) as audit
from ranked
where project_id is not null and currency is not null and day in :days
group by project_id, day, currency
"""
).bindparams(bindparam("days", expanding=True))

QUALITY_DAY = text(
    EVENTS_WITH_BATCH
    + f"""
select project_id, day, type, payload->>'verdict' as verdict, payload->>'reason_code' as reason,
       coalesce((payload->>'billable')::boolean, false) as billable,
       payload->>'auditor_id' is not null as audited, count(*) as n
from evb
where project_id is not null and type in ('{ACCEPTED}', '{REJECTED}') and day in :days
group by 1, 2, 3, 4, 5, 6, 7
"""
).bindparams(bindparam("days", expanding=True))

FUNNEL_DAY = text(
    f"""
select e.listing_id, {DAY} as day, e.payload->>'to_status' as stage, count(*) as n
from analytics.event e
where e.type = 'talent.application.moved.v1' and e.listing_id is not null and {DAY} in :days
group by 1, 2, 3
"""
).bindparams(bindparam("days", expanding=True))

WORKER_WEEK = text(
    EVENTS_WITH_BATCH
    + f"""
, wk as (select evb.*, (day - (extract(isodow from day)::int - 1)) as week from evb)
select worker_id, week, 'author' as role, type, currency,
       sum(coalesce((payload->>'active_seconds')::int, 0)) as seconds, count(*) as n, coalesce(sum(unit_pay), 0) as pay
from wk where worker_id is not null and week in :weeks
  and type in ('{ACCEPTED}', '{REJECTED}', 'tracking.session.ended.v1')
group by 1, 2, 3, 4, 5
union all
select (payload->>'reviewer_id')::uuid, week, 'reviewer', type, currency, 0, count(*), coalesce(sum(review_pay), 0)
from wk where payload->>'reviewer_id' is not null and week in :weeks and type in ('{ACCEPTED}', '{REJECTED}')
group by 1, 2, 3, 4, 5
union all
select (payload->>'auditor_id')::uuid, week, 'auditor', type, currency, 0, count(*), coalesce(sum(review_pay), 0)
from wk where payload->>'auditor_id' is not null and week in :weeks and type in ('{ACCEPTED}', '{REJECTED}')
group by 1, 2, 3, 4, 5
"""
).bindparams(bindparam("weeks", expanding=True))


def dirty_keys(session: Session, since: datetime, until: datetime) -> tuple[list[date], list[uuid.UUID]]:
    """The IST days and the pay windows whose events were ingested in (since - overlap, until]."""
    rows = session.execute(
        select(func.date(func.timezone("Asia/Kolkata", Event.time)), Event.window_id)
        .where(Event.ingested_at > since - OVERLAP, Event.ingested_at <= until)
        .distinct()
    ).all()
    days = sorted({d for d, _ in rows})
    windows = sorted({w for _, w in rows if w is not None}, key=str)
    return days, windows


def refresh_project_days(session: Session, days: list[date], now: datetime) -> int:
    session.execute(delete(MartProjectDay).where(MartProjectDay.day.in_(days)))
    rows = session.execute(PROJECT_DAY, {"days": days}).all()
    for r in rows:
        pay, price, review, audit = (Decimal(x) for x in (r.pay, r.price, r.review, r.audit))
        session.add(
            MartProjectDay(
                project_id=r.project_id,
                day=r.day,
                currency=r.currency,
                units_published=r.published,
                units_claimed=r.claimed,
                units_submitted=r.submitted,
                units_accepted=r.accepted,
                units_rejected=r.rejected,
                first_pass_num=r.fp_num,
                first_pass_den=r.fp_den,
                pay=pay,
                price=price,
                review_cost=review,
                audit_cost=audit,
                margin=price - pay - review - audit,
                refreshed_at=now,
            )
        )
    return len(rows)


def refresh_quality_days(session: Session, days: list[date], now: datetime) -> int:
    session.execute(delete(MartQualityDay).where(MartQualityDay.day.in_(days)))
    acc: dict[tuple[uuid.UUID, date], dict[str, Any]] = {}
    for r in session.execute(QUALITY_DAY, {"days": days}):
        row = acc.setdefault(
            (r.project_id, r.day),
            {"accepted": 0, "rejected": 0, "needs_edits": 0, "reasons": defaultdict(int), "billable": 0, "audited": 0},
        )
        n = int(r.n)
        if r.type == ACCEPTED:
            row["accepted"] += n
        else:
            row["needs_edits" if r.verdict == "needs_edits" else "rejected"] += n
            row["reasons"][r.reason or "unknown"] += n
            row["billable"] += n if r.billable else 0
        row["audited"] += n if r.audited else 0
    for (project_id, day), row in acc.items():
        session.add(
            MartQualityDay(project_id=project_id, day=day, **{**row, "reasons": dict(row["reasons"])}, refreshed_at=now)
        )
    return len(acc)


def refresh_funnel_days(session: Session, days: list[date], now: datetime) -> int:
    session.execute(delete(MartFunnelDay).where(MartFunnelDay.day.in_(days)))
    acc: dict[tuple[uuid.UUID, date], dict[str, int]] = {}
    for r in session.execute(FUNNEL_DAY, {"days": days}):
        if r.stage in FUNNEL_STAGES:
            acc.setdefault((r.listing_id, r.day), dict.fromkeys(FUNNEL_STAGES, 0))[r.stage] += int(r.n)
    for (listing_id, day), counts in acc.items():
        session.add(MartFunnelDay(listing_id=listing_id, day=day, **counts, refreshed_at=now))
    return len(acc)


def refresh_worker_weeks(session: Session, weeks: list[date], now: datetime) -> int:
    session.execute(delete(MartWorkerWeek).where(MartWorkerWeek.week_start.in_(weeks)))
    acc: dict[tuple[uuid.UUID, date], dict[str, Any]] = {}
    for r in session.execute(WORKER_WEEK, {"weeks": weeks}):
        row = acc.setdefault(
            (uuid.UUID(str(r[0])), r.week),
            {"active_seconds": 0, "units_accepted": 0, "units_judged": 0, "earnings": defaultdict(lambda: ZERO)},
        )
        n = int(r.n)
        if r.type == "tracking.session.ended.v1":
            row["active_seconds"] += int(r.seconds)
            continue
        if r.role == "author":
            row["units_judged"] += n
            if r.type == ACCEPTED:
                row["units_accepted"] += n
                if r.currency:
                    row["earnings"][r.currency] += Decimal(r.pay)
        elif r.currency:
            row["earnings"][r.currency] += Decimal(r.pay)
    for (worker_id, week), row in acc.items():
        earnings = {c: str(v.quantize(Decimal("0.01"))) for c, v in sorted(row["earnings"].items())}
        session.add(
            MartWorkerWeek(worker_id=worker_id, week_start=week, **{**row, "earnings": earnings}, refreshed_at=now)
        )
    return len(acc)


def refresh_payout_windows(session: Session, windows: list[uuid.UUID], sla_days: int, now: datetime) -> int:
    session.execute(delete(MartPayoutWindow).where(MartPayoutWindow.window_id.in_(windows)))
    written = 0
    for window_id in windows:
        closed = session.scalar(
            select(Event)
            .where(Event.window_id == window_id, Event.type == "payout.window.closed.v1")
            .order_by(Event.time)
            .limit(1)
        )
        if closed is None:
            continue
        paid = session.execute(
            select(Event.time, Event.worker_id, Event.payload).where(
                Event.window_id == window_id, Event.type == "payout.paid.v1"
            )
        ).all()
        d = closed.payload
        ends = datetime.fromisoformat(d["ends_at"])
        paid_at = max((t for t, _, _ in paid), default=None)
        session.add(
            MartPayoutWindow(
                window_id=window_id,
                currency=d["currency"],
                starts_at=datetime.fromisoformat(d["starts_at"]),
                ends_at=ends,
                closed_at=closed.time,
                line_count=int(d["line_count"]),
                gross_total=Decimal(str(d["gross_total"])),
                held_total=Decimal(str(d["held_total"])),
                paid_total=sum((Decimal(str(p["amount"])) for _, _, p in paid), ZERO),
                workers_paid=len({w for _, w, _ in paid}),
                paid_at=paid_at,
                on_time=None if paid_at is None else paid_at <= ends + timedelta(days=sla_days),
                refreshed_at=now,
            )
        )
        written += 1
    return written


def refresh(session: Session, days: list[date], windows: list[uuid.UUID], sla_days: int, now: datetime) -> int:
    """One chunk of keys, every mart."""
    weeks = sorted({week_start(d) for d in days})
    written = refresh_project_days(session, days, now) if days else 0
    written += refresh_quality_days(session, days, now) if days else 0
    written += refresh_funnel_days(session, days, now) if days else 0
    written += refresh_worker_weeks(session, weeks, now) if weeks else 0
    written += refresh_payout_windows(session, windows, sla_days, now) if windows else 0
    return written


def refresh_marts(factory: sessionmaker[Session], now: datetime | None = None) -> int:
    """The five-minute job: recompute the keys whose events arrived since the cursor, 31 days per transaction,
    then move the cursor. Returns the rows written."""
    now = now or service.now_utc()
    with unit_of_work(factory) as session:
        cursor = service.read_control(session, "refresh")
        since = datetime.fromisoformat(cursor["last_at"]) if "last_at" in cursor else service.EPOCH
        until = session.scalar(select(func.max(Event.ingested_at)))
        if until is None or until <= since - OVERLAP:
            return 0
        days, windows = dirty_keys(session, since, until)
        baseline = service.latest_baseline(session)
        sla = baseline.payout_sla_days if baseline else 7
    written = 0
    for i, chunk in enumerate(chunks(days) if days else [[]]):
        with unit_of_work(factory) as session:
            written += refresh(session, chunk, windows if i == 0 else [], sla, now)
    with unit_of_work(factory) as session:
        service.write_control(session, "refresh", {"last_at": until.isoformat(), "days": len(days)}, now)
    if written:
        log.info("marts refreshed days=%d windows=%d rows=%d", len(days), len(windows), written)
    return written


def reset_cursor(session: Session, now: datetime) -> None:
    service.write_control(session, "refresh", {"last_at": service.EPOCH.isoformat()}, now)
