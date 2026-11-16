"""Display names without a shared table. The gateway forwards the token's name in `X-Name` (percent-encoded UTF-8,
so a Devanagari name survives an ASCII header); talent records each person on first sight and announces it with
`talent.person.seen.v1`; every module that shows names keeps its own `person` read model from that event, the way
`worker_gate` is kept. A module reads only its own schema, so a list carries names with one `IN` query.

A name is a display string only: never an identity, never logged."""

import re
import unicodedata
import uuid
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from typing import Annotated, Literal, get_args
from urllib.parse import unquote

from fastapi import Depends, Header
from sqlalchemy import CheckConstraint, Column, DateTime, MetaData, String, Table, Text, Uuid, func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session

from yantra_common.events import Envelope

Kind = Literal["worker", "staff", "client"]
KINDS = get_args(Kind)
MAX_NAME = 120
STAFF_ROLES = frozenset({"admin", "ops", "finance"})
_SPACES = re.compile(r"\s+")


@dataclass(frozen=True)
class Person:
    name: str | None
    kind: str


def person_table(metadata: MetaData, schema: str) -> Table:
    """`source` says where the name came from: `token` (the identity provider) or `profile` (the worker's legal
    name, which a later token name never overwrites)."""
    return Table(
        "person",
        metadata,
        Column("id", Uuid, primary_key=True),
        Column("name", Text),
        Column("kind", String(10), nullable=False),
        Column("source", String(10), nullable=False, server_default="token"),
        Column("seen_at", DateTime(timezone=True), nullable=False, server_default=func.now()),
        CheckConstraint(f"kind in {KINDS}", name="person_kind"),
        CheckConstraint("source in ('token', 'profile')", name="person_source"),
        schema=schema,
    )


def kind_of(roles: Iterable[str]) -> Kind:
    held = frozenset(roles)
    if held & STAFF_ROLES:
        return "staff"
    return "client" if "client" in held else "worker"


def clean_name(raw: str | None) -> str | None:
    """Whitespace collapsed, control characters dropped, capped; an empty result is no name."""
    if raw is None:
        return None
    text = "".join(ch for ch in raw if unicodedata.category(ch)[0] != "C")
    text = _SPACES.sub(" ", text).strip()[:MAX_NAME].strip()
    return text or None


def name_header(x_name: Annotated[str | None, Header(alias="X-Name")] = None) -> str | None:
    """The caller's display name as the gateway forwarded it, decoded and cleaned; None when absent."""
    return clean_name(unquote(x_name)) if x_name else None


Name = Annotated[str | None, Depends(name_header)]


def upsert_person(session: Session, table: Table, person_id: uuid.UUID, name: str | None, kind: str) -> None:
    stmt = pg_insert(table).values(id=person_id, name=name, kind=kind)
    session.execute(
        stmt.on_conflict_do_update(
            index_elements=["id"], set_={"name": stmt.excluded.name, "kind": stmt.excluded.kind, "seen_at": func.now()}
        )
    )


def on_person_seen(table: Table) -> Callable[[Session, Envelope], None]:
    """The consumer a module registers for `talent.person.seen.v1` (`{id, name, kind}`): keep or forget the name.
    The payload is read here directly: py-common does not depend on the contracts package."""

    def handler(session: Session, env: Envelope) -> None:
        kind = str(env.data["kind"])
        if kind not in KINDS:
            raise ValueError(f"unknown person kind {kind!r}")
        upsert_person(session, table, uuid.UUID(str(env.data["id"])), clean_name(env.data.get("name")), kind)

    return handler


def names_of(session: Session, table: Table, ids: Iterable[uuid.UUID | None]) -> dict[uuid.UUID, Person]:
    """The known people among `ids`, in one query; unknown ids are absent."""
    wanted = {i for i in ids if i is not None}
    if not wanted:
        return {}
    rows = session.execute(select(table.c.id, table.c.name, table.c.kind).where(table.c.id.in_(wanted)))
    return {r.id: Person(r.name, r.kind) for r in rows}


def name_of(people: dict[uuid.UUID, Person], person_id: uuid.UUID | None) -> str | None:
    found = people.get(person_id) if person_id is not None else None
    return found.name if found is not None else None
