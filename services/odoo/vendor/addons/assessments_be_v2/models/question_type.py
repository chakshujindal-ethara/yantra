# -*- coding: utf-8 -*-
"""The question-type vocabulary — the GENERATABLE question types as rows.

Generators pick a subset of these via a Many2many (allowed_question_type_ids) to
restrict what a generation run may author. The rows mirror
constants.QUESTION_TYPE_SELECTION minus NON_GENERATABLE_QUESTION_TYPES, seeded in
init() so the taxonomy stays a single code-level constant and no second
vocabulary can drift away from it. There is no menu/action for this model on
purpose — it is reference data, not user-editable.
"""

import logging

from odoo import models, fields

from ..constants import (
    QUESTION_TYPE_SELECTION, NON_GENERATABLE_QUESTION_TYPES)

_logger = logging.getLogger(__name__)


class EtpAssessmentQuestionType(models.Model):
    _name = "assessments.be.question.type"
    _description = "Assessment Question Type (generation vocabulary)"
    _order = "sequence, id"

    code = fields.Char(
        string="Code", required=True, index=True,
        help="Stable taxonomy code - one of constants.QUESTION_TYPE_SELECTION.")
    name = fields.Char(string="Name", required=True, translate=False)
    sequence = fields.Integer(default=10)
    active = fields.Boolean(default=True)

    def init(self):
        """Seed / re-sync the vocabulary from the GENERATABLE question types.

        Runs on every install and -u upgrade (after the table is created), so the
        rows and their labels always mirror the constant. Idempotent: creates a
        missing code, refreshes name/sequence for an existing one. A unique index
        on `code` (like models/assessment.py::init) guards against a duplicate
        vocabulary row — mirror of the closed enum, so uniqueness is structural.

        NON-GENERATABLE types (import-only formats) are deliberately excluded
        and ARCHIVED if a previous version seeded them: this model's only
        consumer is the generator allow-list (prompt.allowed_question_type_ids),
        and the generation pipeline has no authoring path for them. Today that
        is `transcription` (Form Studio only) - the archive pass is what makes
        retiring a type from generation a constants-only change.
        """
        self._cr.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS assessments_be_question_type_uniq_code
            ON assessments_be_question_type (code)
        """)
        Type = self.with_context(active_test=False)
        existing = {t.code: t for t in Type.search([])}
        created = 0
        wanted = [(code, label) for code, label in QUESTION_TYPE_SELECTION
                  if code not in NON_GENERATABLE_QUESTION_TYPES]
        for seq, (code, label) in enumerate(wanted, start=10):
            row = existing.get(code)
            if row:
                vals = {}
                if row.name != label:
                    vals["name"] = label
                if row.sequence != seq:
                    vals["sequence"] = seq
                if not row.active:
                    vals["active"] = True
                if vals:
                    row.write(vals)
            else:
                Type.create({"code": code, "name": label, "sequence": seq})
                created += 1
        stale = Type.browse([
            row.id for code, row in existing.items()
            if code in NON_GENERATABLE_QUESTION_TYPES and row.active])
        if stale:
            # Archive rather than unlink: a generator may already reference it.
            stale.write({"active": False})
            _logger.info(
                "assessments.be.question.type: archived %d "
                "non-generatable vocabulary row(s).", len(stale))
        if created:
            _logger.info(
                "assessments.be.question.type: seeded %d vocabulary row(s).",
                created)
