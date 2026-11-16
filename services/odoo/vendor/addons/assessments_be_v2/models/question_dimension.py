from odoo import models, fields, api
from odoo.exceptions import ValidationError


class EtpAssessmentQuestionDimension(models.Model):
    _name = "assessments.be.question.dimension"
    # Bumps the question's version on any change (the question cache key).
    _inherit = ["assessments.be.question.cache.touch"]
    _description = "Question Dimension Link"
    _order = "sequence, id"
    _rec_name = "name"

    question_id = fields.Many2one(
        "assessments.be.question", required=True, ondelete="cascade",
        # Read once per question SERVED, so it is on the exam's hot path, not
        # just the admin's.
        index=True,
    )
    name = fields.Char(string="Dimension", required=True)
    sequence = fields.Integer(default=10)
    input_kind = fields.Char(
        string="Input kind",
        help="The Form Studio kind the examiner drew for this axis "
             "(multipleChoice, linearScale, rating, checkboxes, "
             "checkboxGrid...). Empty means a plain single-choice axis, which "
             "is how every axis behaved before templates could carry a scale. "
             "The exam screen reads this to render the control the examiner "
             "actually authored instead of collapsing everything to radios.")
    option_line_ids = fields.One2many(
        "assessments.be.question.dimension.option",
        "question_dimension_id",
        string="Options",
    )

    @api.constrains("question_id", "name")
    def _check_unique_dimension_per_question(self):
        for rec in self:
            duplicate = self.search_count([
                ("question_id", "=", rec.question_id.id),
                ("name", "=", rec.name),
                ("id", "!=", rec.id),
            ])
            if duplicate:
                raise ValidationError(
                    "Dimension '%s' is already assigned to this question."
                    % rec.name
                )


class EtpAssessmentQuestionDimensionOption(models.Model):
    _name = "assessments.be.question.dimension.option"
    _inherit = ["assessments.be.question.cache.touch"]
    _question_path = "question_dimension_id.question_id"
    _description = "Question Dimension Option"
    _order = "sequence, id"

    question_dimension_id = fields.Many2one(
        "assessments.be.question.dimension", required=True, ondelete="cascade",
        # Options are read for every dimension of every question served.
        index=True,
    )
    name = fields.Char(required=True)
    sequence = fields.Integer(default=10)
    is_correct = fields.Boolean(string="Correct", default=False)
    score = fields.Integer(string="Score", compute="_compute_score", store=True)

    @api.depends("is_correct")
    def _compute_score(self):
        for rec in self:
            rec.score = 1 if rec.is_correct else 0

    def write(self, vals):
        # Every answer's marks depend on `is_correct`, and Odoo re-scores them
        # on any write of it, changed or not. Editors resend the whole key on
        # a rename (bank API, Form Studio): on a question sat 3,700 times
        # mid-exam that took 50 s and Odoo's last serialization retry. A real
        # key change still re-scores, as intended.
        if "is_correct" in vals and all(
                rec.is_correct == bool(vals["is_correct"]) for rec in self):
            vals = {k: v for k, v in vals.items() if k != "is_correct"}
        return super().write(vals)
