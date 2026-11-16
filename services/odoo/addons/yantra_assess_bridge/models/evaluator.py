"""Invitations for Yantra workers are Yantra's to send.

Assessment v2 mails every newly assigned candidate an invitation that says to sign in with Odoo credentials; a
Yantra worker has none (they arrive through a launch ticket from the Yantra app, which tells them about the paper
itself). While `yantra_assess_bridge.suppress_invitations` is on, the mail is skipped for accounts bound to a Yantra
person (one log line with the attempt id says so, and the invite reads as handled); everyone else still gets v2's own
mail.
"""

import logging

from odoo import models

_logger = logging.getLogger(__name__)


class AssessmentEvaluator(models.Model):
    _inherit = "assessments.be.evaluator"

    def _deliver_invitation(self):
        self.ensure_one()
        user = self.applicant_id.be_candidate_user_id
        suppress = self.env["ir.config_parameter"].sudo().get_param("yantra_assess_bridge.suppress_invitations", "1")
        if user and user.yantra_keycloak_sub and suppress in ("1", "True", "true"):
            _logger.info("invitation left to Yantra evaluator_id=%s", self.id)
            return None
        return super()._deliver_invitation()
