"""The consumer's failure paths, without NATS: fake messages drive run_once."""

import asyncio
import json
import uuid
from datetime import UTC, datetime
from types import SimpleNamespace

import pytest
from sqlalchemy import MetaData, create_engine, select, text
from sqlalchemy.orm import sessionmaker

from yantra_common.consumer import Consumer, backoff_after, consumed_table, dead_table
from yantra_common.events import DEAD_LETTER_AFTER, MAX_DELIVER, encode
from yantra_common.testing import ADMIN_URL


class FakeMsg:
    def __init__(self, data: bytes, delivered: int = 1) -> None:
        self.data = data
        self.metadata = SimpleNamespace(num_delivered=delivered)
        self.actions: list[str] = []

    async def ack(self) -> None:
        self.actions.append("ack")

    async def nak(self, delay: float = 0) -> None:
        self.actions.append(f"nak:{delay}")

    async def term(self) -> None:
        self.actions.append("term")


class FakeSub:
    def __init__(self, msgs: list[FakeMsg]) -> None:
        self.msgs = msgs

    async def fetch(self, batch: int, timeout: float) -> list[FakeMsg]:
        return self.msgs


@pytest.fixture
def tables():
    engine = create_engine(ADMIN_URL, future=True)
    md = MetaData(schema="consumer_test")
    consumed, dead = consumed_table(md, "consumer_test"), dead_table(md, "consumer_test")
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA IF EXISTS consumer_test CASCADE"))
        c.execute(text("CREATE SCHEMA consumer_test"))
    md.create_all(engine)
    yield sessionmaker(bind=engine), consumed, dead
    with engine.begin() as c:
        c.execute(text("DROP SCHEMA consumer_test CASCADE"))
    engine.dispose()


def good_event() -> bytes:
    return encode(uuid.uuid4(), "t.v1", "s", datetime.now(UTC), {"x": 1})


def run(consumer: Consumer, msgs: list[FakeMsg]) -> int:
    consumer._sub = FakeSub(msgs)  # type: ignore[assignment]
    return asyncio.run(consumer.run_once(None))  # type: ignore[arg-type]


def test_an_undecodable_message_is_dead_lettered_and_terminated_not_crashed(tables, caplog):
    factory, consumed, dead = tables
    c = Consumer("m", "t.v1", lambda s, e: None, factory, consumed, dead)
    bad = FakeMsg(b"not json")
    missing = FakeMsg(json.dumps({"id": "x"}).encode())
    good = FakeMsg(good_event())
    with caplog.at_level("ERROR", logger="yantra.consumer"):
        assert run(c, [bad, missing, good]) == 1
    assert bad.actions == ["term"] and missing.actions == ["term"] and good.actions == ["ack"]
    with factory() as s:
        rows = s.execute(select(dead.c.reason, dead.c.deliveries)).all()
    assert len(rows) == 2 and all(r.reason.startswith("undecodable") for r in rows)
    assert caplog.text.count("dead-lettered") == 2


def test_the_last_failed_delivery_is_dead_lettered_and_earlier_ones_are_naked(tables, caplog):
    factory, consumed, dead = tables

    def boom(s, e):
        raise RuntimeError("db away")

    c = Consumer("m", "t.v1", boom, factory, consumed, dead, nak_delay=0.1)
    first, last = FakeMsg(good_event(), delivered=1), FakeMsg(good_event(), delivered=DEAD_LETTER_AFTER)
    with caplog.at_level("ERROR", logger="yantra.consumer"):
        assert run(c, [first, last]) == 0
    assert first.actions == ["nak:0.1"] and last.actions == ["term"]
    assert [c.redelivery_delay(n) for n in (1, 2, 3, 15)] == [0.1, 0.2, 0.4, 1638.4]
    assert Consumer("m", "t", boom, factory, consumed, dead).redelivery_delay(20) == 3600.0
    with factory() as s:
        [row] = s.execute(select(dead.c.deliveries, dead.c.reason, dead.c.consumer)).all()
    assert row.deliveries == DEAD_LETTER_AFTER and row.reason == "RuntimeError: db away" and row.consumer == "m-t-v1"
    assert "handler failed" in caplog.text and "dead-lettered" in caplog.text


def test_a_dead_letter_that_cannot_be_stored_is_naked_for_redelivery_never_dropped(tables, caplog, monkeypatch):
    factory, consumed, dead = tables

    def boom(s, e):
        raise RuntimeError("handler down")

    assert MAX_DELIVER > DEAD_LETTER_AFTER  # the server redelivers past the dead-letter threshold
    c = Consumer("m", "t.v1", boom, factory, consumed, dead, nak_delay=0.1)
    real = c.dead_letter

    def store_down(*_a: object) -> None:
        from sqlalchemy.exc import OperationalError

        raise OperationalError("insert", {}, Exception("db away"))

    monkeypatch.setattr(c, "dead_letter", store_down)
    last, undecodable = FakeMsg(good_event(), delivered=DEAD_LETTER_AFTER), FakeMsg(b"not json")
    with caplog.at_level("ERROR", logger="yantra.consumer"):
        assert run(c, [last, undecodable]) == 0
    assert last.actions[0].startswith("nak:") and undecodable.actions == ["nak:0.1"]
    assert "dead letter not stored" in caplog.text
    monkeypatch.setattr(c, "dead_letter", real)
    again = FakeMsg(last.data, delivered=DEAD_LETTER_AFTER + 1)  # the redelivery is stored and terminated
    assert run(c, [again]) == 0 and again.actions == ["term"]
    repeat = FakeMsg(last.data, delivered=DEAD_LETTER_AFTER + 2)  # stored already: terminated, not naked forever
    assert run(c, [repeat]) == 0 and repeat.actions == ["term"]
    with factory() as s:
        assert len(s.execute(select(dead.c.id)).all()) == 1


def test_a_validation_error_is_logged_without_the_payload(tables, caplog):
    from pydantic import BaseModel

    class Strict(BaseModel):
        n: int

    factory, consumed, dead = tables
    c = Consumer(
        "m", "t.v1", lambda s, e: Strict.model_validate({"n": "secret-text"}), factory, consumed, dead, nak_delay=0
    )
    msg = FakeMsg(good_event())
    with caplog.at_level("ERROR", logger="yantra.consumer"):
        run(c, [msg])
    assert msg.actions == ["nak:0.0"] and "ValidationError" in caplog.text and "secret-text" not in caplog.text


def test_backoff_grows_and_caps():
    assert [backoff_after(n) for n in (1, 2, 3, 6, 10)] == [2.0, 4.0, 8.0, 60.0, 60.0]


def test_a_consumer_derives_its_durable_name_unless_given_one(tables):
    factory, consumed, dead = tables
    assert Consumer("m", "a.b.v1", lambda s, e: None, factory, consumed, dead).durable == "m-a-b-v1"
    assert Consumer("m", ">", lambda s, e: None, factory, consumed, dead, durable="m-all-g1").durable == "m-all-g1"


def test_the_events_health_app_gets_the_outbox_stuck_setting(monkeypatch):
    import yantra_common.app as app_module
    from yantra_common.consumer import LoopState, health_app

    seen: dict[str, object] = {}

    def fake_events_app(*args: object, **kwargs: object) -> str:
        seen.update(kwargs, args=args)
        return "app"

    monkeypatch.setattr(app_module, "events_app", fake_events_app)
    s = SimpleNamespace(outbox_stuck_seconds=42)
    state = LoopState()
    assert health_app(s, None, [], [], [], state, lambda: True) == "app"
    assert seen["outbox_stuck_after_seconds"] == 42 and seen["args"][4] is state
