import uuid
from datetime import timedelta
from decimal import Decimal

from yantra_analytics import leadership, marts, service
from yantra_analytics.models import DEAD
from yantra_analytics.schemas import BaselineIn

from .conftest import NOW, ids
from .test_marts import a_day


def tiles(out):
    return {t.key: t for t in [*out.numbers, *out.watch]}


def test_with_no_data_and_no_baseline_every_number_says_so(session):
    out = leadership.leadership(session, NOW, 30, [DEAD])
    t = tiles(out)
    assert out.baseline_set_at is None and out.currency == "INR" and out.margin == []
    assert t["days_to_staff"].value is None and t["days_to_staff"].basis["batches"] == 0
    assert t["idle_cost"].value == "0.00" and t["first_pass_acceptance"].value is None
    assert t["cost_per_accepted_unit"].value is None and t["on_time_payout"].value is None
    assert t["fraud_per_1000"].value is None and t["incidents"].value == "0"
    assert [x.href for x in out.numbers] == ["projects", "workers", "quality", "finance"]


def test_the_four_numbers_from_a_coherent_day(session, wh, factory):
    project, batch = ids(2)
    who = a_day(wh, project, batch)
    for w in (who["w1"], who["w2"], idle := uuid.uuid4()):
        wh.put(
            "worker.eligible.v1",
            NOW - timedelta(days=20),
            {"worker_id": w, "legal_name_hash": "h", "pan_last4": "1234"},
        )
    wh.put(
        "payout.paid.v1",
        NOW,
        {"window_id": uuid.uuid4(), "worker_id": who["w1"], "amount": "40", "currency": "INR", "rail_reference": "r"},
    )
    service.set_baseline(
        session,
        BaselineIn(
            days_to_staff=Decimal("3"),
            idle_hourly_cost=Decimal("100"),
            idle_hours_per_week=10,
            staffing_workers=2,
            rail_fee_per_payout=Decimal("3"),
            levy_rate=Decimal("0.01"),
            first_pass_acceptance=Decimal("0.6"),
        ),
        uuid.uuid4(),
        NOW - timedelta(days=1),
    )
    session.commit()
    marts.refresh_marts(factory, NOW)
    out = leadership.leadership(session, NOW + timedelta(hours=1), 30, [DEAD])
    t = tiles(out)
    # both workers claimed at publication time: the second distinct claimer arrived after 0 days
    assert t["days_to_staff"].value == "0.00" and t["days_to_staff"].baseline == "3.00"
    assert t["days_to_staff"].basis == {"batches": 1, "reached": 1, "pending": 0, "staffing_workers": 2}
    assert t["idle_cost"].value == "1000.00" and t["idle_cost"].basis["idle"] == 1  # `idle` never accepted anything
    assert t["first_pass_acceptance"].value == "0.5000" and t["first_pass_acceptance"].baseline == "0.6000"
    # pay 60 + review 25 + audit 5 + one payout at 3 + levy 0.60 = 93.60 over 3 accepted
    assert t["cost_per_accepted_unit"].value == "31.20" and t["cost_per_accepted_unit"].basis["payouts"] == 1
    [m] = out.margin
    assert (m.project_id, m.accepted, m.margin, m.margin_per_unit, m.margin_fraction) == (
        project,
        3,
        "60.00",
        "20.00",
        "0.4000",
    )
    assert out.baseline_set_at is not None and idle not in (who["w1"], who["w2"])


def test_a_batch_not_yet_staffed_is_pending(session, wh):
    batch, project, w = ids(3)
    wh.published(NOW - timedelta(days=2), batch, project, units=10)
    wh.claimed(NOW - timedelta(days=1), uuid.uuid4(), w, batch)
    wh.claimed(NOW, uuid.uuid4(), uuid.uuid4())  # a claim whose batch is not known
    value, basis = leadership.days_to_staff(session, NOW - timedelta(days=30), 5)
    assert value is None and basis == {"batches": 1, "reached": 0, "pending": 1, "staffing_workers": 5}
    small = uuid.uuid4()
    wh.published(NOW - timedelta(days=2), small, project, units=1)
    wh.claimed(NOW - timedelta(hours=12), uuid.uuid4(), w, small)
    value, basis = leadership.days_to_staff(session, NOW - timedelta(days=30), 5)
    assert value == Decimal("1.50") and basis["reached"] == 1


