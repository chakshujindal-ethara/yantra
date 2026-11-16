"""The engine never copies statement parameters into an error: a dead letter's reason or a job's last error keeps
the SQL shape, never a value a caller sent."""

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from yantra_common.db import make_engine
from yantra_common.testing import ADMIN_URL


def test_a_database_error_carries_no_parameter_values():
    engine = make_engine(ADMIN_URL, pool_size=1)
    try:
        with engine.connect() as c, pytest.raises(DBAPIError) as e:
            c.execute(text("SELECT CAST(:secret AS text), 1 / 0"), {"secret": "PAN-ABCDE1234F"})
        assert "PAN-ABCDE1234F" not in str(e.value)
        assert "hidden due to hide_parameters" in str(e.value)
    finally:
        engine.dispose()


def test_the_pool_is_sized_from_the_environment_unless_the_caller_says_otherwise(monkeypatch):
    from yantra_common.db import DbPoolSettings

    defaults = DbPoolSettings()
    assert (defaults.pool_size, defaults.max_overflow, defaults.pool_timeout) == (10, 10, 10.0)
    # four database processes (two APIs, two events) at their ceiling leave a fifth of the rig's 100 connections
    assert 4 * (defaults.pool_size + defaults.max_overflow) + 20 <= 100
    monkeypatch.setenv("YANTRA_DB_POOL_SIZE", "12")
    monkeypatch.setenv("YANTRA_DB_MAX_OVERFLOW", "3")
    monkeypatch.setenv("YANTRA_DB_POOL_TIMEOUT", "2.5")
    engine = make_engine(ADMIN_URL)
    try:
        pool = engine.pool
        assert (pool.size(), pool._max_overflow, pool._timeout) == (12, 3, 2.5)
    finally:
        engine.dispose()
    explicit = make_engine(ADMIN_URL, pool_size=1)  # the test databases size their own pool
    try:
        assert (explicit.pool.size(), explicit.pool._max_overflow) == (1, 3)
    finally:
        explicit.dispose()
