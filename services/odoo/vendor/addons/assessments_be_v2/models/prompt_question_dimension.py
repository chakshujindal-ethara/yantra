# -*- coding: utf-8 -*-
"""Editable answer key for a DRAFT question — one axis per dimension, seeded from the LLM JSON."""

from odoo import models, fields


class EtpAssessmentPromptQuestionDimension(models.Model):
    _name = "assessments.be.prompt.question.dimension"
    _description = "Draft Question Answer Axis"
    _order = "sequence, id"

    draft_id = fields.Many2one(
        "assessments.be.prompt.question",
        string="Draft Question", required=True, ondelete="cascade", index=True)
    sequence = fields.Integer(default=10)
    input_kind = fields.Char(
        string="Input kind",
        help="The Form Studio kind this axis was drawn as (linearScale, "
             "rating, checkboxes...). Empty means a plain single-choice axis. "
             "Carried to the bank question on approve so the exam renders the "
             "control the examiner authored.")
    label = fields.Char(
        string="Axis", required=True,
        help="For MCQ/MSQ this is the question's answer set; for image A/B it is "
             "one scoring axis (e.g. Instruction Following).")
    option_line_ids = fields.One2many(
        "assessments.be.prompt.question.dimension.option",
        "dimension_id", string="Options")


class EtpAssessmentPromptQuestionDimensionOption(models.Model):
    _name = "assessments.be.prompt.question.dimension.option"
    _description = "Draft Question Answer Option"
    _order = "sequence, id"

    dimension_id = fields.Many2one(
        "assessments.be.prompt.question.dimension",
        string="Axis", required=True, ondelete="cascade", index=True)
    sequence = fields.Integer(default=10)
    name = fields.Char(string="Option", required=True)
    is_correct = fields.Boolean(string="Correct", default=False)
