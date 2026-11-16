"""What every HTTP deployable is made of: the limiter, the boundary, the routers, `/health` and `/ready`.
Readiness is the database alone. An outbox with rows older than `stale_after_seconds` still unpublished is reported
(`outbox_stale`) but never fails it: a NATS outage would otherwise pull every API pod out of its Service. The
OutboxStale alert (deployment/observability/alerts.yaml) covers the relay.
`events_app` is the small HTTP face of an events process: is the loop turning, is NATS there, are the jobs on time."""

import logging
from collections.abc import Callable
from datetime import UTC, datetime

from fastapi import APIRouter, FastAPI
from fastapi.responses import JSONResponse
from sqlalchemy import Table, func, select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

from yantra_common.consumer import LoopState
from yantra_common.http import install_boundary, install_security_headers
from yantra_common.metrics import install_metrics, install_metrics_route
from yantra_common.ratelimit import SlidingWindowLimiter, rate_limit_middleware
from yantra_common.scheduler import Job, overdue
from yantra_common.storage import Storage
from yantra_common.tracing import install_tracing

log = logging.getLogger("yantra.app")


def base_app(
    title: str,
    factory: sessionmaker[Session],
    routers: list[APIRouter],
    outboxes: list[Table],
    rate_limit_per_minute: int,
    max_body_bytes: int,
    stale_after_seconds: int = 60,
    storage: Storage | None = None,
    process: str | None = None,
) -> FastAPI:
    """`process` labels this app's metrics and traces (`work`, `money`); it defaults to the lower-cased title."""
    name = process or title.lower()
    app = FastAPI(title=title, version="0.1.0")
    app.state.factory = factory
    app.state.storage = storage
    exempt = frozenset({"/health", "/ready", "/metrics"})
    app.middleware("http")(rate_limit_middleware(SlidingWindowLimiter(rate_limit_per_minute), exempt))
    install_boundary(app, max_body_bytes)
    install_security_headers(app, hsts=False)  # behind the gateway, never reached by a browser directly
    install_metrics(app, name)  # outermost: it sees the final status, a 500 from the boundary included
    install_tracing(app, name, engine=factory.kw.get("bind"))
    for router in routers:
        app.include_router(router)

    @app.get("/health", include_in_schema=False)
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/ready", include_in_schema=False)
    def ready() -> JSONResponse:
        backlog: dict[str, int] = {}
        stale = False
        now = datetime.now(UTC)
        try:
            with factory() as session:
                for t in outboxes:
                    count, oldest = session.execute(
                        select(func.count(), func.min(t.c.occurred_at)).where(t.c.published_at.is_(None))
                    ).one()
                    backlog[str(t.schema)] = int(count)
                    if oldest is not None and (now - oldest).total_seconds() > stale_after_seconds:
                        stale = True
        except SQLAlchemyError as e:
            log.warning("ready: database unavailable process=%s error=%s", name, type(e).__name__)
            return JSONResponse(status_code=503, content={"status": "database_unavailable"})
        return JSONResponse(content={"status": "ok", "outbox_unpublished": backlog, "outbox_stale": stale})

    return app


def events_app(
    factory: sessionmaker[Session],
    outboxes: list[Table],
    dead_tables: list[Table],
    jobs: list[Job],
    state: LoopState,
    connected: Callable[[], bool],
    stale_after_seconds: int = 60,
    clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    outbox_stuck_after_seconds: int = 300,
) -> FastAPI:
    """`/ready` is 503 when the loop has not finished a round within `stale_after_seconds`, NATS is away, an outbox
    is stuck, or a job is well past its slot. An outbox is stuck when its oldest unpublished row is older than
    `outbox_stuck_after_seconds` (YANTRA_OUTBOX_STUCK_SECONDS) and its backlog did not shrink since the previous
    check: the relay is wedged. A large backlog that drains after a burst stays ready. Dead letters are counted but
    never fail readiness: a poison message is not a wedged process (the dead-letter alert job reports them)."""
    app = FastAPI(title="Yantra events", version="0.1.0")
    previous: dict[str, int] = {}  # each outbox's backlog at the previous check
    install_metrics_route(app)  # the probe's gauges and the consumer and job counters of this process

    @app.get("/health", include_in_schema=False)
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/ready", include_in_schema=False)
    def ready() -> JSONResponse:
        now = clock()
        backlog: dict[str, int] = {}
        dead: dict[str, int] = {}
        schedule: dict[str, dict[str, object]] = {}
        stuck: list[str] = []
        with factory() as session:
            for t in outboxes:
                count, oldest = session.execute(
                    select(func.count(), func.min(t.c.occurred_at)).where(t.c.published_at.is_(None))
                ).one()
                schema, count = str(t.schema), int(count)
                old = oldest is not None and (now - oldest).total_seconds() > outbox_stuck_after_seconds
                if old and schema in previous and count >= previous[schema]:
                    stuck.append(schema)
                backlog[schema] = previous[schema] = count
            for t in dead_tables:
                dead[str(t.schema)] = int(session.scalar(select(func.count()).select_from(t)) or 0)
            for job in jobs:
                row = session.execute(select(job.lease).where(job.lease.c.name == job.name)).first()
                if row is None:
                    continue
                schedule[job.name] = {
                    "next_run_at": row.next_run_at.isoformat(),
                    "last_run_at": row.last_run_at.isoformat() if row.last_run_at else None,
                    "last_error": row.last_error,
                    "overdue": overdue(job, row.next_run_at, now),
                }
        nats = connected()
        loop_ok = state.last_round_at is not None and (now - state.last_round_at).total_seconds() <= stale_after_seconds
        if not loop_ok:
            status = "loop_stale"
        elif not nats:
            status = "nats_disconnected"
        elif stuck:
            status = "outbox_stuck"
        elif any(j["overdue"] for j in schedule.values()):
            status = "job_overdue"
        else:
            status = "ok"
        body = {
            "status": status,
            "last_round_at": state.last_round_at.isoformat() if state.last_round_at else None,
            "nats_connected": nats,
            "outbox_unpublished": backlog,
            "outbox_stuck": stuck,
            "dead_letters": dead,
            "jobs": schedule,
        }
        return JSONResponse(status_code=200 if status == "ok" else 503, content=body)

    return app
