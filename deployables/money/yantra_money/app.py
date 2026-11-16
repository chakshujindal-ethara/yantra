"""The `money` deployable: the payout module alone, so money code ships on its own release train.
Run locally: YANTRA_DATABASE_URL=... uv run uvicorn --factory yantra_money.app:default_app --port 8082
The event side: python -m yantra_money.events"""

from fastapi import FastAPI
from sqlalchemy.orm import Session, sessionmaker

from yantra_common.app import base_app
from yantra_common.boot import boot
from yantra_common.config import settings
from yantra_common.db import make_engine, make_session_factory
from yantra_common.deadletters import dead_letter_router, handlers_of, jobs_router
from yantra_money.events import consumers
from yantra_payout.config import PayoutSettings, payout_settings
from yantra_payout.models import CONSUMED, DEAD, JOB_LEASE, OUTBOX
from yantra_payout.rails import Rail, select_rail
from yantra_payout.router import router as payout_router


def create_app(
    factory: sessionmaker[Session],
    rate_limit_per_minute: int,
    max_body_bytes: int = 1 << 20,
    rail: Rail | None = None,
    config: PayoutSettings | None = None,
) -> FastAPI:
    """`rail` and `config` default to what `YANTRA_RAIL` and the payout settings name; tests pass their own."""
    config = config or payout_settings()
    operations = [
        dead_letter_router("/v1/payout/dead-letters", DEAD, CONSUMED, handlers_of(consumers(factory), "payout")),
        jobs_router("/v1/payout/jobs", JOB_LEASE),
    ]
    app = base_app(
        "Yantra money",
        factory,
        [payout_router, *operations],
        [OUTBOX],
        rate_limit_per_minute,
        max_body_bytes,
        process="money",
    )
    app.state.payout_settings = config
    app.state.rail = rail or select_rail(config)
    return app


def default_app() -> FastAPI:
    boot("money")
    s = settings()
    return create_app(make_session_factory(make_engine(str(s.database_url))), s.rate_limit_per_minute, s.max_body_bytes)
