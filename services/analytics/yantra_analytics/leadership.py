"""The leadership page: the four numbers against their baselines, gross margin per accepted unit per project, and
the watch list. Each number says what it is made of (`basis`) and where it is explained (`href`, a destination of
the app). Every figure is read from the warehouse or a mart; nothing is typed by hand except the baselines."""

import statistics
import uuid
from collections import defaultdict
from collections.abc import Sequence
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from typing import Any
from zoneinfo import ZoneInfo

from sqlalchemy import Table, and_, func, select, text
from sqlalchemy.orm import Session

from yantra_analytics import service
from yantra_analytics.marts import ACCEPTED, FUNNEL_STAGES, REJECTED, week_start
from yantra_analytics.models import (
    Baseline,
    DimBatch,
    Event,
    MartFunnelDay,
    MartPayoutWindow,
    MartProjectDay,
    MartWorkerWeek,
)
from yantra_analytics.schemas import (
    BaselineIn,
    FunnelOut,
    LeadershipOut,
    MarginRow,
    Tile,
    TrendDay,
    TrendOut,
    WorkforceOut,
    WorkforceRow,
)

ZERO = Decimal("0")
CENTS = Decimal("0.01")
RATIO = Decimal("0.0001")
IST = ZoneInfo("Asia/Kolkata")


def _q(value: Decimal | None, places: Decimal = CENTS) -> str | None:
    return None if value is None else str(value.quantize(places))


def _ratio(num: int, den: int) -> Decimal | None:
    return (Decimal(num) / Decimal(den)).quantize(RATIO) if den else None


def _settings(baseline: Baseline | None) -> BaselineIn:
    """The constants the numbers need: the latest baseline's, or the defaults until one is set."""
    return BaselineIn.model_validate(baseline, from_attributes=True) if baseline else BaselineIn()


# ---------- the four numbers ----------


def days_to_staff(session: Session, since: datetime, staffing_workers: int) -> tuple[Decimal | None, dict[str, Any]]:
    """Per batch published in the window: days from publication until its K-th distinct worker first claimed
    (K = the baseline's staffing size, or the batch's unit count when smaller). The median over batches that got
    there; the others are pending."""
    batches = session.execute(
        select(DimBatch.batch_id, DimBatch.published_at, DimBatch.unit_count).where(DimBatch.published_at >= since)
    ).all()
    if not batches:
        return None, {"batches": 0, "reached": 0, "pending": 0, "staffing_workers": staffing_workers}
    firsts = session.execute(
        text(
            """
            select coalesce(e.batch_id, u.batch_id) as batch_id, e.worker_id, min(e.time) as first
            from analytics.event e left join analytics.dim_unit u on u.unit_id = e.unit_id
            where e.type = 'work.unit.claimed.v1' and e.worker_id is not null
            group by 1, 2
            """
        )
    ).all()
    by_batch: dict[uuid.UUID, list[datetime]] = defaultdict(list)
    for b, _, first in firsts:
        if b is not None:
            by_batch[b].append(first)
    spans = []
    for batch_id, published_at, unit_count in batches:
        k = min(staffing_workers, unit_count or staffing_workers)
        times = sorted(by_batch.get(batch_id, []))
        if len(times) >= k:
            spans.append(Decimal((times[k - 1] - published_at).total_seconds()) / Decimal(86400))
    value = Decimal(statistics.median(spans)).quantize(CENTS) if spans else None
    basis = {
        "batches": len(batches),
        "reached": len(spans),
        "pending": len(batches) - len(spans),
        "staffing_workers": staffing_workers,
    }
    return value, basis


def eligible_workers(session: Session) -> set[uuid.UUID]:
    rows = session.scalars(
        select(Event.worker_id).where(Event.type == "worker.eligible.v1", Event.worker_id.is_not(None)).distinct()
    ).all()
    return {w for w in rows if w is not None}


def idle_cost(session: Session, now: datetime, cfg: BaselineIn) -> tuple[Decimal, dict[str, Any]]:
    """Eligible workers with no accepted unit in the last seven days, priced at the retainer-equivalent the
    baseline sets (hourly cost times hours a week). The bench pays nothing for idle time; this is what it would."""
    eligible = eligible_workers(session)
    active = set(
        session.scalars(
            select(Event.worker_id).where(Event.type == ACCEPTED, Event.time >= now - timedelta(days=7)).distinct()
        ).all()
    )
    idle = len(eligible - active)
    value = (Decimal(idle) * cfg.idle_hourly_cost * cfg.idle_hours_per_week).quantize(CENTS)
    return value, {"eligible": len(eligible), "idle": idle, "hourly_cost": str(cfg.idle_hourly_cost)}