def test_the_watch_list_counts_integrity_cases_and_incidents(session, wh):
    workers = ids(4)
    for w in workers:
        wh.put("worker.eligible.v1", NOW, {"worker_id": w, "legal_name_hash": "h", "pan_last4": "1"})
    wh.put(
        "tracking.anomaly.upheld.v1",
        NOW,
        {
            "anomaly_id": uuid.uuid4(),
            "worker_id": workers[0],
            "session_id": None,
            "kind": "duplicate_device",
            "decided_by": uuid.uuid4(),
        },
    )
    wh.put(
        "payout.hold.set.v1", NOW, {"worker_id": workers[1], "reason": "integrity", "until": None, "source": "manual"}
    )
    wh.put(
        "payout.hold.set.v1", NOW, {"worker_id": workers[0], "reason": "integrity", "until": None, "source": "anomaly"}
    )
    wh.put("payout.hold.set.v1", NOW, {"worker_id": workers[2], "reason": None, "until": None, "source": "manual"})
    wh.put("payout.reconciliation.delta.v1", NOW, {"window_id": uuid.uuid4(), "run_id": uuid.uuid4()})
    session.execute(
        DEAD.insert().values(id=uuid.uuid4(), consumer="c", deliveries=20, reason="r", raw=b"x", dead_at=NOW)
    )
    session.commit()
    t = tiles(leadership.leadership(session, NOW, 30, [DEAD]))
    assert t["fraud_per_1000"].value == "500.00" and t["fraud_per_1000"].basis["manual_holds"] == 1
    assert t["incidents"].value == "2" and t["incidents"].basis == {"dead_letters": 1, "reconciliation_deltas": 1}


def test_trend_is_zero_filled_in_the_projects_currency(session, wh, factory):
    project, batch = ids(2)
    a_day(wh, project, batch)
    session.commit()
    marts.refresh_marts(factory, NOW)
    out = leadership.trend(session, project, NOW.date(), 3)
    assert out.currency == "INR" and [d.day.isoformat() for d in out.days] == ["2026-11-02", "2026-11-03", "2026-11-04"]
    assert out.days[0].accepted == 0 and out.days[0].first_pass_rate is None and out.days[0].margin == "0.00"
    last = out.days[-1]
    assert (last.accepted, last.first_pass_rate, last.review_cost, last.margin) == (3, "0.5000", "30.00", "60.00")
    empty = leadership.trend(session, uuid.uuid4(), NOW.date(), 2)
    assert empty.currency is None and len(empty.days) == 2


def test_the_funnel_from_moves_or_from_decisions(session, wh, factory):
    listing = uuid.uuid4()
    for decision in ("offer", "offer", "reject"):
        wh.put(
            "talent.application.decided.v1",
            NOW,
            {
                "application_id": uuid.uuid4(),
                "listing_id": listing,
                "listing_title": "t",
                "worker_id": uuid.uuid4(),
                "decision": decision,
            },
        )
    wh.put(
        "talent.offer.accepted.v1",
        NOW,
        {"application_id": uuid.uuid4(), "listing_id": listing, "worker_id": uuid.uuid4(), "gate": None},
    )
    session.commit()
    fallback = leadership.funnel(session, listing, NOW.date(), 30)
    assert fallback.stages_available == ["offered", "rejected", "accepted"] and fallback.stages == {
        "offered": 2,
        "rejected": 1,
        "accepted": 1,
    }
    assert leadership.funnel(session, None, NOW.date(), 30).stages["offered"] == 2
    wh.put(
        "talent.application.moved.v1",
        NOW,
        {
            "application_id": uuid.uuid4(),
            "listing_id": listing,
            "worker_id": uuid.uuid4(),
            "from_status": None,
            "to_status": "applied",
        },
    )
    session.commit()
    marts.refresh_marts(factory, NOW)
    full = leadership.funnel(session, listing, NOW.date(), 30)
    assert full.stages["applied"] == 1 and len(full.stages_available) == 9 and full.by_day[0]["day"] == "2026-11-04"
    assert leadership.funnel(session, None, NOW.date(), 30).stages["applied"] == 1


def test_workforce_lists_the_weeks_workers_with_totals(session, wh, factory):
    project, batch = ids(2)
    who = a_day(wh, project, batch)
    wh.put(
        "tracking.session.ended.v1", NOW, {"session_id": uuid.uuid4(), "worker_id": who["w1"], "active_seconds": 5400}
    )
    session.commit()
    marts.refresh_marts(factory, NOW)
    out = leadership.workforce(session, NOW.date())
    assert out.week_start.isoformat() == "2026-11-02"
    first = out.workers[0]
    assert (first.worker_id, first.active_hours, first.acceptance_rate) == (who["w1"], "1.50", "1.0000")
    assert out.totals["units_accepted"] == 3 and out.totals["earnings"] == {"INR": "90.00"}
    assert leadership.workforce(session, NOW.date() - timedelta(days=30)).workers == []
