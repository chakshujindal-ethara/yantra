import uuid
from datetime import date, timedelta
from decimal import Decimal

from sqlalchemy import select

from yantra_analytics import marts, service
from yantra_analytics.models import (
    MartFunnelDay,
    MartPayoutWindow,
    MartProjectDay,
    MartQualityDay,
    MartWorkerWeek,
)

from .conftest import NOW, ids


def a_day(wh, project, batch):
    """Four units: two accepted first time (one audited), one rejected then accepted, one rejected as needs-edits."""
    u1, u2, u3, u4, w1, w2, rev, aud = ids(8)
    wh.published(NOW, batch, project, units=4)
    for u, w in ((u1, w1), (u2, w1), (u3, w2), (u4, w2)):
        wh.claimed(NOW, u, w, batch)
        wh.submitted(NOW + timedelta(minutes=1), u, batch, w)
    wh.verdict(NOW + timedelta(minutes=2), u1, batch, w1, rev)
    wh.verdict(NOW + timedelta(minutes=2), u2, batch, w1, rev, auditor=aud)
    wh.verdict(
        NOW + timedelta(minutes=2), u3, batch, w2, rev, accept=False, reason="client_glossary_change", billable=True
    )
    wh.verdict(NOW + timedelta(minutes=3), u3, batch, w2, rev)
    wh.verdict(NOW + timedelta(minutes=2), u4, batch, w2, rev, accept=False, verdict="needs_edits", reason="incomplete")
    return {"w1": w1, "w2": w2, "rev": rev, "aud": aud}


def test_the_project_day_mirrors_payouts_margin_arithmetic(session, wh, factory):
    project, batch = ids(2)
    a_day(wh, project, batch)
    session.commit()
    assert marts.refresh_marts(factory, NOW) > 0
    session.expire_all()
    [row] = session.scalars(select(MartProjectDay)).all()
    assert (row.day, row.currency) == (date(2026, 11, 4), "INR")
    assert (row.units_published, row.units_claimed, row.units_submitted) == (4, 4, 4)
    assert (row.units_accepted, row.units_rejected, row.first_pass_num, row.first_pass_den) == (3, 2, 2, 4)
    # 3 accepts: pay 60, price 150; 5 verdicts reviewed at 5 = 25; one audited verdict = 5
    assert (row.pay, row.price, row.review_cost, row.audit_cost) == (Decimal(60), Decimal(150), Decimal(25), Decimal(5))
    assert row.margin == Decimal(60)


def test_quality_reasons_and_billable_rework(session, wh, factory):
    project, batch = ids(2)
    a_day(wh, project, batch)
    session.commit()
    marts.refresh_marts(factory, NOW)
    session.expire_all()
    [q] = session.scalars(select(MartQualityDay)).all()
    assert (q.accepted, q.rejected, q.needs_edits, q.billable, q.audited) == (3, 1, 1, 1, 1)
    assert q.reasons == {"client_glossary_change": 1, "incomplete": 1}


def test_a_worker_week_counts_authorship_reviews_and_tracked_hours(session, wh, factory):
    project, batch = ids(2)
    who = a_day(wh, project, batch)
    wh.put(
        "tracking.session.ended.v1", NOW, {"session_id": uuid.uuid4(), "worker_id": who["w1"], "active_seconds": 5400}
    )
    session.commit()
    marts.refresh_marts(factory, NOW)
    session.expire_all()
    rows = {r.worker_id: r for r in session.scalars(select(MartWorkerWeek)).all()}
    assert all(r.week_start == date(2026, 11, 2) for r in rows.values())
    w1, w2, rev, aud = rows[who["w1"]], rows[who["w2"]], rows[who["rev"]], rows[who["aud"]]
    assert (w1.active_seconds, w1.units_accepted, w1.units_judged, w1.earnings) == (5400, 2, 2, {"INR": "40.00"})
    assert (w2.units_accepted, w2.units_judged, w2.earnings) == (1, 3, {"INR": "20.00"})
    assert rev.earnings == {"INR": "25.00"} and aud.earnings == {"INR": "5.00"}


