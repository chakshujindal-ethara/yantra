# -*- coding: utf-8 -*-
"""Question-group grading caches on Vertex - one row per cache key (W13).

Written only by `services/grading_cache.py`, on a short cursor of its own. A
row is reused for its key: a cache that expired is created again in place.
"""
from odoo import fields, models


class EtpScoringCache(models.Model):
    _name = "assessments.be.scoring.cache"
    _description = "Grading Question-Group Cache"
    _order = "id desc"
    _rec_name = "key"

    key = fields.Char(
        required=True, readonly=True, index=True,
        help="sha256 of project, location, model, prompt version, layout "
             "version and the group's question material.")
    resource_name = fields.Char(
        string="Vertex Cache", readonly=True,
        help="projects/.../locations/.../cachedContents/...")
    model = fields.Char(readonly=True)
    location = fields.Char(readonly=True)
    token_count = fields.Integer(readonly=True)
    expires_at = fields.Datetime(readonly=True)
    created_at = fields.Datetime(readonly=True)
    failed_until = fields.Datetime(
        readonly=True,
        help="A failed create is not retried for this key before then.")

    _uniq_key = models.Constraint(
        "unique(key)", "One grading cache row per key.")