def first_pass(session: Session, since: datetime) -> tuple[Decimal | None, dict[str, Any]]:
    """Units whose first verdict fell in the window, and how many of those were accepts."""
    row = session.execute(
        text(
            f"""
            select count(*) as judged, count(*) filter (where type = '{ACCEPTED}') as accepted from (
                select distinct on (unit_id) unit_id, type, time from analytics.event
                where type in ('{ACCEPTED}', '{REJECTED}') and unit_id is not null
                order by unit_id, time, id
            ) first where time >= :since
            """
        ),
        {"since": since},
    ).one()
    return _ratio(int(row.accepted), int(row.judged)), {"judged": int(row.judged), "accepted": int(row.accepted)}


def cost_per_unit(session: Session, since: datetime, cfg: BaselineIn) -> tuple[Decimal | None, dict[str, Any]]:
    """(pay + review + audit + rail fees + levy) over accepted units, in the baseline's currency. Rail fee and levy
    rate come from the baseline until an event carries them."""
    row = session.execute(
        text(
            f"""
            select
                count(*) filter (where e.type = '{ACCEPTED}') as accepted,
                coalesce(sum(b.unit_pay) filter (where e.type = '{ACCEPTED}'), 0) as pay,
                coalesce(sum(b.review_pay), 0) as review,
                coalesce(sum(b.review_pay) filter (where e.payload->>'auditor_id' is not null), 0) as audit
            from analytics.event e
            left join analytics.dim_unit u on u.unit_id = e.unit_id
            join analytics.dim_batch b on b.batch_id = coalesce(e.batch_id, u.batch_id)
            where e.type in ('{ACCEPTED}', '{REJECTED}') and e.time >= :since and b.currency = :currency
            """
        ),
        {"since": since, "currency": cfg.currency},
    ).one()
    payouts = session.scalar(
        select(func.count()).where(
            Event.type == "payout.paid.v1",
            Event.time >= since,
            Event.payload["currency"].astext == cfg.currency,
        )
    )
    pay, review, audit = Decimal(row.pay), Decimal(row.review), Decimal(row.audit)
    rail = cfg.rail_fee_per_payout * int(payouts or 0)
    levy = (cfg.levy_rate * pay).quantize(CENTS)
    total = pay + review + audit + rail + levy
    accepted = int(row.accepted)
    value = (total / accepted).quantize(CENTS) if accepted else None
    basis = {
        "accepted": accepted,
        "pay": _q(pay),
        "review": _q(review),
        "audit": _q(audit),
        "rail_fees": _q(rail),
        "levy": _q(levy),
        "payouts": int(payouts or 0),
    }
    return value, basis


def margins(session: Session, since: date) -> list[MarginRow]:
    rows = session.execute(
        select(
            MartProjectDay.project_id,
            MartProjectDay.currency,
            func.sum(MartProjectDay.units_accepted),
            func.sum(MartProjectDay.price),
            func.sum(MartProjectDay.pay),
            func.sum(MartProjectDay.review_cost),
            func.sum(MartProjectDay.audit_cost),
            func.sum(MartProjectDay.margin),
        )
        .where(MartProjectDay.day >= since)
        .group_by(MartProjectDay.project_id, MartProjectDay.currency)
        .order_by(func.sum(MartProjectDay.margin).desc(), MartProjectDay.project_id)
    ).all()
    out = []
    for project_id, currency, accepted, price, pay, review, audit, margin in rows:
        n = int(accepted or 0)
        out.append(
            MarginRow(
                project_id=project_id,
                currency=currency,
                accepted=n,
                price=str(Decimal(price).quantize(CENTS)),
                pay=str(Decimal(pay).quantize(CENTS)),
                review=str(Decimal(review).quantize(CENTS)),
                audit=str(Decimal(audit).quantize(CENTS)),
                margin=str(Decimal(margin).quantize(CENTS)),
                margin_per_unit=_q(Decimal(margin) / n) if n else None,
                margin_fraction=_q(Decimal(margin) / Decimal(price), RATIO) if price else None,
            )
        )
    return out


# ---------- the watch list ----------


def count_dead(session: Session, dead_tables: Sequence[Table]) -> int:
    return sum(int(session.scalar(select(func.count()).select_from(t)) or 0) for t in dead_tables)


