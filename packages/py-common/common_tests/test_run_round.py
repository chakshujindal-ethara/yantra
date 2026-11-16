"""A round serves every consumer at once: an idle consumer's fetch wait must not hold up a busy one, or a process
with thirty consumers serves each about once every fifteen seconds (the money-parity gate measured ~3 events/s)."""

import asyncio
import time
from typing import Any

import pytest

from yantra_common.consumer import run_round


class Idle:
    """A consumer whose fetch finds nothing after its wait, like run_once on an empty subscription."""

    def __init__(self, wait: float, handled: int = 0) -> None:
        self.wait, self.handled = wait, handled

    async def run_once(self, bus: Any) -> int:
        await asyncio.sleep(self.wait)
        return self.handled


class Broken:
    async def run_once(self, bus: Any) -> int:
        raise RuntimeError("nats away")


def test_idle_waits_overlap_so_a_round_costs_one_wait_not_the_sum():
    consumers: list[Any] = [Idle(0.25) for _ in range(10)] + [Idle(0.25, handled=7)]
    relayed: list[int] = []

    async def relay() -> int:
        relayed.append(1)
        return 2

    started = time.monotonic()
    busy = asyncio.run(run_round(None, consumers, [relay]))
    elapsed = time.monotonic() - started
    assert busy == 9 and relayed == [1]
    assert elapsed < 1.0, f"a round took {elapsed:.2f}s: consumers were served one after another"


def test_a_failing_consumer_still_fails_the_round():
    with pytest.raises(RuntimeError, match="nats away"):
        asyncio.run(run_round(None, [Idle(0.01), Broken()], []))
