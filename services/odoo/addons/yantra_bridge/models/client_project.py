"""Client projects and batches: the delivery manifest becomes one customer invoice per batch."""

import logging
from decimal import Decimal

from odoo import Command, _, api, fields, models
from odoo.exceptions import UserError
from odoo.tools import float_compare

from ..gateway_client import GatewayClient, GatewayError

_logger = logging.getLogger(__name__)
ERROR_ENVELOPE = ("code", "message", "request_id")


class ClientProject(models.Model):
    _name = "yantra.client.project"
    _description = "Yantra client project"
    _order = "name, id"

    name = fields.Char(required=True)
    partner_id = fields.Many2one("res.partner", string="Customer", required=True, ondelete="restrict")
    gateway_id = fields.Char("Gateway project id", required=True, copy=False, index=True)
    batch_ids = fields.One2many("yantra.batch", "project_id", string="Batches")
    batch_count = fields.Integer(compute="_compute_batch_count")

    _gateway_id_uniq = models.Constraint("unique(gateway_id)", "This gateway project is already registered.")

    @api.depends("batch_ids")
    def _compute_batch_count(self):
        for project in self:
            project.batch_count = len(project.batch_ids)


class Batch(models.Model):
    _name = "yantra.batch"
    _description = "Yantra work batch"
    _order = "id desc"
    _rec_name = "title"

    gateway_id = fields.Char("Gateway batch id", required=True, copy=False, index=True)
    project_id = fields.Many2one("yantra.client.project", required=True, ondelete="restrict", index=True)
    partner_id = fields.Many2one(related="project_id.partner_id")
    title = fields.Char(required=True)
    invoice_id = fields.Many2one("account.move", string="Customer invoice", readonly=True, copy=False)
    currency_id = fields.Many2one("res.currency", readonly=True)
    accepted_units = fields.Integer(readonly=True)
    unit_price = fields.Monetary(currency_field="currency_id", readonly=True)
    total_price = fields.Monetary(currency_field="currency_id", readonly=True)
    manifest_at = fields.Datetime("Manifest fetched at", readonly=True)

    _gateway_id_uniq = models.Constraint("unique(gateway_id)", "This gateway batch is already registered.")

    def action_invoice_batch(self):
        self.ensure_one()
        if not self.invoice_id:
            self._invoice_from_manifest(self._fetch_manifest())
        return {
            "type": "ir.actions.act_window",
            "res_model": "account.move",
            "res_id": self.invoice_id.id,
            "view_mode": "form",
        }

    def _fetch_manifest(self):
        self.ensure_one()
        client = GatewayClient(self.env)
        try:
            return client.get(f"/v1/batches/{self.gateway_id}/manifest")
        except GatewayError as exc:
            _logger.warning(
                "manifest refused batch_id=%s gateway_batch=%s http=%s code=%s request_id=%s",
                self.id,
                self.gateway_id,
                exc.status,
                exc.code,
                exc.request_id,
            )
            if exc.code == "batch_held":
                raise UserError(
                    _(
                        "Batch %(title)s is held by the delivery gate (batch_held): %(detail)s",
                        title=self.title,
                        detail=self._held_detail(exc),
                    )
                ) from exc
            raise UserError(
                _(
                    "The gateway refused the manifest: %(code)s (request %(rid)s).",
                    code=exc.code,
                    rid=exc.request_id or "-",
                )
            ) from exc

    @staticmethod
    def _held_detail(exc):
        counts = {k: v for k, v in exc.body.items() if k not in ERROR_ENVELOPE}
        parts = [exc.message] + [f"{key}={value}" for key, value in sorted(counts.items())]
        return "; ".join(part for part in parts if part)

    def _invoice_from_manifest(self, manifest):
        self.ensure_one()
        accepted = int(manifest["accepted_units"])
        unit_price = Decimal(str(manifest["unit_price"]))
        expected = accepted * unit_price
        if "total_price" in manifest and float_compare(
            float(expected), float(Decimal(str(manifest["total_price"]))), 2
        ):
            raise UserError(
                _(
                    "Manifest total %(total)s does not equal %(units)s x %(price)s.",
                    total=manifest["total_price"],
                    units=accepted,
                    price=unit_price,
                )
            )
        currency = self.env["yantra.pay.window"]._currency(manifest["currency"])
        invoice = self.env["account.move"].create(
            {
                "move_type": "out_invoice",
                "partner_id": self.project_id.partner_id.id,
                "currency_id": currency.id,
                "ref": f"yantra:batch:{self.gateway_id}",
                "invoice_origin": self.title,
                "invoice_line_ids": [
                    Command.create(
                        {
                            "name": f"{self.title}: {accepted} accepted units",
                            "quantity": accepted,
                            "price_unit": float(unit_price),
                            "tax_ids": [Command.clear()],
                        }
                    )
                ],
            }
        )
        self.write(
            {
                "invoice_id": invoice.id,
                "currency_id": currency.id,
                "accepted_units": accepted,
                "unit_price": float(unit_price),
                "total_price": float(expected),
                "manifest_at": fields.Datetime.now(),
            }
        )
