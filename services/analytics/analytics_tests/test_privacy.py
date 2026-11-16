"""What the warehouse keeps of personal data: minimised payloads, pseudonyms for erased workers, a retention."""

import json
import uuid
from datetime import timedelta

from alembic import command
from alembic.config import Config
from sqlalchemy import func, select, text

from yantra_analytics import marts, minimise, service
from yantra_analytics.models import ErasedWorker, Event, MartFunnelDay, MartWorkerWeek
from yantra_analytics.testing import ALEMBIC_INI

from .conftest import NOW, ids

NAME = "Asha Verma"


def _all_text(session) -> str:
    rows = session.execute(select(Event.worker_id, Event.subject, Event.payload)).all()
    return json.dumps([[str(w), s, p] for w, s, p in rows])


def test_names_answers_and_free_text_never_land(session, wh):
    worker, unit, batch, project = ids(4)
    wh.put("talent.person.seen.v1", NOW, {"id": worker, "name": NAME, "kind": "worker"})
    wh.put(
        "work.unit.submitted.v1",
        NOW,
        {
            "unit_id": unit,
            "batch_id": batch,
            "claim_id": uuid.uuid4(),
            "submission_id": uuid.uuid4(),
            "worker_id": worker,
            "rubric_version": "v1",
            "payload": {"text": "the source sentence"},
            "answer": {"text": "the worker's answer"},
            "project_id": project,
            "sensitive": True,
        },
    )
    wh.put("worker.eligible.v1", NOW, {"worker_id": worker, "legal_name_hash": "ab" * 32, "pan_last4": "234F"})
    wh.put(
        "payout.paid.v1",
        NOW,
        {
            "window_id": uuid.uuid4(),
            "worker_id": worker,
            "amount": "10",
            "currency": "INR",
            "rail_reference": "r",
            "utr": "UTR123",
        },
    )
    wh.put(
        "tracking.anomaly.flagged.v1",
        NOW,
        {
            "anomaly_id": uuid.uuid4(),
            "worker_id": worker,
            "session_id": None,
            "kind": "duplicate_device",
            "detail": {"device_hash": "device-secret-1"},
        },
    )
    session.commit()
    stored = _all_text(session)
    for secret in (NAME, "the source sentence", "the worker's answer", "234F", "UTR123", "device-secret-1", "ab" * 32):
        assert secret not in stored
    seen = session.scalar(select(Event).where(Event.type == "talent.person.seen.v1"))
    assert seen.payload == {"id": str(worker), "kind": "worker"}
    submitted = session.scalar(select(Event).where(Event.type == "work.unit.submitted.v1"))
    assert submitted.payload["sensitive"] is True and "payload" not in submitted.payload
    assert (submitted.unit_id, submitted.batch_id, submitted.project_id) == (unit, batch, project)


def test_a_reason_is_kept_only_as_present_or_absent_and_unknown_types_keep_their_ids():
    assert minimise.minimise(
        "payout.hold.set.v1", {"worker_id": "w", "reason": "said rude things", "until": None, "source": "manual"}
    ) == {
        "worker_id": "w",
        "until": None,
        "source": "manual",
        "has_reason": True,
    }
    assert minimise.minimise("payout.hold.set.v1", {"reason": ""})["has_reason"] is False
    a = str(uuid.uuid4())
    assert minimise.minimise("some.future.v9", {"id": a, "worker_id": "nope", "x_id": 5, "note": "hi", "y_id": a}) == {
        "id": a,
        "y_id": a,
    }
    assert minimise.minimise("x.y.v1", {"z_id": uuid.UUID(a)}) == {"z_id": uuid.UUID(a)}


def test_the_funnel_and_every_field_a_mart_reads_survive(session, wh, factory):
    listing, app, worker = ids(3)
    for frm, to in ((None, "applied"), ("applied", "screening"), ("screening", "offered")):
        wh.put(
            "talent.application.moved.v1",
            NOW,
            {"application_id": app, "listing_id": listing, "worker_id": worker, "from_status": frm, "to_status": to},
        )
    session.commit()
    moved = session.scalars(select(Event.payload).where(Event.type == "talent.application.moved.v1")).all()
    assert {p["to_status"] for p in moved} == {"applied", "screening", "offered"}
    assert {p["from_status"] for p in moved} == {None, "applied", "screening"}
    marts.refresh_marts(factory, NOW)
    with factory() as s:
        row = s.scalar(select(MartFunnelDay))
        assert (row.applied, row.screening, row.offered) == (1, 1, 1)


