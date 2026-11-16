"""Per-caller sliding-window rate limit. 429 with Retry-After when the window is full.

In-process by design for a single `work` replica; the gateway owns the shared limit across replicas and
validates identity. Here the key is the caller's worker id when it is a well-formed UUID, otherwise the
client address, so a made-up header cannot mint a fresh bucket per request. Keys are evicted when their
window empties and the table is capped, so the limiter cannot grow without bound."""

import logging
import threading
import time
import uuid
from collections import deque
from collections.abc import Awaitable, Callable

from fastapi import Request, Response
from fastapi.responses import JSONResponse

log = logging.getLogger("yantra.ratelimit")


class SlidingWindowLimiter:
    def __init__(self, limit: int, window_seconds: float = 60.0, max_keys: int = 50_000) -> None:
        self.limit = limit
        self.window = window_seconds
        self.max_keys = max_keys
        self._hits: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def check(self, key: str, now: float | None = None) -> float:
        """Returns 0 when the call is allowed, otherwise the seconds to wait."""
        now = time.monotonic() if now is None else now
        with self._lock:
            if key not in self._hits and len(self._hits) >= self.max_keys:
                self._evict(now)
            hits = self._hits.setdefault(key, deque())
            while hits and now - hits[0] >= self.window:
                hits.popleft()
            if len(hits) >= self.limit:
                return self.window - (now - hits[0])
            hits.append(now)
            return 0.0

    def _evict(self, now: float) -> None:
        """Drop every key whose window has emptied; if the table is still full, drop the quietest keys."""
        for key in [k for k, h in self._hits.items() if not h or now - h[-1] >= self.window]:
            del self._hits[key]
        while len(self._hits) >= self.max_keys:
            del self._hits[min(self._hits, key=lambda k: self._hits[k][-1])]

    def size(self) -> int:
        return len(self._hits)


def caller_key(request: Request, header: str = "X-Worker-Id") -> str:
    raw = request.headers.get(header, "")
    try:
        return f"w:{uuid.UUID(raw)}"
    except ValueError:
        return f"ip:{request.client.host if request.client else 'unknown'}"


def rate_limit_middleware(
    limiter: SlidingWindowLimiter, exempt: frozenset[str] = frozenset({"/health", "/ready"})
) -> Callable[[Request, Callable[[Request], Awaitable[Response]]], Awaitable[Response]]:
    async def middleware(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        if request.url.path in exempt:
            return await call_next(request)
        key = caller_key(request)
        wait = limiter.check(key)
        if wait > 0:
            retry_after = max(1, int(wait + 0.999))
            log.warning("rate limited key=%s path=%s retry_after=%s", key, request.url.path, retry_after)
            return JSONResponse(
                status_code=429,
                content={"code": "rate_limited", "message": "too many requests"},
                headers={"Retry-After": str(retry_after)},
            )
        return await call_next(request)

    return middleware
