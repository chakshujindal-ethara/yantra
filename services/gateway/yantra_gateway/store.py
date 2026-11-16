"""The gateway's shared state in Redis: the per-caller rate limit and the idempotency store.
Every replica sees the same counters, so the allowance is the limit, not the limit times the replicas.
An idempotency key is scoped to the caller, the method and the path, so one key cannot answer a different
request, and bound to a digest of the body, so a key reused with a different body is refused instead of answered
with the first body's response. A request in flight holds its key for a short time only; a stored response is kept
for the full TTL."""

import hashlib
import json
import time
from dataclasses import dataclass

from redis.asyncio import Redis

MAX_STORED_BODY = 64 * 1024


@dataclass(frozen=True)
class Stored:
    status: int
    body: bytes
    content_type: str


class Mismatch:
    """The key is held, or was answered, for a different body."""


MISMATCH = Mismatch()


class Store:
    def __init__(
        self,
        redis: Redis,
        limit_per_minute: int,
        idempotency_ttl: int,
        inflight_ttl: int = 30,
        address_multiplier: int = 20,
    ) -> None:
        self.redis = redis
        self.limit = limit_per_minute
        self.address_limit = limit_per_minute * address_multiplier  # one address fronts many callers behind NAT
        self.ttl = idempotency_ttl
        self.inflight_ttl = inflight_ttl

    async def allow(self, key: str, limit: int | None = None, now: float | None = None) -> int:
        """Fixed one-minute window. Returns 0 when allowed, else the seconds until the window turns."""
        now = time.time() if now is None else now
        window = int(now // 60)
        counter = f"rl:{key}:{window}"
        count = await self.redis.incr(counter)
        if count == 1:
            await self.redis.expire(counter, 120)
        if count > (self.limit if limit is None else limit):
            return max(1, int(60 - (now % 60)))
        return 0

    @staticmethod
    def name(worker: str, method: str, path: str, key: str) -> str:
        scope = hashlib.sha256(f"{method} {path}".encode()).hexdigest()[:16]
        return f"idem:{worker}:{scope}:{key}"

    async def begin(self, name: str, body_hash: str = "") -> Stored | None | bool | Mismatch:
        """Claim an idempotency key. Returns the stored response for a replay, False when another request
        with the same key and body is still in flight, MISMATCH when the key is held or answered for another body,
        or None when this request owns the key."""
        if await self.redis.set(name, f"inflight:{body_hash}", nx=True, ex=self.inflight_ttl):
            return None
        raw = await self.redis.get(name)
        if raw is None:  # pragma: no cover - the key lapsed between the SET and the GET: still someone else's turn
            return False
        if raw.startswith(b"inflight"):
            held = raw.decode().partition(":")[2]  # empty for a key written before bodies were bound
            return MISMATCH if held and held != body_hash else False
        doc = json.loads(raw)
        if doc.get("body_hash", body_hash) != body_hash:
            return MISMATCH
        return Stored(status=int(doc["status"]), body=bytes.fromhex(doc["body"]), content_type=str(doc["content_type"]))

    async def finish(self, name: str, stored: Stored, body_hash: str = "") -> bool:
        """Keep the response for replays. An oversized body is not kept; the key is freed instead."""
        if len(stored.body) > MAX_STORED_BODY:
            await self.redis.delete(name)
            return False
        doc = {
            "status": stored.status,
            "body": stored.body.hex(),
            "content_type": stored.content_type,
            "body_hash": body_hash,
        }
        await self.redis.set(name, json.dumps(doc), ex=self.ttl)
        return True

    async def release(self, name: str) -> None:
        """A failure frees the key so the client can retry."""
        await self.redis.delete(name)

    async def close(self) -> None:
        await self.redis.aclose()