def test_an_erased_worker_is_a_pseudonym_everywhere_and_the_marts_stay_whole(session, wh, factory):
    worker, other, reviewer, unit, batch, project = ids(6)
    wh.published(NOW, batch, project)
    wh.verdict(NOW, unit, batch, worker, reviewer)
    wh.verdict(NOW, uuid.uuid4(), batch, other, worker)  # the erased worker reviewed someone else's unit
    wh.put("talent.person.seen.v1", NOW, {"id": worker, "name": NAME, "kind": "worker"})
    wh.put("talent.person.seen.v1", NOW, {"id": other, "name": "B", "kind": "worker"})
    session.commit()
    marts.refresh_marts(factory, NOW)
    before = {
        "events": session.scalar(select(func.count()).select_from(Event)),
        "weeks": sorted(json.dumps([w.units_accepted, w.earnings]) for w in session.scalars(select(MartWorkerWeek))),
    }
    erased = wh.put("worker.erasure.completed.v1", NOW + timedelta(hours=1), {"worker_id": worker})
    session.commit()
    stored = _all_text(session)
    assert str(worker) not in stored
    pseudonym = session.scalar(select(ErasedWorker.pseudonym))
    assert session.scalar(select(func.count()).where(Event.worker_id == pseudonym)) == 2  # their verdict, the erasure
    seen = session.scalar(
        select(Event.payload).where(Event.type == "talent.person.seen.v1", Event.payload["id"].astext == str(pseudonym))
    )
    assert seen == {"id": str(pseudonym), "kind": "worker"}
    assert session.scalar(select(func.count()).select_from(Event)) == before["events"] + 1
    weeks = list(session.scalars(select(MartWorkerWeek)))
    assert sorted(json.dumps([w.units_accepted, w.earnings]) for w in weeks) == before["weeks"]
    assert worker not in {w.worker_id for w in weeks} and pseudonym in {w.worker_id for w in weeks}
    assert other in {w.worker_id for w in weeks}
    # a later event (a payout after the erasure) and a redelivered erasure land under the same pseudonym
    wh.put(
        "payout.paid.v1",
        NOW + timedelta(days=1),
        {"window_id": uuid.uuid4(), "worker_id": worker, "amount": "1", "currency": "INR"},
    )
    wh.put("worker.erasure.completed.v1", NOW + timedelta(days=2), erased)
    session.commit()
    assert session.scalar(select(func.count()).select_from(ErasedWorker)) == 1
    assert str(worker) not in _all_text(session)
    paid = session.scalar(select(Event).where(Event.type == "payout.paid.v1"))
    assert paid.worker_id == pseudonym and paid.payload["worker_id"] == str(pseudonym)
    # an erasure event without a well-formed id is stored and erases nothing
    wh.put("worker.erasure.completed.v1", NOW, {"worker_id": "nope"})
    session.commit()
    assert session.scalar(select(func.count()).select_from(ErasedWorker)) == 1


def test_events_past_the_retention_are_pruned_in_chunks(session, wh, monkeypatch):
    worker = uuid.uuid4()
    for days in (401, 402, 403, 10):
        wh.put("worker.eligible.v1", NOW - timedelta(days=days), {"worker_id": worker})
    session.commit()
    monkeypatch.setattr(service, "PRUNE_CHUNK", 1)
    monkeypatch.setattr(service, "PRUNE_CHUNKS", 2)
    assert service.prune_events(session, NOW, 400) == 2  # bounded: two chunks of one per pass
    assert service.prune_events(session, NOW, 400) == 1
    assert service.prune_events(session, NOW, 400) == 0
    session.commit()
    assert session.scalar(select(func.count()).select_from(Event)) == 1


def test_the_migration_minimises_payloads_already_stored(engine):
    cfg = Config(str(ALEMBIC_INI))
    cfg.attributes["url"] = engine.url.render_as_string(hide_password=False)
    command.downgrade(cfg, "0001")
    try:
        rows = [
            ("talent.person.seen.v1", {"id": str(uuid.uuid4()), "name": NAME, "kind": "worker"}),
            ("payout.hold.set.v1", {"worker_id": str(uuid.uuid4()), "reason": "free text", "source": "manual"}),
            ("payout.hold.set.v1", {"worker_id": str(uuid.uuid4()), "reason": None, "source": "manual"}),
            ("some.future.v9", {"x_id": str(uuid.uuid4()), "y_id": "nope", "name": NAME, "n": 1}),
        ]
        with engine.begin() as c:
            for type_, payload in rows:
                c.execute(
                    text(
                        "insert into analytics.event (id, type, subject, time, payload, ingested_at) "
                        "values (:id, :type, 's', now(), cast(:payload as jsonb), now())"
                    ),
                    {"id": uuid.uuid4(), "type": type_, "payload": json.dumps(payload)},
                )
    finally:
        command.upgrade(cfg, "head")
    with engine.begin() as c:
        stored = dict(c.execute(text("select payload::text, type from analytics.event")).all())
        c.execute(text("truncate analytics.event"))
    assert NAME not in "".join(stored) and "free text" not in "".join(stored)
    payloads = [json.loads(p) for p in stored]
    assert [set(p) for p in payloads if "kind" in p] == [{"id", "kind"}]
    holds = sorted(p["has_reason"] for p in payloads if "has_reason" in p)
    assert holds == [False, True]
    [future] = [p for p in payloads if "x_id" in p]
    assert set(future) == {"x_id"}
