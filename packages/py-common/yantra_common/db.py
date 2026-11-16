"""One engine per process, one session per unit of work. Services never share a session across modules.
Every connection carries a statement timeout and a lock timeout, so a stuck row never pins a request thread.
Statement parameters are never rendered into an error, so `str(error)` is safe to store and log.

The pool is sized from `YANTRA_DB_POOL_SIZE`, `YANTRA_DB_MAX_OVERFLOW` and `YANTRA_DB_POOL_TIMEOUT` (seconds a
request waits for a free connection before failing). Every process may open up to pool + overflow connections, so:

    processes x (pool_size + max_overflow) + reserve <= max_connections

The rig: four database processes (work and money APIs, work and money events) x (10 + 10) = 80, leaving 20 of
Postgres's 100 for migrations, Odoo and an operator's shell. More replicas means a smaller pool or a pooler."""

from collections.abc import Iterator
from contextlib import contextmanager

from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session, sessionmaker

CONNECT_ARGS = {"connect_timeout": 5, "options": "-c statement_timeout=5000 -c lock_timeout=2000"}


class DbPoolSettings(BaseSettings):
    """The connection pool, read here rather than in the process settings so every engine is sized alike."""

    model_config = SettingsConfigDict(env_prefix="YANTRA_DB_", extra="ignore")

    pool_size: int = 10
    max_overflow: int = 10
    pool_timeout: float = 10.0


def make_engine(
    url: str, pool_size: int | None = None, max_overflow: int | None = None, pool_timeout: float | None = None
) -> Engine:
    """An engine with the pool the environment sets; an argument given here wins over its setting."""
    pool = DbPoolSettings()
    return create_engine(
        url,
        pool_size=pool.pool_size if pool_size is None else pool_size,
        max_overflow=pool.max_overflow if max_overflow is None else max_overflow,
        pool_timeout=pool.pool_timeout if pool_timeout is None else pool_timeout,
        pool_pre_ping=True,
        future=True,
        connect_args=CONNECT_ARGS,
        hide_parameters=True,  # an error's text (a dead letter's reason, a job's last error) carries no bound value
    )


def make_session_factory(engine: Engine) -> sessionmaker[Session]:
    return sessionmaker(bind=engine, expire_on_commit=False, future=True)


@contextmanager
def unit_of_work(factory: sessionmaker[Session]) -> Iterator[Session]:
    """Commit on success, roll back on any error. Partial writes never survive."""
    session = factory()
    try:
        yield session
        session.commit()
    except BaseException:
        session.rollback()
        raise
    finally:
        session.close()
