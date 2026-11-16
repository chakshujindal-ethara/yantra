"""Test support shared by every module: a fresh database per test session, migrated with each module's own
Alembic migrations, so the migrations are under test too. Needs the local Postgres (and NATS for event tests)
from deployment/local."""

import os
import re
from collections.abc import Iterator, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import Engine, create_engine, text
from sqlalchemy.orm import Session, sessionmaker

from yantra_common.db import make_engine, make_session_factory
from yantra_common.storage import ObjectInfo, Presigned

ADMIN_URL = os.environ.get("YANTRA_TEST_ADMIN_URL", "postgresql+psycopg://yantra:yantra@localhost:5440/yantra")
NATS_URL = os.environ.get("YANTRA_TEST_NATS_URL", "nats://localhost:4223")  # the rig's own NATS is 4222
DB_NAME = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")


def migrated_engine(alembic_inis: Path | list[Path], db_name: str, pool_size: int = 20) -> Iterator[Engine]:
    """Drop and recreate `db_name`, run every module's migrations to head, yield an engine. Parallel runs on one
    Postgres (several agents or CI shards) set YANTRA_TEST_DB_SUFFIX so their databases never collide."""
    db_name += os.environ.get("YANTRA_TEST_DB_SUFFIX", "")
    if not DB_NAME.match(db_name):
        raise ValueError(f"unsafe test database name: {db_name!r}")
    admin = create_engine(ADMIN_URL, isolation_level="AUTOCOMMIT", future=True)
    with admin.connect() as c:
        c.execute(text(f"DROP DATABASE IF EXISTS {db_name} WITH (FORCE)"))
        c.execute(text(f"CREATE DATABASE {db_name}"))
    admin.dispose()
    url = ADMIN_URL.rsplit("/", 1)[0] + "/" + db_name
    for ini in [alembic_inis] if isinstance(alembic_inis, Path) else alembic_inis:
        cfg = Config(str(ini))
        cfg.attributes["url"] = url
        command.upgrade(cfg, "head")
    engine = make_engine(url, pool_size=pool_size, max_overflow=0)  # a test session's share of Postgres is bounded
    yield engine
    engine.dispose()


def truncate(engine: Engine, qualified_tables: list[str]) -> None:
    with engine.begin() as c:
        c.execute(text("TRUNCATE " + ", ".join(qualified_tables)))


def database_fixtures(db_name: str, alembic_inis: list[Path], tables: list[str]) -> tuple[Any, Any, Any]:
    """The three fixtures every database-backed test module needs: engine, factory, clean_tables."""

    @pytest.fixture(scope="session")
    def engine() -> Iterator[Engine]:
        yield from migrated_engine(alembic_inis, db_name)

    @pytest.fixture(scope="session")
    def factory(engine: Engine) -> sessionmaker[Session]:
        return make_session_factory(engine)

    @pytest.fixture(autouse=True)
    def clean_tables(engine: Engine) -> Iterator[None]:
        yield
        truncate(engine, tables)

    return engine, factory, clean_tables


@dataclass
class FakeStorage:
    """An in-memory store for tests: records puts and deletes, answers HEAD from `objects`, presigns
    deterministic `fake://` URLs (never signed)."""

    bucket: str = "yantra"
    objects: dict[str, tuple[bytes, str]] = field(default_factory=dict)
    deleted: list[str] = field(default_factory=list)
    presigned: list[tuple[str, str]] = field(default_factory=list)
    put_sizes: dict[str, int | None] = field(default_factory=dict)  # key -> the size_bytes a PUT was signed for
    seconds: int = 300

    def _presign(self, method: str, key: str, headers: dict[str, str], now: datetime | None) -> Presigned:
        self.presigned.append((method, key))
        when = now or datetime.now(UTC)
        return Presigned(
            url=f"fake://{self.bucket}/{key}?method={method}",
            method=method,
            headers=headers,
            expires_at=when + timedelta(seconds=self.seconds),
        )

    def presign_put(
        self, key: str, content_type: str, max_bytes: int, *, size_bytes: int | None = None, now: datetime | None = None
    ) -> Presigned:
        self.put_sizes[key] = size_bytes
        return self._presign("PUT", key, {"content-type": content_type}, now)

    def presign_get(self, key: str, *, now: datetime | None = None) -> Presigned:
        return self._presign("GET", key, {}, now)

    def put(self, key: str, body: bytes, content_type: str) -> None:
        self.objects[key] = (body, content_type)

    def head(self, key: str) -> ObjectInfo | None:
        found = self.objects.get(key)
        return None if found is None else ObjectInfo(size=len(found[0]), content_type=found[1], etag=None)

    def delete(self, keys: Sequence[str]) -> int:
        for k in keys:
            self.objects.pop(k, None)
            self.deleted.append(k)
        return len(keys)

    def list_keys(self, prefix: str) -> list[str]:
        if not prefix.strip("/"):
            raise ValueError("list_keys needs a non-empty prefix")
        return sorted(k for k in self.objects if k.startswith(prefix))
