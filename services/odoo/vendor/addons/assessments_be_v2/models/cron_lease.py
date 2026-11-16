# -*- coding: utf-8 -*-
"""The cron lease table: one row per lock key, used only in lease mode
(`assessments_be_v2.cron_lock_mode`) and written only by `services/locks.py`
in raw SQL.

A model so that `-u` creates the table and the ACL can name it. `_auto` is off
because the lock key itself is the primary key (no `id` column): the take's
`ON CONFLICT (key)` needs it, and it is a bigint because lock keys are.
"""
from odoo import fields, models


class CronLease(models.Model):
    _name = "assessments.be.cron.lease"
    _description = "Cron Lock Lease"
    _auto = False
    _log_access = False
    _rec_name = "holder"

    key = fields.Integer(readonly=True, help="The cron's lock key (bigint).")
    holder = fields.Char(readonly=True, help="host:pid:uuid of the tick.")
    acquired_at = fields.Datetime(readonly=True)
    expires_at = fields.Datetime(readonly=True)

    def init(self):
        self.env.cr.execute("""
            CREATE TABLE IF NOT EXISTS assessments_be_cron_lease (
                key bigint PRIMARY KEY,
                holder text NOT NULL,
                acquired_at timestamptz NOT NULL,
                expires_at timestamptz NOT NULL)
        """)
