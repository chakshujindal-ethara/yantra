"""The payout module's dead letters and jobs over HTTP, and the money events process's schedule."""

from datetime import timedelta

from fastapi.testclient import TestClient

from yantra_common.scheduler import At, register
from yantra_money.app import create_app
from yantra_money.events import build, jobs


def test_payout_dead_letters_jobs_and_schedule(factory):
    client = TestClient(create_app(factory, rate_limit_per_minute=1000))
    consumers, relays = build(factory, None)
    assert len(consumers) == 7 and len(relays) == 1
    assert {"worker.consent.withdrawn.v1", "worker.consent.given.v1"} <= {c.subject for c in consumers}
    schedule = {j.name: j for j in jobs(factory)}
    assert schedule["payout_prune"].at == At(3, 0)
    assert schedule["payout_dead_letter_alert"].every == timedelta(minutes=5)
    register(factory, list(schedule.values()))
    assert client.get("/v1/payout/dead-letters", headers={"X-Role": "admin"}).json() == []
    names = [j["name"] for j in client.get("/v1/payout/jobs", headers={"X-Role": "ops"}).json()]
    assert names == [
        "payout_account_validation_poll",
        "payout_dead_letter_alert",
        "payout_dispatch",
        "payout_prune",
        "payout_rail_poll",
        "payout_reconcile",
        "payout_window_close",
    ]
    assert client.get("/v1/payout/jobs", headers={"X-Role": "worker"}).status_code == 403
    assert schedule["payout_prune"].run() == 0 and schedule["payout_dead_letter_alert"].run() == 0
