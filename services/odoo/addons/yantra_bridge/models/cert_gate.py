from odoo import fields, models


class CertGate(models.Model):
    _name = "yantra.cert.gate"
    _description = "Yantra certification gate"
    _order = "code"

    code = fields.Char(required=True)
    name = fields.Char(required=True)

    _code_uniq = models.Constraint("unique(code)", "A certification gate code must be unique.")