def test_the_funnel_counts_moves_by_their_target_stage(session, wh, factory):
    listing = uuid.uuid4()
    for to in ("applied", "applied", "screening", "offered", "accepted", "nonsense"):
        wh.put(
            "talent.application.moved.v1",
            NOW,
            {
                "application_id": uuid.uuid4(),
                "listing_id": listing,
                "worker_id": uuid.uuid4(),
                "from_status": None,
                "to_status": to,
            },
        )
    session.commit()
    marts.refresh_marts(factory, NOW)
    session.expire_all()
    [f] = session.scalars(select(MartFunnelDay)).all()
    assert (f.applied, f.screening, f.offered, f.accepted, f.rejected) == (2, 1, 1, 1, 0)


def test_a_pay_window_is_on_time_when_paid_within_the_sla(session, wh, factory):
    late, prompt, unpaid, w1, w2 = ids(5)
    ends = NOW - timedelta(days=10)
    for win in (late, prompt, unpaid):
        wh.put(
            "payout.window.closed.v1",
            NOW - timedelta(days=9),
            {
                "window_id": win,
                "starts_at": (ends - timedelta(days=7)).isoformat(),
                "ends_at": ends.isoformat(),
                "currency": "INR",
                "line_count": 2,
                "gross_total": "100",
                "held_total": "0",
            },
        )
    for w in (w1, w2):
        wh.put(
            "payout.paid.v1",
            ends + timedelta(days=3),
            {"window_id": prompt, "worker_id": w, "amount": "50", "currency": "INR", "rail_reference": "r"},
        )
    wh.put(
        "payout.paid.v1",
        ends + timedelta(days=9),
        {"window_id": late, "worker_id": w1, "amount": "100", "currency": "INR", "rail_reference": "r"},
    )
    wh.put(
        "payout.paid.v1",
        ends,
        {"window_id": uuid.uuid4(), "worker_id": w1, "amount": "1", "currency": "INR", "rail_reference": "r"},
    )
    session.commit()
    marts.refresh_marts(factory, NOW)
    session.expire_all()
    rows = {r.window_id: r for r in session.scalars(select(MartPayoutWindow)).all()}
    assert set(rows) == {late, prompt, unpaid}
    assert (rows[prompt].on_time, rows[prompt].paid_total, rows[prompt].workers_paid) == (True, Decimal(100), 2)
    assert rows[late].on_time is False and rows[unpaid].on_time is None and rows[unpaid].paid_at is None


def test_refresh_is_idempotent_and_only_touches_new_days(session, wh, factory):
    project, batch = ids(2)
    a_day(wh, project, batch)
    session.commit()
    marts.refresh_marts(factory, NOW)
    first = [(r.project_id, r.day, r.units_accepted, r.margin) for r in session.scalars(select(MartProjectDay))]
    assert marts.refresh_marts(factory, NOW) > 0  # the overlap re-reads the tail: same rows again
    session.expire_all()
    assert [(r.project_id, r.day, r.units_accepted, r.margin) for r in session.scalars(select(MartProjectDay))] == first
    cursor = service.read_control(session, "refresh")
    assert cursor["days"] == 1
    session.commit()
    with factory() as s:
        service.write_control(s, "refresh", {"last_at": (NOW + timedelta(days=400)).isoformat()}, NOW)
        s.commit()
    assert marts.refresh_marts(factory, NOW) == 0  # nothing ingested since the cursor


def test_an_empty_warehouse_refreshes_nothing(factory):
    assert marts.refresh_marts(factory) == 0


def test_an_ist_evening_lands_on_the_next_utc_days_date(session, wh, factory):
    project, batch = ids(2)
    evening = NOW.replace(hour=19)  # 00:30 IST on 5 Nov
    wh.published(evening, batch, project)
    session.commit()
    marts.refresh_marts(factory, NOW)
    session.expire_all()
    [row] = session.scalars(select(MartProjectDay)).all()
    assert row.day == date(2026, 11, 5)


def test_many_days_refresh_in_chunks(session, wh, factory):
    project, batch = ids(2)
    for d in range(40):
        wh.published(NOW - timedelta(days=d), batch, project, units=1)
    session.commit()
    marts.refresh_marts(factory, NOW)
    session.expire_all()
    assert len(session.scalars(select(MartProjectDay)).all()) == 40
    assert list(marts.chunks([date(2026, 1, 1)] * 5, 2)) == [[date(2026, 1, 1)] * 2] * 2 + [[date(2026, 1, 1)]]
