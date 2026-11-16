"""The event bus: NATS JetStream with one stream for every Yantra subject. Events are CloudEvents-shaped JSON;
the message id is the outbox row id, so JetStream drops a duplicate publish within its dedup window."""

import json
import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any

import nats
from nats.aio.client import Client
from nats.js import JetStreamContext
from nats.js.api import ConsumerConfig, DeliverPolicy, RetentionPolicy, StreamConfig
from nats.js.errors import NotFoundError

STREAM = "YANTRA"
SUBJECTS = [
    "work.>",
    "quality.>",
    "payout.>",
    "worker.>",
    "delivery.>",
    "talent.>",
    "assess.>",
    "tracking.>",
    "analytics.>",
]
RETENTION_SECONDS = 30 * 24 * 3600
# the consumer dead-letters a message on its twentieth failed delivery (it doubles its nak delay per delivery, so
# twenty attempts span hours); the server keeps redelivering a few times past that, so a dead-letter insert that
# fails on that delivery is naked and tried again instead of the event being dropped
DEAD_LETTER_AFTER = 20
MAX_DELIVER = DEAD_LETTER_AFTER + 5


@dataclass(frozen=True)
class Envelope:
    """What a consumer receives: the outbox row, decoded."""

    id: uuid.UUID
    type: str
    subject: str
    occurred_at: datetime
    data: dict[str, Any]

    @classmethod
    def from_bytes(cls, raw: bytes) -> "Envelope":
        doc = json.loads(raw)
        return cls(
            id=uuid.UUID(doc["id"]),
            type=str(doc["type"]),
            subject=str(doc["subject"]),
            occurred_at=datetime.fromisoformat(doc["time"]),
            data=dict(doc["data"]),
        )


def encode(event_id: uuid.UUID, type_: str, subject: str, occurred_at: datetime, data: dict[str, Any]) -> bytes:
    doc = {
        "specversion": "1.0",
        "id": str(event_id),
        "type": type_,
        "source": "yantra",
        "subject": subject,
        "time": occurred_at.isoformat(),
        "data": data,
    }
    return json.dumps(doc, separators=(",", ":")).encode()


class Bus:
    def __init__(self, nc: Client, js: JetStreamContext) -> None:
        self.nc = nc
        self.js = js

    @classmethod
    async def connect(cls, url: str) -> "Bus":
        nc = await nats.connect(url, connect_timeout=5, max_reconnect_attempts=-1)
        js = nc.jetstream(timeout=5)
        bus = cls(nc, js)
        await bus.ensure_stream()
        return bus

    async def ensure_stream(self) -> None:
        cfg = StreamConfig(
            name=STREAM,
            subjects=SUBJECTS,
            retention=RetentionPolicy.LIMITS,
            max_age=RETENTION_SECONDS,
            duplicate_window=120,
        )
        try:
            await self.js.stream_info(STREAM)
            await self.js.update_stream(cfg)
        except NotFoundError:
            await self.js.add_stream(cfg)

    async def publish(self, event_id: uuid.UUID, type_: str, payload: bytes) -> None:
        """Publish to the subject that is the event type. The outbox id is the dedup key."""
        await self.js.publish(type_, payload, timeout=5, headers={"Nats-Msg-Id": str(event_id)})

    async def pull_subscription(self, durable: str, subject: str) -> JetStreamContext.PullSubscription:
        """Subscribe to a durable, created with this config when new; an existing durable created with another
        `max_deliver` (an earlier release) is updated to it first, since subscribing alone never changes it."""
        cfg = ConsumerConfig(
            durable_name=durable,
            deliver_policy=DeliverPolicy.ALL,
            ack_wait=30,
            max_deliver=MAX_DELIVER,
            filter_subject=subject,
        )
        try:
            info = await self.js.consumer_info(STREAM, durable)
        except NotFoundError:
            pass
        else:
            if info.config.max_deliver != MAX_DELIVER:
                await self.js.add_consumer(STREAM, cfg)  # the same durable name: an update of an editable field
        return await self.js.pull_subscribe(subject, durable=durable, stream=STREAM, config=cfg)

    async def close(self) -> None:
        """Close without draining: pull subscriptions have nothing in flight to drain and would wait 30 s."""
        await self.nc.close()
