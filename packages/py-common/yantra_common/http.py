"""The boundary: request ids, body size, and the one place errors become HTTP responses.
Every error is logged once, here, with the request id and record ids; never with client data."""

import json
import logging
import os
import re
import time
import uuid
from collections.abc import Awaitable, Callable
from contextvars import ContextVar
from datetime import UTC, datetime

from fastapi import FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from yantra_common.errors import DomainError

log = logging.getLogger("yantra.http")
access = logging.getLogger("yantra.access")
REQUEST_ID = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")
ID_KEYS = re.compile(r"(^|_)(id|ref|code|status|gate|count|margin|floor)$")
CURRENT_REQUEST: ContextVar[str | None] = ContextVar("yantra_request_id", default=None)
QUIET_PATHS = ("/health", "/ready", "/metrics")
TEXT_FORMAT = "%(asctime)s %(levelname)s %(name)s %(message)s"
# what every LogRecord carries; anything else on a record came in through `extra=` and belongs in the JSON line
_STANDARD = set(logging.LogRecord("", 0, "", 0, "", None, None).__dict__) | {"message", "asctime", "request_id"}


class RequestIdFilter(logging.Filter):
    """Stamps the request being served (if any) on every record, so a JSON line needs no id in its message."""

    def filter(self, record: logging.LogRecord) -> bool:
        record.request_id = CURRENT_REQUEST.get()
        return True


class JsonFormatter(logging.Formatter):
    """One JSON object per line: ts, level, logger, msg, request_id, the `extra=` fields, and the traceback."""

    def format(self, record: logging.LogRecord) -> str:
        line: dict[str, object] = {
            "ts": datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
            "request_id": getattr(record, "request_id", None),
        }
        line.update({k: v for k, v in record.__dict__.items() if k not in _STANDARD and not k.startswith("_")})
        if record.exc_info:
            line["exc"] = self.formatException(record.exc_info)
        return json.dumps(line, default=str)


def configure_logging(level: int = logging.INFO, fmt: str | None = None) -> None:
    """`LOG_FORMAT=json` (deployed environments, read by the log shipper) or `text` (the default: one key=value
    line per event, so a request id can be grepped across the service and the gateway)."""
    handler = logging.StreamHandler()
    handler.addFilter(RequestIdFilter())
    chosen = (fmt or os.environ.get("LOG_FORMAT") or "text").lower()
    handler.setFormatter(JsonFormatter() if chosen == "json" else logging.Formatter(TEXT_FORMAT))
    logging.basicConfig(level=level, handlers=[handler], force=True)


def loggable(context: dict[str, object]) -> str:
    """Only ids, codes and counts reach the log. Lists (import line errors) are reduced to their length."""
    parts = []
    for key, value in context.items():
        if isinstance(value, list):
            parts.append(f"{key}_count={len(value)}")
        elif ID_KEYS.search(key):
            parts.append(f"{key}={value}")
    return " ".join(parts)


API_SECURITY_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
    "Cache-Control": "no-store",
}
HSTS = "max-age=31536000; includeSubDomains"
DOCS_PATHS = ("/docs", "/redoc", "/openapi.json")


def install_security_headers(app: FastAPI, hsts: bool) -> None:
    """The headers every JSON API answer carries: no sniffing, no framing, no referrer, nothing cached, a CSP that
    loads nothing. HSTS only where TLS terminates in front (a deployed environment), never on the local rig's plain
    HTTP. A route may set its own value (a CSV download its Cache-Control); the docs pages keep theirs."""

    @app.middleware("http")
    async def security_headers(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        response = await call_next(request)
        if request.url.path.startswith(DOCS_PATHS):
            return response
        for name, value in API_SECURITY_HEADERS.items():
            response.headers.setdefault(name, value)
        if hsts:
            response.headers.setdefault("Strict-Transport-Security", HSTS)
        return response


def install_boundary(app: FastAPI, max_body_bytes: int) -> None:
    @app.middleware("http")
    async def request_id(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        incoming = request.headers.get("X-Request-Id", "")
        rid = incoming if REQUEST_ID.match(incoming) else str(uuid.uuid4())
        request.state.request_id = rid
        token = CURRENT_REQUEST.set(rid)
        try:
            return await _bounded(request, call_next, rid)
        finally:
            CURRENT_REQUEST.reset(token)

    async def _bounded(request: Request, call_next: Callable[[Request], Awaitable[Response]], rid: str) -> Response:
        length = request.headers.get("content-length")
        if length and length.isdigit() and int(length) > max_body_bytes:
            return JSONResponse(
                status_code=413,
                content={
                    "code": "payload_too_large",
                    "message": f"body over {max_body_bytes} bytes",
                    "request_id": rid,
                },
                headers={"X-Request-Id": rid},
            )
        if length is None and "chunked" in request.headers.get("transfer-encoding", "").lower():
            # a body with no declared length could not be capped before it is read; the gateway always sends one
            return JSONResponse(
                status_code=411,
                content={"code": "length_required", "message": "Content-Length is required", "request_id": rid},
                headers={"X-Request-Id": rid},
            )
        start = time.perf_counter()
        try:
            response = await call_next(request)
        except Exception:
            log.exception("unhandled request_id=%s method=%s path=%s", rid, request.method, request.url.path)
            response = JSONResponse(
                status_code=500, content={"code": "internal_error", "message": "internal error", "request_id": rid}
            )
        response.headers["X-Request-Id"] = rid
        if not request.url.path.startswith(QUIET_PATHS):
            log_access(request, response.status_code, (time.perf_counter() - start) * 1000, rid)
        return response

    @app.exception_handler(DomainError)
    async def domain_error(request: Request, exc: DomainError) -> JSONResponse:
        rid = getattr(request.state, "request_id", "-")
        log.warning("domain_error code=%s status=%s request_id=%s %s", exc.code, exc.status, rid, loggable(exc.context))
        return JSONResponse(
            status_code=exc.status, content={"code": exc.code, "message": exc.message, "request_id": rid, **exc.context}
        )

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
        rid = getattr(request.state, "request_id", "-")
        fields = [".".join(str(p) for p in e.get("loc", ())) for e in exc.errors()]
        log.warning("validation_error request_id=%s fields=%s", rid, ",".join(fields[:10]))
        return JSONResponse(
            status_code=422,
            content={"code": "validation_error", "message": "invalid request", "request_id": rid, "fields": fields},
        )


def log_access(request: Request, status: int, duration_ms: float, rid: str) -> None:
    """The one access line per request (uvicorn's own access log is off): method, path, status, time, the caller's
    subject id when the gateway sent one. Never the query string or a body."""
    caller = request.headers.get("X-Worker-Id", "")
    access.info(
        "%s %s status=%d duration_ms=%.1f request_id=%s",
        request.method,
        request.url.path,
        status,
        duration_ms,
        rid,
        extra={
            "method": request.method,
            "path": request.url.path,
            "status": status,
            "duration_ms": round(duration_ms, 1),
            "caller": caller if UUID_TEXT.match(caller) else None,
        },
    )


UUID_TEXT = re.compile(r"^[0-9a-fA-F-]{36}$")
