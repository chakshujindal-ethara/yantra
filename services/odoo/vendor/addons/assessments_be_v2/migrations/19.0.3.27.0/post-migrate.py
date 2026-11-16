# -*- coding: utf-8 -*-
"""assessments_be_v2 19.0.3.27.0 post-migration: recount `answered_count`.

`answered_count` is a STORED compute, and 19.0.3.27.0 changes what it counts:
real answers only (`assessments.be.response._is_answered`), where it used to
count every submitted row - including the empty placeholder settlement writes
for each question left blank, so every handed-in paper read answered =
questions. Odoo recomputes a stored field only when one of its dependencies is
written, never because its compute changed, so without this every existing
attempt keeps the old number.

Recomputed through the ORM, so the definition lives in one place. In batches,
with the cache dropped between them, so a large table never sits in memory.
Idempotent: a second run recomputes the same values and changes nothing.
"""
import logging

from odoo import SUPERUSER_ID, api

_logger = logging.getLogger(__name__)

VERSION = "19.0.3.27.0"
BATCH = 500


def migrate(cr, version):
    # Falsy on a fresh install: nothing stored yet to recount.
    if not version:
        return
    env = api.Environment(cr, SUPERUSER_ID, {})
    Evaluator = env["assessments.be.evaluator"]
    field = Evaluator._fields["answered_count"]
    cr.execute("SELECT id FROM assessments_be_evaluator ORDER BY id")
    ids = [row[0] for row in cr.fetchall()]
    changed = 0
    for start in range(0, len(ids), BATCH):
        batch = Evaluator.browse(ids[start:start + BATCH])
        before = dict(zip(batch.ids, batch.mapped("answered_count")))
        env.add_to_compute(field, batch)
        batch.flush_recordset(["answered_count"])
        changed += sum(1 for rec in batch
                       if rec.answered_count != before[rec.id])
        env.invalidate_all()
    _logger.info(
        "assessments_be_v2 %s: answered_count recomputed for %d attempt(s); "
        "%d changed.", VERSION, len(ids), changed)
