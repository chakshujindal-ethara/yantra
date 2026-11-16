# -*- coding: utf-8 -*-
"""Video attachments for video-evaluation questions; ``slot`` identifies each clip.

Videos get their OWN model (not question.image): mp4 is large and streams from a
URL/CDN (``video_url`` preferred), with a small Binary as a dev-only fallback.
"""
from odoo import api, models, fields


class EtpAssessmentQuestionVideo(models.Model):
    _name = "assessments.be.question.video"
    # Bumps the question's version on any change (the question cache key).
    _inherit = ["assessments.be.question.cache.touch"]
    _description = "Assessment Question Video"
    _order = "sequence, id"

    question_id = fields.Many2one(
        "assessments.be.question",
        string="Question",
        required=True,
        ondelete="cascade",
        # Every media question served reads its plates by this column.
        index=True,
    )
    label = fields.Char(
        string="Label",
        help="Shown to the candidate, e.g. 'Reference', 'Output'.")
    slot = fields.Selection(
        [
            ("reference", "Reference"),
            ("output", "Output"),
            ("single", "Single"),
        ],
        string="Slot",
        default="single",
        help="video_prompt uses Reference + Output; Single for a lone clip.")
    video_url = fields.Char(
        string="Video URL",
        help="S3/CDN URL, the preferred storage. When set, the portal streams "
             "this instead of the stored binary.")
    video = fields.Binary(
        string="Video", attachment=True,
        help="Small/dev fallback; production stores the clip at video_url.")
    video_filename = fields.Char(string="Video Filename")
    poster_url = fields.Char(
        string="Poster URL",
        help="Optional still frame shown before the clip plays.")
    duration_s = fields.Float(string="Duration (s)")
    has_audio = fields.Boolean(string="Has Audio")
    # Stored + computed, so the upgrade that adds the column back-fills every
    # existing row (all clips, so "video") with no migration script.
    media_kind = fields.Selection(
        [("video", "Video"), ("audio", "Audio")],
        string="Media Kind", compute="_compute_media_kind", store=True,
        help="Audio when the URL (else the filename) ends in an audio "
             "extension; the exam then plays it in an audio player.")
    sequence = fields.Integer(default=10)

    @api.depends("video_url", "video_filename", "question_id.question_type")
    def _compute_media_kind(self):
        looks_audio = self.env["etp.studio.form"]._looks_like_audio
        for rec in self:
            # A transcription clip is audio whatever its link looks like: a
            # Drive or Jumpshare link has no extension to read.
            rec.media_kind = ("audio" if (
                rec.question_id.question_type == "transcription"
                or looks_audio(rec.video_url or rec.video_filename))
                else "video")

    @api.depends("label", "slot")
    def _compute_display_name(self):
        for rec in self:
            rec.display_name = rec.label or dict(
                self._fields["slot"].selection).get(rec.slot, "Video")
