from odoo import fields, models


class AccountMoveLine(models.Model):
    _inherit = "account.move.line"

    yantra_is_tds = fields.Boolean("Yantra TDS line", copy=False, help="Withholding line on a Yantra earnings bill.")
