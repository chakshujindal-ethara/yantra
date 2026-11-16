# -*- coding: utf-8 -*-
"""Persisted SOP-similarity pairs — the Odoo analogue of the harness
``similarity.json`` ranking rows + the all-pairs ``_similarity_matrix.xlsx``.

Per research ODOO19_HANDOFF §10 "the free win": storing one record per DIRECTED
(source -> target) pair turns the matrix into a native pivot view — rows =
source, columns = target, measure = overall — with Odoo's built-in xlsx download.
That replaces the harness's hand-rolled openpyxl exporters and terminal grids.

"One thing to preserve" (§10): the matrix is NOT symmetric — each row is its own
model call, so proj-3 -> q7r and q7r -> proj-3 can differ. Both directed pairs are
stored as SEPARATE records and shown as measured, never averaged: a wide split is
a real low-confidence signal and averaging destroys it.
"""

from odoo import api, fields, models


class AssessmentSimilarity(models.Model):
    _name = "assessments.be.similarity"
    _description = "SOP Similarity (directed source -> target pair)"
    _order = "source_id, overall desc"
    _rec_name = "target_id"

    source_id = fields.Many2one(
        "assessments.be.prompt", string="Source", required=True,
        ondelete="cascade", index=True,
        help="The generator being ranked (the 'new SOP' in the mapping run).")
    target_id = fields.Many2one(
        "assessments.be.prompt", string="Compared To", required=True,
        ondelete="cascade", index=True,
        help="An existing generator the source is scored against.")

    # Scores are stored as 0-100 integers (percent) so the pivot measure reads as
    # a plain match %, matching the harness terminal + xlsx presentation.
    overall = fields.Integer(
        string="Match %", help="Blended 0.30*lexical + 0.70*semantic, 0-100. "
        "The headline closeness of source to target.")
    lexical = fields.Integer(
        string="Lexical %", help="Deterministic faceted overlap on the mapping "
        "array (free, offline, auditable).")
    semantic = fields.Integer(
        string="Semantic %", help="The model's by-meaning score under the "
        "mapping prompt; empty when only a lexical pass has run.")
    band = fields.Selection(
        [("near-duplicate", "Near-duplicate (\u226575%)"),
         ("same-family", "Same-family (40-74%)"),
         ("new-territory", "New territory (<40%)")],
        string="Band", help="A label on the number, never a shade of it: "
        "near-duplicate = probably a revision (diff before rebuilding); "
        "same-family = different task but worker pool / cutoff / renderer likely "
        "carries over; new-territory = build from scratch.")
    mode = fields.Selection(
        [("hybrid", "Hybrid (lexical + semantic)"),
         ("lexical-fallback", "Lexical fallback (semantic pass failed)"),
         ("lexical", "Lexical only (offline)")],
        string="Mode", default="lexical",
        help="Honest degradation record: a semantic pass that failed its retries "
        "degrades to lexical and is filed as 'lexical-fallback', NEVER 'hybrid', "
        "so the number is never read as blended when it is not.")
    evidence = fields.Char(
        string="Facet Evidence (computed)", help="Model-independent: what facets "
        "are shared / partial / diverging, straight from the mapping arrays.")
    why = fields.Text(
        string="Reason (model)", help="The semantic pass's plain-language reading "
        "of the pair; empty on a lexical-only row.")
    computed_on = fields.Datetime(
        string="Computed On", default=fields.Datetime.now)

    # ODOO 19 DOES NOT READ `_sql_constraints`, AND DOES NOT FAIL EITHER.
    #
    # It logs "Model attribute '_sql_constraints' is no longer supported" at
    # registry load and moves on, so the declaration below read as an enforced
    # uniqueness for as long as it has existed while Postgres held NO SUCH
    # CONSTRAINT - confirmed against the database: `assessments_be_similarity`
    # carries its pkey and its two foreign keys and nothing else. Duplicate
    # (source, target) pairs were therefore always insertable, and a duplicate
    # pair double-counts a SOP against the same target in every similarity
    # read.
    #
    # A LOUD FAILURE WOULD HAVE BEEN BETTER. This is the dangerous shape of
    # deprecation: the code still says what it always said, the tests that
    # never inserted a duplicate still pass, and only the database knows.
    _uniq_pair = models.Constraint(
        "unique(source_id, target_id)",
        "A similarity pair already exists for this source and target.",
    )

    @api.depends("source_id", "target_id")
    def _compute_display_name(self):
        for rec in self:
            rec.display_name = "%s \u2192 %s" % (
                rec.source_id.name or "?", rec.target_id.name or "?")