def watch(session: Session, since: datetime, dead_tables: Sequence[Table], eligible: int) -> list[Tile]:
    windows = (
        session.execute(
            select(MartPayoutWindow.on_time).where(
                MartPayoutWindow.paid_at >= since, MartPayoutWindow.on_time.is_not(None)
            )
        )
        .scalars()
        .all()
    )
    on_time = sum(1 for w in windows if w)
    upheld = session.scalar(select(func.count()).where(Event.type == "tracking.anomaly.upheld.v1", Event.time >= since))
    manual_holds = session.scalar(
        select(func.count()).where(
            Event.type == "payout.hold.set.v1",
            Event.time >= since,
            Event.payload["source"].astext == "manual",
            Event.payload["has_reason"].astext == "true",  # the reason's text is never stored (minimise.py)
        )
    )
    integrity = int(upheld or 0) + int(manual_holds or 0)
    dead = count_dead(session, dead_tables)
    deltas = int(
        session.scalar(select(func.count()).where(Event.type == "payout.reconciliation.delta.v1", Event.time >= since))
        or 0
    )
    return [
        Tile(
            key="on_time_payout",
            label="Pay windows paid on time",
            value=_q(_ratio(on_time, len(windows)), RATIO),
            baseline="1.0000",
            unit="ratio",
            better="higher",
            basis={"windows": len(windows), "on_time": on_time},
            href="finance",
        ),
        Tile(
            key="fraud_per_1000",
            label="Integrity cases per 1,000 eligible workers",
            value=_q(Decimal(integrity * 1000) / eligible) if eligible else None,
            baseline=None,
            unit="per_1000",
            better="lower",
            basis={"upheld_anomalies": int(upheld or 0), "manual_holds": int(manual_holds or 0), "eligible": eligible},
            href="quality",
        ),
        Tile(
            key="incidents",
            label="Incidents waiting",
            value=str(dead + deltas),
            baseline="0",
            unit="count",
            better="lower",
            basis={"dead_letters": dead, "reconciliation_deltas": deltas},
            href="system",
            note="Dead letters counted in the work deployable; payout's own are on its System tab.",
        ),
    ]


def leadership(session: Session, now: datetime, days: int, dead_tables: Sequence[Table]) -> LeadershipOut:
    baseline = service.latest_baseline(session)
    cfg = _settings(baseline)
    since = now - timedelta(days=days)
    staff, staff_basis = days_to_staff(session, since, cfg.staffing_workers)
    idle, idle_basis = idle_cost(session, now, cfg)
    fp, fp_basis = first_pass(session, since)
    cpu, cpu_basis = cost_per_unit(session, since, cfg)
    numbers = [
        Tile(
            key="days_to_staff",
            label="Days to staff a batch",
            value=_q(staff),
            baseline=_q(cfg.days_to_staff),
            unit="days",
            better="lower",
            basis=staff_basis,
            href="projects",
        ),
        Tile(
            key="idle_cost",
            label="Idle bench cost a week",
            value=_q(idle),
            baseline=_q(cfg.idle_cost_weekly),
            unit="money",
            better="lower",
            currency=cfg.currency,
            basis=idle_basis,
            href="workers",
            note="What the idle bench would cost on a retainer; the bench pays nothing for idle time.",
        ),
        Tile(
            key="first_pass_acceptance",
            label="First-pass acceptance",
            value=_q(fp, RATIO),
            baseline=_q(cfg.first_pass_acceptance, RATIO),
            unit="ratio",
            better="higher",
            basis=fp_basis,
            href="quality",
        ),
        Tile(
            key="cost_per_accepted_unit",
            label="Cost per accepted unit",
            value=_q(cpu),
            baseline=_q(cfg.cost_per_accepted_unit),
            unit="money",
            better="lower",
            currency=cfg.currency,
            basis=cpu_basis,
            href="finance",
        ),
    ]
    return LeadershipOut(
        as_of=now,
        window_days=days,
        currency=cfg.currency,
        baseline_set_at=baseline.set_at if baseline else None,
        numbers=numbers,
        margin=margins(session, (now - timedelta(days=days)).date()),
        watch=watch(session, since, dead_tables, int(idle_basis["eligible"])),
    )


# ---------- the drill-downs ----------


