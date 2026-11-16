"""The Alembic environment every module shares. Each module's `migrations/env.py` is three lines:
    from yantra_common.migrations import run
    from yantra_quality.models import Base
    run("quality", Base.metadata)
The URL comes from `config.attributes["url"]` (tests) or from YANTRA_DATABASE_URL, read directly: the migrate Job gets
the owner's URL and nothing else (no PII or bank key), so it never loads the process settings or their rig guard."""

import os

from alembic import context
from sqlalchemy import MetaData, create_engine, text


def database_url() -> str:
    url = context.config.attributes.get("url") or os.environ.get("YANTRA_DATABASE_URL")
    if not url:
        raise RuntimeError("YANTRA_DATABASE_URL is not set: migrations need the schema owner's database URL")
    return str(url)


def run(schema: str, metadata: MetaData) -> None:
    engine = create_engine(database_url(), future=True)
    with engine.connect() as connection:
        connection.execute(text(f"CREATE SCHEMA IF NOT EXISTS {schema}"))
        connection.commit()
        context.configure(
            connection=connection,
            target_metadata=metadata,
            version_table_schema=schema,
            include_schemas=True,
            include_name=lambda name, type_, _: name == schema if type_ == "schema" else True,
        )
        with context.begin_transaction():
            context.run_migrations()
