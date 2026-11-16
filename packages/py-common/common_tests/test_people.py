"""Display names: cleaning, the header dependency, the kind of a caller, and the read model a module keeps."""

import os
import uuid
from datetime import UTC, datetime
from urllib.parse import quote

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import MetaData, create_engine, select, text
from sqlalchemy.orm import sessionmaker

from yantra_common.events import Envelope
from yantra_common.people import Name, clean_name, kind_of, name_of, names_of, on_person_seen, person_table
from yantra_common.testing import ADMIN_URL

SCHEMA = "people_test" + os.environ.get("YANTRA_TEST_DB_SUFFIX", "")


def test_clean_name_collapses_spaces_drops_controls_and_caps():
    assert clean_name("  Asha \t  Rani\n") == "Asha Rani"
    assert clean_name("a\x00b​c") == "abc"  # NUL and a zero-width space are format/control characters
    assert clean_name("   ") is None and clean_name(None) is None
    assert clean_name("x" * 300) == "x" * 120


def test_kind_of_ranks_staff_then_client_then_worker():
    assert kind_of({"worker", "finance"}) == "staff"
    assert kind_of({"admin"}) == "staff"
    assert kind_of({"client"}) == "client"
    assert kind_of({"worker", "reviewer"}) == "worker"
    assert kind_of(set()) == "worker"


def test_the_name_header_is_percent_decoded_and_cleaned():
    app = FastAPI()

    @app.get("/me")  # type: ignore[misc]
    def me(name: Name) -> dict[str, str | None]:
        return {"name": name}

    client = TestClient(app)
    assert client.get("/me", headers={"X-Name": quote("आशा  रानी", safe="")}).json() == {"name": "आशा रानी"}
    assert client.get("/me").json() == {"name": None}
    assert client.get("/me", headers={"X-Name": "%20"}).json() == {"name": None}


def _env(data: dict[str, object]) -> Envelope:
    return Envelope(
        id=uuid.uuid4(), type="talent.person.seen.v1", subject="s", occurred_at=datetime.now(UTC), data=data
    )


def test_the_read_model_keeps_forgets_and_reads_names_in_one_query():
    engine = create_engine(ADMIN_URL, future=True)
    md = MetaData(schema=SCHEMA)
    table = person_table(md, SCHEMA)
    with engine.begin() as c:
        c.execute(text(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE"))
        c.execute(text(f"CREATE SCHEMA {SCHEMA}"))
    md.create_all(engine)
    a, b = uuid.uuid4(), uuid.uuid4()
    handler = on_person_seen(table)
    try:
        with sessionmaker(bind=engine)() as s:
            handler(s, _env({"id": str(a), "name": "  Asha  Rani ", "kind": "worker"}))
            handler(s, _env({"id": str(b), "name": "Ops One", "kind": "staff"}))
            s.commit()
            people = names_of(s, table, [a, b, uuid.uuid4(), None])
            assert {k: (p.name, p.kind) for k, p in people.items()} == {
                a: ("Asha Rani", "worker"),
                b: ("Ops One", "staff"),
            }
            assert name_of(people, a) == "Asha Rani" and name_of(people, None) is None
            assert name_of(people, uuid.uuid4()) is None
            assert names_of(s, table, []) == {}
            handler(s, _env({"id": str(a), "name": None, "kind": "worker"}))  # erasure: forget the name
            s.commit()
            assert s.scalar(select(table.c.name).where(table.c.id == a)) is None
            with pytest.raises(ValueError, match="kind"):
                handler(s, _env({"id": str(a), "name": "x", "kind": "robot"}))
    finally:
        with engine.begin() as c:
            c.execute(text(f"DROP SCHEMA {SCHEMA} CASCADE"))
        engine.dispose()
