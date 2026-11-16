# -*- coding: utf-8 -*-
"""The counted confirmation in front of "Release Results".

ONE DIALOG, SAME SHAPE AS THE CONSOLE'S SHEET: how many have submitted, how
many are being released now, how many of those are still being graded and who
they are, that it cannot be undone, and a way out that waits for the grader.

It exists because a header `confirm=` is a static string and the numbers are
the whole argument - "release 412 results, 37 of them still being graded" is
what stops the wrong click; "are you sure?" is not. The delete wizard beside it
is the same pattern for the same reason.
"""
from odoo import api, fields, models


class EtpAssessmentReleaseWizard(models.TransientModel):
    _name = "assessments.be.release.wizard"
    _description = "Release results for a whole assessment"

    #: `set null`, as the delete wizard's: a cascade would delete this row out
    #: from under the method that is using it.
    assessment_id = fields.Many2one(
        "assessments.be", string="Assessment", ondelete="set null")
    name = fields.Char(related="assessment_id.name", readonly=True)
    submitted_count = fields.Integer(
        compute="_compute_counts", string="Submitted")
    releasable_count = fields.Integer(
        compute="_compute_counts", string="Releasing now")
    still_grading_count = fields.Integer(
        compute="_compute_counts", string="Still being graded")
    #: NAMED, not just counted. "37 still grading" is a number to accept; a
    #: list of names is something an operator recognises - it is how they spot
    #: that the one person they were waiting for is in it.
    still_grading_names = fields.Text(
        compute="_compute_counts", string="Waiting on")
    release_label = fields.Char(compute="_compute_counts")

    @api.depends("assessment_id")
    def _compute_counts(self):
        for rec in self:
            assessment = rec.assessment_id
            if not assessment:
                rec.submitted_count = 0
                rec.releasable_count = 0
                rec.still_grading_count = 0
                rec.still_grading_names = ""
                rec.release_label = "Release Results"
                continue
            to_release, unscored = assessment._releasable_evaluators()
            names = [
                e.applicant_id.partner_name or e.candidate_email or "?"
                for e in unscored[:10]
            ]
            if len(unscored) > len(names):
                names.append("and %d more" % (len(unscored) - len(names)))
            rec.submitted_count = assessment.submitted_count
            rec.releasable_count = len(to_release)
            rec.still_grading_count = len(unscored)
            rec.still_grading_names = ", ".join(names)
            rec.release_label = "Release %d result(s)" % len(to_release)

    def action_release(self):
        self.ensure_one()
        return self.assessment_id.action_confirm_release()


# The paper's grading phase on the attempt and answer forms, so their
# re-score buttons can hide while a kill is stopping (S1).
class EtpAssessmentEvaluatorScoringPhase(models.Model):
    _inherit = "assessments.be.evaluator"

    assessment_scoring_phase = fields.Selection(
        related="assessment_id.scoring_phase", string="Paper Scoring Phase")


class EtpAssessmentResponseScoringPhase(models.Model):
    _inherit = "assessments.be.response"

    assessment_scoring_phase = fields.Selection(
        related="assessment_id.scoring_phase", string="Paper Scoring Phase")
