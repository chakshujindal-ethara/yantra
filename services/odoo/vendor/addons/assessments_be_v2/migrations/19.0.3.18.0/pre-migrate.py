"""Index the foreign keys on the hot tables, without locking any of them.

THE SWEEP, not one fix. `assessments_be_response_line.response_id` was the row
that started this (SNo 127), but a catalogue query for foreign keys with no
leading index returned THIRTEEN across this addon - including
`assessments_be_response.evaluator_id`, which is `required=True` on the answers
table. Fixing the one that was noticed and leaving twelve would have left the
same defect under a different name, so the whole class is handled here.

NINE OF THIRTEEN, AND THE OTHER FOUR ON PURPOSE. An index is not free: it is a
B-tree insert on every row written, and cutting write cost is the whole point of
the surrounding work. So the test is whether the column is read on a path that
scales with CANDIDATES:

    indexed here                                 why
    response.evaluator_id                        every per-candidate answer read
    response_line.response_id                    every answer's lines; cascade re-scans
    response_line.question_dimension_id          restrict => a scan to prove deletable
    response_line.selected_option_id             same, and provoked by ordinary bank edits
    evaluator.applicant_id                       every roster row
    question_dimension.question_id               every question served
    question_dimension_option.question_dimension_id  every dimension served
    question_image.question_id                   every media question served
    question_video.question_id                   every media question served
    llm_usage.evaluator_id                       the per-candidate spend cap, per call

    NOT indexed                                  why not
    assessments.generator_id                     a handful of rows, read by an admin
    prompt_question.prompt_id                    generation-time, not exam-time
    prompt_question.approved_question_id         same
    prompt_resource.prompt_id                    same

CONCURRENTLY, AND WHY `cr.commit()` IS NOT ENOUGH. Verbatim the mechanism proved
in 19.0.3.17.0: a plain `CREATE INDEX` holds a SHARE lock for the whole build and
blocks every write to the table, and `CREATE INDEX CONCURRENTLY` cannot run
inside a transaction block. Odoo runs migrations inside the upgrade transaction,
and `cr.commit()` alone does NOT help because psycopg2 opens a fresh transaction
on the next execute - measured, not assumed. Autocommit for the statement is what
works, and the previous isolation level is restored afterwards so later
migrations in the same run stay transactional.

FAILURE DEGRADES, IT DOES NOT ABORT. Every column below also carries
`index=True`, so if a concurrent build fails Odoo's own schema step creates the
index the ordinary way later in this same upgrade. The bad outcome is a brief
lock, never a missing index and never a failed upgrade. Each index is attempted
independently for the same reason: one failure must not skip the other eight.
"""
import logging

from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT

_logger = logging.getLogger(__name__)

# (table, column). The index name follows Odoo's own convention so its schema
# step recognises what is already there and does not build a second one.
TARGETS = [
    ("assessments_be_response", "evaluator_id"),
    ("assessments_be_response_line", "response_id"),
    ("assessments_be_response_line", "question_dimension_id"),
    ("assessments_be_response_line", "selected_option_id"),
    ("assessments_be_evaluator", "applicant_id"),
    ("assessments_be_question_dimension", "question_id"),
    ("assessments_be_question_dimension_option", "question_dimension_id"),
    ("assessments_be_question_image", "question_id"),
    ("assessments_be_question_video", "question_id"),
    ("assessments_be_llm_usage", "evaluator_id"),
]


def _index_name(table, column):
    return "%s__%s_index" % (table, column)


def _needs_build(cr, table, index):
    """True when `index` should be built. Drops an INVALID leftover first."""
    cr.execute(
        "SELECT 1 FROM information_schema.tables WHERE table_name = %s",
        (table,))
    if not cr.fetchone():
        return False

    cr.execute(
        """
        SELECT i.indisvalid
          FROM pg_class c
          JOIN pg_index i ON i.indexrelid = c.oid
         WHERE c.relname = %s
        """,
        (index,))
    row = cr.fetchone()
    if row and row[0]:
        return False
    if row and not row[0]:
        # An interrupted CONCURRENTLY build leaves an index Postgres will
        # neither use nor let us replace.
        _logger.warning("%s exists but is INVALID; dropping before rebuild",
                        index)
        cr.execute("DROP INDEX IF EXISTS %s" % index)
    return True


def migrate(cr, version):
    if not version:
        # A fresh install: the field declarations create every index, and the
        # tables do not exist yet anyway.
        return

    pending = [(t, c, _index_name(t, c)) for t, c in TARGETS]
    pending = [(t, c, i) for t, c, i in pending if _needs_build(cr, t, i)]
    if not pending:
        _logger.info("every hot-path foreign key is already indexed")
        return

    # Publishes only what the PREVIOUS version had already committed: a
    # pre-migrate runs before this version's schema and data steps, so nothing
    # of ours is half-written here.
    cr.commit()
    previous_level = cr._cnx.isolation_level
    built, failed = 0, 0
    try:
        cr._cnx.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
        for table, column, index in pending:
            try:
                cr.execute(
                    "CREATE INDEX CONCURRENTLY IF NOT EXISTS %s ON %s (%s)"
                    % (index, table, column))
                built += 1
                _logger.info("built %s CONCURRENTLY", index)
            except Exception:  # noqa: BLE001 - never abort an upgrade for this
                failed += 1
                _logger.warning(
                    "could not build %s concurrently; the ordinary schema step "
                    "will create it during this upgrade instead (a brief SHARE "
                    "lock on %s)", index, table, exc_info=True)
    finally:
        try:
            cr._cnx.set_isolation_level(previous_level)
        except Exception:  # noqa: BLE001
            _logger.exception(
                "could not restore the connection isolation level; later "
                "migrations in this run may not be transactional")
    _logger.info("hot-path indexes: %d built concurrently, %d deferred to the "
                 "schema step", built, failed)
