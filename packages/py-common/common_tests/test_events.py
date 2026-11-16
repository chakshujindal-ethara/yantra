"""The bus against the test NATS (4223): a durable created by an earlier release with the old `max_deliver` is moved
to the current one when a consumer subscribes, so the server keeps redelivering past the dead-letter threshold."""

import asyncio

from nats.js.api import ConsumerConfig, DeliverPolicy

from yantra_common.events import DEAD_LETTER_AFTER, MAX_DELIVER, STREAM, Bus
from yantra_common.testing import NATS_URL

SUBJECT = "analytics.fxtest-maxdeliver.v1"


def test_an_old_durable_gets_the_current_max_deliver_and_a_new_one_is_created_with_it():
    async def scenario() -> tuple[int, int]:
        bus = await Bus.connect(NATS_URL)
        try:
            for name in ("fxtest-old", "fxtest-new"):
                try:
                    await bus.js.delete_consumer(STREAM, name)
                except Exception:  # noqa: S110 - absent from an earlier run is the normal case
                    pass
            old = ConsumerConfig(
                durable_name="fxtest-old",
                deliver_policy=DeliverPolicy.ALL,
                ack_wait=30,
                max_deliver=DEAD_LETTER_AFTER,
                filter_subject=SUBJECT,
            )
            await bus.js.add_consumer(STREAM, old)
            await bus.pull_subscription("fxtest-old", SUBJECT)
            await bus.pull_subscription("fxtest-new", SUBJECT)
            updated = (await bus.js.consumer_info(STREAM, "fxtest-old")).config.max_deliver
            created = (await bus.js.consumer_info(STREAM, "fxtest-new")).config.max_deliver
            for name in ("fxtest-old", "fxtest-new"):
                await bus.js.delete_consumer(STREAM, name)
            return int(updated or 0), int(created or 0)
        finally:
            await bus.close()

    assert asyncio.run(scenario()) == (MAX_DELIVER, MAX_DELIVER)
    assert MAX_DELIVER == DEAD_LETTER_AFTER + 5
