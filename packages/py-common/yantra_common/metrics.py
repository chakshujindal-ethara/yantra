"""Prometheus metrics, one registry per process. Every metric is defined here so its name exists in one place; the
alert rules (deployment/observability/alerts.yaml) and the dashboard read these names.

Two kinds of producers:
- request middleware on every HTTP app (`install_metrics`): one histogram, labelled by route template, so a path
  full of ids stays one series;
- a `Probe` in each events process: a cheap read of the outboxes, dead letters, job leases and the deployable's own
  invariants (two live claims on one unit, the oldest pending review, pay-window lines by status), at most every 15 s.
Counters inside the consumer, the scheduler and the payout rail count as things happen."""

import asyncio
import logging
import re
import time
from collections.abc import Awaitable, Callable, Iterable, Sequence
from datetime import UTC, datetime

from fastapi import FastAPI, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from sqlalchemy import Table, func, select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

log = logging.getLogger("yantra.metrics")

HTTP_DURATION = Histogram(
    "yantra_http_request_duration_seconds",
    "Time to answer one HTTP request, by process, method, route template and status.",
    ["process", "method", "route", "status"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)
OUTBOX_UNPUBLISHED = Gauge("yantra_outbox_unpublished", "Outbox rows not yet on the bus.", ["schema"])
OUTBOX_OLDEST = Gauge("yantra_outbox_oldest_age_seconds", "Age of the oldest unpublished outbox row.", ["schema"])
DEAD_EVENTS = Gauge("yantra_dead_events", "Messages in a module's dead-letter table.", ["schema"])
CONSUMER_HANDLED = Counter(
    "yantra_consumer_handled_total", "Messages a consumer finished, by outcome.", ["consumer", "outcome"]
)
CONSUMER_OLDEST = Gauge(
    "yantra_consumer_oldest_age_seconds",
    "Age of the oldest message in a consumer's last fetch (0 if none).",
    ["consumer"],
)
JOB_DURATION = Histogram(
    "yantra_job_duration_seconds",
    "Time one scheduled job pass took.",
    ["job"],
    buckets=(0.01, 0.05, 0.1, 0.5, 1.0, 5.0, 15.0, 60.0, 300.0),
)
JOB_LAST_SUCCESS = Gauge("yantra_job_last_success_timestamp", "Unix time a job last finished without error.", ["job"])
JOB_FAILURES = Counter("yantra_job_failures_total", "Scheduled job passes that raised.", ["job"])
JOB_OVERDUE = Gauge("yantra_job_overdue", "1 when a job is well past its slot (no replica has run it).", ["job"])
UNITS_DOUBLE_CLAIMED = Gauge(
    "yantra_units_with_two_live_claims", "Units holding more than one active claim: must always be 0."
)
REVIEW_BACKLOG_AGE = Gauge(
    "yantra_review_backlog_oldest_age_seconds", "Age of the oldest review task still waiting for a reviewer."
)
WINDOW_LINES = Gauge("yantra_window_lines", "Pay-window lines by status, across open windows.", ["status"])
WINDOW_LAST_CLOSED = Gauge("yantra_pay_window_last_closed_timestamp", "Unix time the latest pay window closed.")
RECONCILIATION_DELTA = Gauge(
    "yantra_pay_window_reconciliation_delta",
    "Sum of absolute deltas in each window's latest reconciliation run: must always be 0.",
)
RAIL_CALLS = Counter("yantra_rail_calls_total", "Calls to a payout rail, by outcome.", ["rail", "outcome"])
ASSESS_ENGINE_UP = Gauge("yantra_assess_engine_up", "1 when the assessment engine answered the last call usefully.")
ASSESS_ENGINE_CALLS = Counter(
    "yantra_assess_engine_calls_total", "Calls to the assessment engine, by operation and outcome.", ["op", "outcome"]
)
ASSESS_SYNC_LAG = Gauge(
    "yantra_assess_sync_lag_seconds", "Seconds since the assess sync last read the engine's attempts."
)
ASSESS_AWAITING = Gauge(
    "yantra_assess_awaiting_result", "Sittings submitted and waiting for a result, by reason.", ["reason"]
)

UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
WORD = re.compile(r"^[a-z][a-z0-9_-]{0,40}$")
MAX_SEGMENTS = 6
UNROUTED = "other"


def normalize_path(path: str) -> str:
    """A route label for a path no template describes (the gateway's catch-all): ids and anything that is not a
    plain word become `{id}`, and depth is capped, so the series stay bounded."""
    segments = [s for s in path.split("/") if s][:MAX_SEGMENTS]
    return "/" + "/".join(s if WORD.match(s) and not UUID.match(s) else "{id}" for s in segments)


def mark_upstream(request: Request) -> None:
    """The gateway calls this once a service answered the request, so its path may become a (normalised) label."""
    request.state.upstream_answered = True


def route_label(request: Request, status: int, normalize: bool) -> str:
    """The matched route template. For the gateway (`normalize`) the normalised path, but only for an answer a service
    gave (`mark_upstream`) and never for a 401 or 404, which a scanner could vary without end; an answer the gateway
    made itself (a 400, 413, 422, 429 or 503 on any path) is the matched template when it is not the catch-all, else
    `other`. Every series stays bounded."""
    if normalize and getattr(request.state, "upstream_answered", False) and status not in (401, 404):
        return normalize_path(request.url.path)
    route = request.scope.get("route")
    path = getattr(route, "path", None)
    return path if isinstance(path, str) and ":path}" not in path else UNROUTED


def render() -> tuple[bytes, str]:
    return generate_latest(), CONTENT_TYPE_LATEST


def install_metrics(app: FastAPI, process: str, normalize: bool = False) -> None:
    """Time every request and serve `/metrics`. Install it after the boundary so it is the outermost layer and
    sees the final status, a 500 from the boundary included."""

    @app.middleware("http")
    async def observe(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        if request.url.path == "/metrics":
            return await call_next(request)
        start = time.perf_counter()
        response = await call_next(request)
        route = route_label(request, response.status_code, normalize)
        HTTP_DURATION.labels(process, request.method, route, str(response.status_code)).observe(
            time.perf_counter() - start
        )
        return response

    install_metrics_route(app)


def install_metrics_route(app: FastAPI) -> None:
    @app.get("/metrics", include_in_schema=False)
    def metrics() -> Response:
        body, content_type = render()
        return Response(body, media_type=content_type)


Observer = Callable[[Session, datetime], None]


def observe_outboxes(outboxes: Sequence[Table]) -> Observer:
    def observe(session: Session, now: datetime) -> None:
        for t in outboxes:
            count, oldest = session.execute(
                select(func.count(), func.min(t.c.occurred_at)).where(t.c.published_at.is_(None))
            ).one()
            OUTBOX_UNPUBLISHED.labels(str(t.schema)).set(int(count))
            OUTBOX_OLDEST.labels(str(t.schema)).set(0 if oldest is None else max(0.0, (now - oldest).total_seconds()))

    return observe


def observe_dead(tables: Sequence[Table]) -> Observer:
    def observe(session: Session, now: datetime) -> None:
        for t in tables:
            DEAD_EVENTS.labels(str(t.schema)).set(int(session.scalar(select(func.count()).select_from(t)) or 0))

    return observe


def observe_jobs(jobs: Iterable[object]) -> Observer:
    """`jobs` are scheduler `Job`s; typed loosely so this module never imports the scheduler (which imports it)."""
    from yantra_common.scheduler import Job, overdue

    job_list = [j for j in jobs if isinstance(j, Job)]

    def observe(session: Session, now: datetime) -> None:
        for job in job_list:
            next_run_at = session.scalar(select(job.lease.c.next_run_at).where(job.lease.c.name == job.name))
            JOB_OVERDUE.labels(job.name).set(1 if next_run_at is not None and overdue(job, next_run_at, now) else 0)

    return observe


class Probe:
    """A relay that never reports work: at most every `every` seconds it runs the observers in a worker thread,
    one session for all of them. A failing observer is logged and skipped; metrics never stop the event loop."""

    def __init__(
        self,
        factory: sessionmaker[Session],
        observers: Sequence[Observer],
        every: float = 15.0,
        clock: Callable[[], float] = time.monotonic,
        now: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self.factory, self.observers, self.every, self.clock, self.now = factory, observers, every, clock, now
        self._last: float | None = None

    async def __call__(self) -> int:
        t = self.clock()
        if self._last is not None and t - self._last < self.every:
            return 0
        self._last = t
        await asyncio.to_thread(self.observe)
        return 0

    def observe(self) -> None:
        now = self.now()
        with self.factory() as session:
            for observer in self.observers:
                try:
                    observer(session, now)
                except SQLAlchemyError:
                    session.rollback()
                    log.warning("metrics observer failed observer=%s", getattr(observer, "__qualname__", observer))
