"""The in-image migration runner: every named module to head, an unknown one refused before anything runs."""

import os
from pathlib import Path

import pytest
from sqlalchemy import create_engine, inspect, text

from yantra_common import migrate
from yantra_common.testing import ADMIN_URL

ROOT = Path(__file__).resolve().parents[3] / "services"
DB = "yantra_migrate_test" + os.environ.get("YANTRA_TEST_DB_SUFFIX", "")  # parallel runs never collide


@pytest.fixture
def url():
    admin = create_engine(ADMIN_URL, isolation_level="AUTOCOMMIT", future=True)
    with admin.connect() as c:
        c.execute(text(f"DROP DATABASE IF EXISTS {DB} WITH (FORCE)"))
        c.execute(text(f"CREATE DATABASE {DB}"))
    yield ADMIN_URL.rsplit("/", 1)[0] + "/" + DB
    with admin.connect() as c:
        c.execute(text(f"DROP DATABASE IF EXISTS {DB} WITH (FORCE)"))
    admin.dispose()


def test_upgrade_migrates_each_named_module(url):
    assert migrate.upgrade(["notify", "assess"], ROOT, url) == ["notify", "assess"]
    engine = create_engine(url, future=True)
    try:
        names = inspect(engine).get_schema_names()
        assert {"notify", "assess"} <= set(names) and "market" not in names
    finally:
        engine.dispose()


def test_an_unknown_module_fails_before_any_migration(url):
    with pytest.raises(FileNotFoundError, match="nowhere"):
        migrate.upgrade(["notify", "nowhere"], ROOT, url)
    engine = create_engine(url, future=True)
    try:
        assert "notify" not in inspect(engine).get_schema_names()
    finally:
        engine.dispose()


def test_main_reads_the_root_and_defaults_to_every_module(monkeypatch, tmp_path):
    seen = {}
    monkeypatch.setattr(migrate, "upgrade", lambda modules, root: seen.update(modules=modules, root=root))
    monkeypatch.setenv("YANTRA_SERVICES_ROOT", str(tmp_path))
    assert migrate.main([]) == 0 and seen == {"modules": list(migrate.MODULES), "root": tmp_path}
    assert migrate.main(["market"]) == 0 and seen["modules"] == ["market"]


def test_main_in_a_deployed_environment_needs_only_the_database_url(url, monkeypatch):
    """The hook Job gets YANTRA_ENV, YANTRA_SERVICES_ROOT and YANTRA_DATABASE_URL only: no PII or bank key, and the
    owner's password may be anything. Migrations never load the process settings or their rig-secrets guard."""
    for name in [k for k in os.environ if k.startswith("YANTRA_") and k != "YANTRA_TEST_DB_SUFFIX"]:
        monkeypatch.delenv(name)
    monkeypatch.setenv("YANTRA_ENV", "staging")
    monkeypatch.setenv("YANTRA_SERVICES_ROOT", str(ROOT))
    monkeypatch.setenv("YANTRA_DATABASE_URL", url)
    assert migrate.main(["notify"]) == 0
    engine = create_engine(url, future=True)
    try:
        assert "notify" in inspect(engine).get_schema_names()
    finally:
        engine.dispose()


def test_main_without_a_database_url_names_the_setting(monkeypatch):
    monkeypatch.delenv("YANTRA_DATABASE_URL", raising=False)
    monkeypatch.setenv("YANTRA_SERVICES_ROOT", str(ROOT))
    with pytest.raises(RuntimeError, match="YANTRA_DATABASE_URL"):
        migrate.main(["notify"])
