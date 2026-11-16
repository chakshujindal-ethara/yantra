"""The exam app's side of a launch: spend a one-time ticket for a v2 bearer.

    POST /api/v1/yantra/launch/redeem  {ticket}
        -> {access_token, refresh_token: "", expires_at, exam_token, next, return_url}

Public by design: the ticket IS the credential (256 bits, single use, two minutes, stored only as a hash). A failure
says which of invalid / used / expired it was, so the app can send the person back to Yantra for a fresh one, and
the ticket itself never reaches a log line.
"""

import logging

from odoo import http
from odoo.http import request

from odoo.addons.assessments_be_v2.controllers.api.common import API_TYPE, api_endpoint, fail, ok, str_arg

from ..models.ticket import TicketRefused

_logger = logging.getLogger(__name__)
STATUS = {"invalid_ticket": 404, "ticket_used": 410, "ticket_expired": 410, "account_inactive": 403}


class YantraAssessLaunch(http.Controller):
    @http.route("/api/v1/yantra/launch/redeem", type=API_TYPE, auth="public", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    def redeem(self, **kw):
        try:
            result = request.env["yantra.assess.ticket"].sudo()._redeem(str_arg("ticket", max_len=128))
        except TicketRefused as exc:
            _logger.info("launch ticket refused code=%s", exc.code)
            return fail(exc.code, str(exc.args[0]), status=STATUS.get(exc.code, 400))
        return ok(result)
