"""Index `assessments_be_response.assessment_id` without locking the table.

WHY A MIGRATION AND NOT JUST `index=True`. The field declaration is there too,
and it is what a fresh install uses. But on an EXISTING database Odoo's own
schema step issues a plain `CREATE INDEX`, which takes a SHARE lock on the
table for the whole build - and that blocks every INSERT and UPDATE to the
answers table while it runs. On the live database that table is the one a
sitting writes to on every question, so a plain build during `-u` stalls any
exam in progress. `CONCURRENTLY` does not take that lock.

WHY AUTOCOMMIT AND NOT JUST `cr.commit()`. Measured on this codebase, not
assumed:

    ActiveSqlTransaction: CREATE INDEX CONCURRENTLY cannot run inside a
    transaction block

Odoo runs migrations inside the upgrade transaction. `cr.commit()` alone does
NOT fix it - psycopg2 opens a fresh transaction on the very next `execute`, so
the statement still lands inside a block. That was the first attempt here and it
failed exactly that way. What works is putting the underlying connection into
ISOLATION_LEVEL_AUTOCOMMIT for the one statement, then restoring the level it
had.

The commit before that is still needed, and is safe HERE in a way it would not
be in a post-migrate: a pre-migrate runs before this version's schema changes
and before any data migration, so it publishes only what the previous version
had already committed. Nothing of ours is half-written at this point.

IF IT FAILS, THE UPGRADE STILL SUCCEEDS. A missing index is a slow query, not a
broken one, and Odoo's own schema step will create the index the ordinary way
afterwards because the field carries `index=True`. So a failure here degrades to
"the plain build happens" rather than "the upgrade aborts" - which is the right
trade for a performance change. The one case worth catching explicitly is a
previous run that was interrupted: `CONCURRENTLY` leaves an INVALID index
behind, and Postgres will not replace it, so it is dropped first.
"""
import logging

from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT

_logger = logging.getLogger(__name__)

TABLE = "assessments_be_response"
INDEX = "assessments_be_response__assessment_id_index"


def migrate(cr, version):
    if not version:
        # A fresh install: the field declaration creates the index, and the
        # table does not exist yet anyway.
        return

    cr.execute(
        "SELECT 1 FROM information_schema.tables WHERE table_name = %s",
        (TABLE,))
    if not cr.fetchone():
        return

    # ALREADY THERE AND VALID: nothing to do. Checked before the commit so the
    # ordinary case does not commit at all.
    cr.execute(
        """
        SELECT c.relname, i.indisvalid
          FROM pg_class c
          JOIN pg_index i ON i.indexrelid = c.oid
         WHERE c.relname = %s
        """,
        (INDEX,))
    row = cr.fetchone()
    if row and row[1]:
        _logger.info("%s already present and valid; nothing to do", INDEX)
        return

    # An interrupted CONCURRENTLY build leaves an INVALID index that Postgres
    # will neither use nor let us replace. Drop it before rebuilding.
    if row and not row[1]:
        _logger.warning(
            "%s exists but is INVALID (an earlier CONCURRENTLY build was "
            "interrupted); dropping it before rebuilding", INDEX)
        cr.execute("DROP INDEX IF EXISTS %s" % INDEX)

    # See the docstring: CONCURRENTLY needs the connection OUT of a transaction
    # block, which means autocommit for this one statement - `cr.commit()` on its
    # own is not enough.
    cr.commit()
    previous_level = cr._cnx.isolation_level
    try:
        cr._cnx.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
        cr.execute(
            "CREATE INDEX CONCURRENTLY IF NOT EXISTS %s ON %s (assessment_id)"
            % (INDEX, TABLE))
        _logger.info("built %s CONCURRENTLY", INDEX)
    except Exception:  # noqa: BLE001 - a slow query must not abort an upgrade
        _logger.warning(
            "could not build %s concurrently; the ordinary schema step will "
            "create it during this upgrade instead (it takes a brief SHARE "
            "lock on %s)", INDEX, TABLE, exc_info=True)
    finally:
        # RESTORE THE LEVEL WHATEVER HAPPENED. Leaving the upgrade's connection
        # in autocommit would silently remove transactionality from every
        # migration that runs after this one.
        try:
            cr._cnx.set_isolation_level(previous_level)
        except Exception:  # noqa: BLE001
            _logger.exception(
                "could not restore the connection isolation level after "
                "building %s; the upgrade continues but later migrations in "
                "this run may not be transactional", INDEX)
