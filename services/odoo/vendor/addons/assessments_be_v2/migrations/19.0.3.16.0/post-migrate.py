# -*- coding: utf-8 -*-
"""assessments_be_v2 19.0.3.16.0 post-migration: tag pre-versioning scores.

WHY (tracker SNo 124). `llm_prompt_version` records WHICH grading prompt
produced a subjective score - the other half of `llm_judge_model`, because the
same model under a different system prompt is a different rubric. Scores stored
before the field existed have nothing in it.

WHAT THIS DOES, AND THE ONE THING IT REFUSES TO DO

An empty column cannot distinguish two very different situations:

  * the score was graded before versioning shipped, and is fine;
  * the score was graded AFTER, and the stamp did not land - a bug.

They must not read alike, or the field is useless for the audit it exists for:
the first blank would train everyone to ignore blanks. So every already-scored
answer is stamped `pre-versioning` ONCE, and from then on an empty version on a
`scored` row is a defect worth chasing.

NOTHING IS RE-GRADED. No LLM call, no mark changes, no state changes - the
product decision on this row was explicit: freeze the prompt and version it
going forward. Backfilling the ACTUAL digest onto these rows would be worse
than a blank, because we cannot prove which prompt text graded them; asserting
one would be inventing provenance for a hire/reject decision.

ONLY `llm_state = 'scored'`. A pending, failed or not_needed answer has no score
to attribute, and stamping one would claim a grading that never happened - so
those stay empty and the NEXT grade fills them in properly.

Idempotent, and guarded on the column existing: safe to re-run, and a no-op on
a fresh install where there are no pre-versioning rows.
"""
import logging

_logger = logging.getLogger(__name__)

#: What a score graded before versioning is tagged with. Deliberately not a
#: digest: it is a statement about what is NOT known, not a fake measurement.
PRE_VERSIONING = "pre-versioning"


def migrate(cr, version):
    if not version:
        # Fresh install: the field arrives empty on an empty table.
        return

    cr.execute("""
        SELECT 1 FROM information_schema.columns
         WHERE table_name = 'assessments_be_response'
           AND column_name = 'llm_prompt_version'
    """)
    if not cr.fetchone():
        # The registry has not created the column yet, which means this is
        # running against a build without the field. Nothing to stamp, and
        # failing here would block an otherwise valid upgrade.
        _logger.warning(
            "assessments_be_v2: llm_prompt_version is missing, so "
            "pre-versioning scores were not tagged. Re-run the upgrade once "
            "the field exists.")
        return

    cr.execute("""
        UPDATE assessments_be_response
           SET llm_prompt_version = %s
         WHERE llm_state = 'scored'
           AND COALESCE(llm_prompt_version, '') = ''
    """, (PRE_VERSIONING,))
    tagged = cr.rowcount or 0
    _logger.info(
        "assessments_be_v2: tagged %d already-scored answer(s) as %r. No "
        "answer was re-graded and no mark changed - the prompt that graded "
        "them is not recoverable, so it is recorded as unknown rather than "
        "guessed.", tagged, PRE_VERSIONING)
