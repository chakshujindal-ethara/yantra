# -*- coding: utf-8 -*-
"""assessments_be_v2 19.0.3.7.0 pre-migration: retire `image_label_2`.

WHY THIS EXISTS. 19.0.3.7.0 removes `image_label_2` from
`constants.QUESTION_TYPE_SELECTION`. Odoo does NOT rewrite stored rows when a
Selection shrinks: the old string stays in the column, so without this script an
upgraded database keeps questions, drafts and generators stamped with a code that
nothing in the module answers to any more. Such a row is worse than broken - it is
INVISIBLE. It renders blank in the form (no matching selection label), matches no
branch of any `question_type in (...)` guard in scoring, serving or the portal, and
so falls through every lane silently: the question is served with no media handling,
graded with no rubric, and reported with no error. The failure looks like an empty
screen, not like a stack trace.

It must run PRE-migrate, before the registry loads the new (shorter) Selection and
before `assessments.be.question.type::init()` re-syncs the vocabulary, because once
the column's constraint set has shrunk the old value can no longer be reasoned about
from Python - only raw SQL still sees it.

WHY `image_label` IS THE TARGET. `image_label_2` was the two-plate variant: a clean
Reference plate plus a pre-marked Single plate. Its marked plate has always lived in
the SAME `single` slot that `image_label` reads, its answer key has always been the
same marker-keyed JSON, and its candidate answer has always been the same box-number
map. Repointing therefore preserves the answer key, the stored responses and the
scoring path; only the clean Reference plate stops being rendered beside the marked
one. Those Reference rows are left in place on purpose (see below).

The Reference image rows are NOT deleted. The `reference` slot is still a live value
- `image_prompt` uses it for its input plate - so the rows remain valid data, and an
operator who wants the clean plate back has it. `image_label` simply does not read
that slot, so it is inert rather than lost. Deleting operator-supplied media in a
migration is not reversible; leaving it is.

Guarded throughout: every statement checks the table/column exists first, so the
script is a no-op on a fresh install and safe to re-run.
"""
import logging

_logger = logging.getLogger(__name__)

OLD_TYPE = "image_label_2"
NEW_TYPE = "image_label"

# (table, column) pairs holding a stored copy of the question-type code.
# question_image.question_type is a stored `related` mirror of its parent
# question, so it carries the stale value independently and must be repointed
# too - a recompute would fix it, but only for rows Odoo happens to touch.
TYPE_COLUMNS = [
    ("assessments_be_question", "question_type"),
    ("assessments_be_question_image", "question_type"),
    ("assessments_be_prompt_question", "question_type"),
    ("assessments_be_prompt", "force_question_type"),
]


def _column_exists(cr, table, column):
    cr.execute(
        "SELECT 1 FROM information_schema.columns "
        "WHERE table_name = %s AND column_name = %s",
        (table, column),
    )
    return bool(cr.fetchone())


def _table_exists(cr, table):
    cr.execute(
        "SELECT 1 FROM information_schema.tables WHERE table_name = %s",
        (table,),
    )
    return bool(cr.fetchone())


def migrate(cr, version):
    # `version` is falsy on a fresh install - there is nothing to repoint.
    if not version:
        return

    for table, column in TYPE_COLUMNS:
        if not _column_exists(cr, table, column):
            continue
        cr.execute(
            "UPDATE {t} SET {c} = %s WHERE {c} = %s".format(t=table, c=column),
            (NEW_TYPE, OLD_TYPE),
        )
        if cr.rowcount:
            _logger.info(
                "assessments_be_v2 19.0.3.7.0: repointed %d row(s) in %s.%s "
                "from %r to %r.",
                cr.rowcount, table, column, OLD_TYPE, NEW_TYPE,
            )

    # The generation vocabulary row. init() only ARCHIVES a non-generatable code;
    # with the code gone from the Selection entirely the row is dead reference data
    # and would keep showing up in the allow-list widget with `active_test=False`.
    if not _table_exists(cr, "assessments_be_question_type"):
        return
    cr.execute(
        "SELECT id FROM assessments_be_question_type WHERE code = %s",
        (OLD_TYPE,),
    )
    stale_ids = [row[0] for row in cr.fetchall()]
    if not stale_ids:
        return

    # Drop the m2m links FIRST (the FK points at the row we are about to delete).
    # The links are DELETED rather than repointed at the image_label row on
    # purpose: a generator that allowed both codes would collide on the m2m's
    # unique pair, and repointing would silently WIDEN an operator's allow-list
    # to a type they never ticked. An emptied allow-list means "model chooses
    # freely", which is the documented default, not a broken state.
    if _table_exists(cr, "assessments_be_prompt_allowed_qtype_rel"):
        cr.execute(
            "DELETE FROM assessments_be_prompt_allowed_qtype_rel "
            "WHERE qtype_id IN %s",
            (tuple(stale_ids),),
        )
        if cr.rowcount:
            _logger.info(
                "assessments_be_v2 19.0.3.7.0: dropped %d generator "
                "allow-list link(s) to the %r vocabulary row.",
                cr.rowcount, OLD_TYPE,
            )

    # ir_model_data would otherwise keep an external id pointing at a missing row
    # and abort a later upgrade with a MissingError.
    cr.execute(
        "DELETE FROM ir_model_data WHERE model = %s AND res_id IN %s",
        ("assessments.be.question.type", tuple(stale_ids)),
    )
    cr.execute(
        "DELETE FROM assessments_be_question_type WHERE id IN %s",
        (tuple(stale_ids),),
    )
    _logger.info(
        "assessments_be_v2 19.0.3.7.0: deleted %d %r vocabulary row(s).",
        len(stale_ids), OLD_TYPE,
    )
