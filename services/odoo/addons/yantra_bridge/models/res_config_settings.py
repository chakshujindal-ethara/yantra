from odoo import fields, models


class ResConfigSettings(models.TransientModel):
    _inherit = "res.config.settings"

    yantra_gateway_url = fields.Char("Gateway URL", config_parameter="yantra.gateway_url")
    yantra_keycloak_url = fields.Char("Keycloak URL", config_parameter="yantra.keycloak_url")
    yantra_keycloak_client_id = fields.Char("Keycloak client id", config_parameter="yantra.keycloak_client_id")
    yantra_keycloak_client_secret = fields.Char(
        "Keycloak client secret", config_parameter="yantra.keycloak_client_secret"
    )
    yantra_default_tds_rate = fields.Float(
        "Default TDS rate (%)", config_parameter="yantra.default_tds_rate", digits=(5, 2)
    )
