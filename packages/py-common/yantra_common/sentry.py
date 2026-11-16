"""Error reporting to Sentry, opt-in: nothing happens unless `SENTRY_DSN` is set. Personal data stays out: no default
PII, no request bodies, no auth or cookie headers, no query strings, no user block. Traces go to OpenTelemetry, not
here, so the trace sample rate is 0."""

import logging
import os
from collections.abc import Mapping
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from sentry_sdk.types import Event, Hint

log = logging.getLogger("yantra.sentry")
SECRET_HEADERS = {"authorization", "cookie", "x-name", "idempotency-key", "x-razorpay-signature"}


def scrub(event: "Event", hint: "Hint | None" = None) -> "Event":
    """`before_send`: strip what could identify a person or carry a secret, keep what helps to debug."""
    request: Any = event.get("request")
    if isinstance(request, dict):
        for key in ("data", "cookies", "query_string", "env"):
            request.pop(key, None)
        headers = request.get("headers")
        if isinstance(headers, dict):
            request["headers"] = {k: v for k, v in headers.items() if k.lower() not in SECRET_HEADERS}
    event.pop("user", None)
    return event


def install_sentry(process: str, env: Mapping[str, str] | None = None) -> bool:
    env = os.environ if env is None else env
    dsn = env.get("SENTRY_DSN")
    if not dsn:
        return False
    import sentry_sdk

    sentry_sdk.init(
        dsn=dsn,
        environment=env.get("YANTRA_ENV", "local"),
        release=env.get("YANTRA_RELEASE") or None,
        send_default_pii=False,
        traces_sample_rate=0.0,
        max_request_body_size="never",
        before_send=scrub,
    )
    sentry_sdk.set_tag("process", process)
    log.info("sentry enabled process=%s", process)
    return True