def trend(session: Session, project_id: uuid.UUID, today: date, days: int) -> TrendOut:
    """Day by day for one project, zero-filled, in the project's first currency."""
    start = today - timedelta(days=days - 1)
    rows = session.scalars(
        select(MartProjectDay)
        .where(MartProjectDay.project_id == project_id, MartProjectDay.day >= start)
        .order_by(MartProjectDay.currency, MartProjectDay.day)
    ).all()
    currency = rows[0].currency if rows else None
    by_day = {r.day: r for r in rows if r.currency == currency}
    out = []
    for i in range(days):
        d = start + timedelta(days=i)
        r = by_day.get(d)
        out.append(
            TrendDay(
                day=d,
                published=r.units_published if r else 0,
                claimed=r.units_claimed if r else 0,
                submitted=r.units_submitted if r else 0,
                accepted=r.units_accepted if r else 0,
                rejected=r.units_rejected if r else 0,
                first_pass_rate=_q(_ratio(r.first_pass_num, r.first_pass_den), RATIO) if r else None,
                pay=str((r.pay if r else ZERO).quantize(CENTS)),
                price=str((r.price if r else ZERO).quantize(CENTS)),
                review_cost=str(((r.review_cost + r.audit_cost) if r else ZERO).quantize(CENTS)),
                margin=str((r.margin if r else ZERO).quantize(CENTS)),
            )
        )
    return TrendOut(project_id=project_id, currency=currency, days=out)


FALLBACK_STAGES = ["offered", "rejected", "accepted"]


def funnel(session: Session, listing_id: uuid.UUID | None, today: date, days: int) -> FunnelOut:
    """From talent's `application.moved` events when they exist; otherwise the three stages the decision and
    acceptance events tell."""
    start = today - timedelta(days=days - 1)
    q = select(MartFunnelDay).where(MartFunnelDay.day >= start).order_by(MartFunnelDay.day)
    if listing_id is not None:
        q = q.where(MartFunnelDay.listing_id == listing_id)
    rows = session.scalars(q).all()
    if rows:
        stages = {s: sum(getattr(r, s) for r in rows) for s in FUNNEL_STAGES}
        by_day: dict[date, dict[str, int]] = defaultdict(lambda: dict.fromkeys(FUNNEL_STAGES, 0))
        for r in rows:
            for s in FUNNEL_STAGES:
                by_day[r.day][s] += getattr(r, s)
        return FunnelOut(
            listing_id=listing_id,
            window_days=days,
            stages_available=list(FUNNEL_STAGES),
            stages=stages,
            by_day=[{"day": d.isoformat(), **c} for d, c in sorted(by_day.items())],
        )
    conds = [Event.time >= datetime.combine(start, time(0), tzinfo=IST)]
    if listing_id is not None:
        conds.append(Event.listing_id == listing_id)
    decisions = session.execute(
        select(Event.payload["decision"].astext, func.count())
        .where(Event.type == "talent.application.decided.v1", and_(*conds))
        .group_by(text("1"))  # the payload path once, by position: its parameter would not match twice
    ).tuples()
    decided = {str(k): int(v) for k, v in decisions}
    accepted = session.scalar(select(func.count()).where(Event.type == "talent.offer.accepted.v1", and_(*conds)))
    stages = {
        "offered": int(decided.get("offer", 0)),
        "rejected": int(decided.get("reject", 0)),
        "accepted": int(accepted or 0),
    }
    return FunnelOut(
        listing_id=listing_id, window_days=days, stages_available=FALLBACK_STAGES, stages=stages, by_day=[]
    )


def workforce(session: Session, week: date) -> WorkforceOut:
    start = week_start(week)
    rows = session.scalars(
        select(MartWorkerWeek).where(MartWorkerWeek.week_start == start).order_by(MartWorkerWeek.units_accepted.desc())
    ).all()
    workers = [
        WorkforceRow(
            worker_id=r.worker_id,
            active_hours=str((Decimal(r.active_seconds) / 3600).quantize(CENTS)),
            units_accepted=r.units_accepted,
            units_judged=r.units_judged,
            acceptance_rate=_q(_ratio(r.units_accepted, r.units_judged), RATIO),
            earnings=r.earnings,
        )
        for r in rows
    ]
    earnings: dict[str, Decimal] = defaultdict(lambda: ZERO)
    for r in rows:
        for c, v in r.earnings.items():
            earnings[c] += Decimal(v)
    totals = {
        "workers": len(rows),
        "active_hours": str((Decimal(sum(r.active_seconds for r in rows)) / 3600).quantize(CENTS)),
        "units_accepted": sum(r.units_accepted for r in rows),
        "earnings": {c: str(v.quantize(CENTS)) for c, v in sorted(earnings.items())},
    }
    return WorkforceOut(week_start=start, workers=workers, totals=totals)
