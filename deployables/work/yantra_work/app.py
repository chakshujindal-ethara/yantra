"""The `work` deployable: market, talent, assess, quality, notify, tracker and analytics in one process, each on its
own schema.
Run locally: YANTRA_DATABASE_URL=... uv run uvicorn --factory yantra_work.app:default_app --port 8081
The event side (outbox relays and consumers) is a separate process: python -m yantra_work.events"""

from collections.abc import Mapping

from fastapi import FastAPI
from sqlalchemy.orm import Session, sessionmaker

from yantra_analytics.consumers import AnyGeneration
from yantra_analytics.models import CONSUMED as ANALYTICS_CONSUMED
from yantra_analytics.models import DEAD as ANALYTICS_DEAD
from yantra_analytics.models import JOB_LEASE as ANALYTICS_LEASE
from yantra_analytics.router import router as analytics_router
from yantra_assess.config import AssessSettings
from yantra_assess.engine import Engine, select_engine
from yantra_assess.models import CONSUMED as ASSESS_CONSUMED
from yantra_assess.models import DEAD as ASSESS_DEAD
from yantra_assess.models import JOB_LEASE as ASSESS_LEASE
from yantra_assess.models import OUTBOX as ASSESS_OUTBOX
from yantra_assess.router import router as assess_router
from yantra_common.app import base_app
from yantra_common.boot import boot
from yantra_common.config import settings
from yantra_common.consumer import Handler
from yantra_common.db import make_engine, make_session_factory
from yantra_common.deadletters import dead_letter_router, handlers_of, jobs_router
from yantra_common.storage import Storage, storage_from_env
from yantra_market.models import CONSUMED as MARKET_CONSUMED
from yantra_market.models import DEAD as MARKET_DEAD
from yantra_market.models import JOB_LEASE as MARKET_LEASE
from yantra_market.models import OUTBOX as MARKET_OUTBOX
from yantra_market.router import router as market_router
from yantra_notify.models import CONSUMED as NOTIFY_CONSUMED
from yantra_notify.models import DEAD as NOTIFY_DEAD
from yantra_notify.models import JOB_LEASE as NOTIFY_LEASE
from yantra_notify.router import router as notify_router
from yantra_quality.models import CONSUMED as QUALITY_CONSUMED
from yantra_quality.models import DEAD as QUALITY_DEAD
from yantra_quality.models import JOB_LEASE as QUALITY_LEASE
from yantra_quality.models import OUTBOX as QUALITY_OUTBOX
from yantra_quality.router import router as quality_router
from yantra_talent.models import CONSUMED as TALENT_CONSUMED
from yantra_talent.models import DEAD as TALENT_DEAD
from yantra_talent.models import JOB_LEASE as TALENT_LEASE
from yantra_talent.models import OUTBOX as TALENT_OUTBOX
from yantra_talent.router import router as talent_router
from yantra_tracker.models import CONSUMED as TRACKER_CONSUMED
from yantra_tracker.models import DEAD as TRACKER_DEAD
from yantra_tracker.models import JOB_LEASE as TRACKER_LEASE
from yantra_tracker.models import OUTBOX as TRACKER_OUTBOX
from yantra_tracker.router import router as tracker_router
from yantra_work.attention import attention_router
from yantra_work.events import consumers

# module name, dead letters, consumed ids, job leases: what /v1/<module>/dead-letters and /jobs read
OPERATIONS = [
    ("market", MARKET_DEAD, MARKET_CONSUMED, MARKET_LEASE),
    ("talent", TALENT_DEAD, TALENT_CONSUMED, TALENT_LEASE),
    ("assess", ASSESS_DEAD, ASSESS_CONSUMED, ASSESS_LEASE),
    ("quality", QUALITY_DEAD, QUALITY_CONSUMED, QUALITY_LEASE),
    ("notify", NOTIFY_DEAD, NOTIFY_CONSUMED, NOTIFY_LEASE),
    ("tracker", TRACKER_DEAD, TRACKER_CONSUMED, TRACKER_LEASE),
    ("analytics", ANALYTICS_DEAD, ANALYTICS_CONSUMED, ANALYTICS_LEASE),
]


def create_app(
    factory: sessionmaker[Session],
    rate_limit_per_minute: int,
    max_body_bytes: int = 8 << 20,
    storage: Storage | None = None,
    assess_engine: Engine | None = None,
    assess_config: AssessSettings | None = None,
) -> FastAPI:
    """`assess_engine` and `assess_config` default to what `YANTRA_ASSESS_*` names; tests pass their own."""
    replayable = consumers(factory)
    operations = []
    for module, dead, consumed, lease in OPERATIONS:
        # analytics' durable changes name with every rebuild generation; any of them replays through ingest
        handlers: Mapping[str, Handler] = AnyGeneration() if module == "analytics" else handlers_of(replayable, module)
        operations.append(dead_letter_router(f"/v1/{module}/dead-letters", dead, consumed, handlers))
        operations.append(jobs_router(f"/v1/{module}/jobs", lease))
    app = base_app(
        "Yantra work",
        factory,
        [
            market_router,
            talent_router,
            assess_router,
            quality_router,
            notify_router,
            tracker_router,
            analytics_router,
            attention_router([dead for _, dead, _, _ in OPERATIONS]),
            *operations,
        ],
        [MARKET_OUTBOX, TALENT_OUTBOX, ASSESS_OUTBOX, QUALITY_OUTBOX, TRACKER_OUTBOX],
        rate_limit_per_minute,
        max_body_bytes,
        storage=storage,
        process="work",
    )
    app.state.dead_tables = [dead for _, dead, _, _ in OPERATIONS]  # the leadership page counts incidents here
    app.state.assess_settings = assess_config or AssessSettings()
    app.state.assess_engine = assess_engine or select_engine(app.state.assess_settings)
    return app


def default_app() -> FastAPI:
    boot("work")
    s = settings()
    return create_app(
        make_session_factory(make_engine(str(s.database_url))),
        s.rate_limit_per_minute,
        s.max_body_bytes,
        storage=storage_from_env(),
    )
