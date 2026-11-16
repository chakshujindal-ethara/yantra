# -*- coding: utf-8 -*-
"""A missing filestore file answers a placeholder, not a 500.

THE FAULT. `ir.attachment.location` was switched to `db` on 2026-04-05, but
1,054 rows still carry a `store_fname` pointing at files that no longer exist
anywhere - the filestore they lived on is gone. Reading one raises
`FileNotFoundError`, and `ir_attachment._to_http_stream` stats the path with
nothing around it (`base/models/ir_attachment.py:921`), while the web
controller that calls it catches only `UserError`
(`addons/web/controllers/binary.py`). So the exception escapes as a 500.

During the 753-candidate run this produced 2,483 tracebacks and 5 hard 500s,
all on `/web/image/...`. None of it touched candidates - no assessment-model
attachment is filestore-backed and exam media streams from S3 - but it is noise
on the only telemetry the run had, and a 500 on an avatar is still a 500.

WHY A `UserError` AND NOT A CAUGHT `FileNotFoundError`. `UserError` is the
signal `binary.py` already handles, and handling it drops the request into the
existing `web.image_placeholder` fallback. Raising the exception core expects is
what makes a broken avatar render as a placeholder instead of a stack trace,
without this addon knowing anything about the fallback itself.

THIS DOES NOT FIX THE ROWS. 1,054 attachments still point at files that cannot
be read, and deleting them is a separate, irreversible decision that needs a
business sign-off on the ~80 that are genuinely user-supplied (April-era CVs,
event PDFs, calendar invites). `force_storage()` must NOT be used for it: it
routes through `_compute_raw`, which returns `b''` for a missing file, so it
would write empty bytes into `db_datas` and turn "missing, maybe restorable"
into "the database says this is empty".
"""
import logging
import os

import werkzeug.security

from odoo import _, models
from odoo.exceptions import UserError
from odoo.http import request
from odoo.tools import config

_logger = logging.getLogger(__name__)


class IrAttachment(models.Model):
    _inherit = "ir.attachment"

    def _to_http_stream(self):
        """Refuse a missing file the way the caller already knows how to read."""
        self.ensure_one()
        if self.store_fname and request:
            # THE SAME PATH CORE IS ABOUT TO STAT, built the same way. Using
            # `self._filestore()` instead would be a second construction of the
            # same thing, and a guard that checks a different file from the one
            # that gets opened is worse than no guard.
            path = werkzeug.security.safe_join(
                os.path.abspath(config.filestore(request.db)),
                self.store_fname,
            )
            # `safe_join` answers None for a traversal attempt, and core would
            # hand that straight to `os.stat`.
            if path is None or not os.path.exists(path):
                _logger.info(
                    "attachment %s has no file in the filestore (%s); "
                    "serving the placeholder instead of raising",
                    self.id, self.store_fname)
                raise UserError(_("Attachment file is missing."))
        return super()._to_http_stream()
