"""The worker record: the system of record for a person on the Yantra bench. Status changes are pushed to the
gateway (`PUT /v1/workers/{keycloak_sub}`) before they are written here, so a refused push leaves the record as
it was."""

import logging
import uuid

from odoo import _, api, fields, models
from odoo.exceptions import UserError, ValidationError

from ..gateway_client import GatewayClient, GatewayError

_logger = logging.getLogger(__name__)

STATUSES = [
    ("draft", "Draft"),
    ("eligible", "Eligible"),
    ("active", "Active"),
    ("suspended", "Suspended"),
    ("offboarded", "Offboarded"),
]
ELIGIBILITY_FIELDS = ("agreement_signed_at", "dpdp_consent_at", "bank_id")
TRANSITIONS = {
    "eligible": ("draft",),
    "active": ("eligible", "suspended"),
    "suspended": ("eligible", "active"),
    "offboarded": ("eligible", "active", "suspended"),
}


class Worker(models.Model):
    _name = "yantra.worker"
    _description = "Yantra worker"
    _order = "name, id"

    name = fields.Char(required=True)
    email = fields.Char()
    phone = fields.Char()
    partner_id = fields.Many2one(
        "res.partner", string="Vendor partner", required=True, ondelete="restrict", copy=False, index=True
    )
    keycloak_sub = fields.Char("Keycloak subject", required=True, copy=False, index=True)
    status = fields.Selection(STATUSES, required=True, default="draft", copy=False)
    agreement_signed_at = fields.Datetime("Agreement signed at")
    dpdp_consent_at = fields.Datetime("DPDP consent at")
    dpdp_consent_text = fields.Text("DPDP consent text")
    account_holder = fields.Char("Account holder")
    bank_ifsc = fields.Char("IFSC")
    bank_id = fields.Many2one(
        "res.partner.bank", string="Bank account", domain="[('partner_id', '=', partner_id)]", copy=False
    )
    bank_account_number = fields.Char(
        "Account number",
        compute="_compute_bank_account_number",
        inverse="_inverse_bank_account_number",
        help="Stored only on the partner's bank account record.",
    )
    bank_account_last4 = fields.Char("Account last 4", compute="_compute_bank_account_last4", store=True)
    pan = fields.Char("PAN")
    tds_rate = fields.Float("TDS rate (%)", digits=(5, 2), default=lambda self: self._default_tds_rate())
    cert_gate_ids = fields.Many2many("yantra.cert.gate", string="Certification gates")

    _keycloak_sub_uniq = models.Constraint("unique(keycloak_sub)", "A Keycloak subject belongs to one worker.")

    @api.model
    def _default_tds_rate(self):
        return float(self.env["ir.config_parameter"].sudo().get_param("yantra.default_tds_rate") or 0.0)

    @api.constrains("keycloak_sub")
    def _check_keycloak_sub(self):
        for worker in self:
            try:
                uuid.UUID(worker.keycloak_sub)
            except (ValueError, TypeError, AttributeError):
                raise ValidationError(_("Keycloak subject must be a UUID, got %r.", worker.keycloak_sub))

    @api.depends("bank_id.acc_number")
    def _compute_bank_account_number(self):
        for worker in self:
            worker.bank_account_number = worker.bank_id.acc_number or False

    def _inverse_bank_account_number(self):
        for worker in self:
            number = (worker.bank_account_number or "").strip()
            if not number:
                continue
            vals = {
                "acc_number": number,
                "acc_holder_name": worker.account_holder or worker.name,
                "partner_id": worker.partner_id.id,
            }
            if worker.bank_id:
                worker.bank_id.write(vals)
            else:
                worker.bank_id = self.env["res.partner.bank"].create(vals)

    @api.depends("bank_id.acc_number")
    def _compute_bank_account_last4(self):
        for worker in self:
            number = worker.bank_id.acc_number or ""
            worker.bank_account_last4 = number[-4:] if number else False

    @api.model_create_multi
    def create(self, vals_list):
        for vals in vals_list:
            if not vals.get("partner_id"):
                vals["partner_id"] = self._create_partner(vals).id
        return super().create(vals_list)

    def _create_partner(self, vals):
        return self.env["res.partner"].create(
            {
                "name": vals.get("name"),
                "email": vals.get("email"),
                "phone": vals.get("phone"),
                "supplier_rank": 1,
                "company_type": "person",
            }
        )

    # Status transitions ---------------------------------------------------------------------------------

    def action_mark_eligible(self):
        for worker in self:
            worker._check_eligibility()
        self._transition("eligible")

    def action_activate(self):
        self._transition("active")

    def action_suspend(self):
        self._transition("suspended")

    def action_offboard(self):
        self._transition("offboarded")

    def _check_eligibility(self):
        self.ensure_one()
        for field_name in ELIGIBILITY_FIELDS:
            if not self[field_name]:
                label = self._fields[field_name].string
                raise UserError(
                    _(
                        "Cannot mark %(worker)s eligible: %(field)s (%(label)s) is missing.",
                        worker=self.name,
                        field=field_name,
                        label=label,
                    )
                )

    def _transition(self, status):
        # One worker per transition: a push that is refused halfway through a list would leave the gateway with
        # the first records changed and Odoo with none of them.
        if len(self) != 1:
            raise UserError(_("Change one worker at a time: a refused push must leave both sides as they were."))
        for worker in self:
            if worker.status not in TRANSITIONS[status]:
                raise UserError(
                    _(
                        "%(worker)s cannot go from %(old)s to %(new)s.",
                        worker=worker.name,
                        old=worker.status,
                        new=status,
                    )
                )
            worker._push_status(status)
            worker.status = status

    def write(self, vals):
        """A gate change on a worker the gateway already knows is pushed at once; otherwise the market would keep
        refusing claims with a certification error and nothing on this side would say why."""
        result = super().write(vals)
        if "cert_gate_ids" in vals:
            for worker in self.filtered(lambda w: w.status in ("eligible", "active")):
                worker._push_status(worker.status)
        return result

    def _push_body(self, status):
        self.ensure_one()
        return {
            "status": status,
            "cert_gates": self.cert_gate_ids.mapped("code"),
            "partner_ref": self.partner_id.id,
        }

    def _push_status(self, status):
        self.ensure_one()
        client = GatewayClient(self.env)
        try:
            client.put(f"/v1/workers/{self.keycloak_sub}", self._push_body(status))
        except GatewayError as exc:
            _logger.warning(
                "worker push refused worker_id=%s sub=%s status=%s http=%s code=%s request_id=%s",
                self.id,
                self.keycloak_sub,
                status,
                exc.status,
                exc.code,
                exc.request_id,
            )
            raise UserError(
                _(
                    "The gateway refused the worker update: %(code)s (request %(rid)s). The record was not changed.",
                    code=exc.code,
                    rid=exc.request_id or "-",
                )
            ) from exc
