"""Paid pay windows pulled from the payout service, and the vendor bill (with TDS) each line becomes.

Idempotency: a window is imported once (unique gateway id), a line is imported once (unique gateway id) and maps to
at most one bill (`bill_id`). Re-running the cron only retries lines that have no bill yet.
"""

import logging
from datetime import UTC, datetime
from decimal import ROUND_HALF_UP, Decimal

from odoo import Command, _, api, fields, models
from odoo.exceptions import UserError
from odoo.tools import float_compare

from .. import gateway_client
from ..gateway_client import GatewayClient, GatewayError

_logger = logging.getLogger(__name__)

PAISA = Decimal("0.01")
BILLABLE_STATUSES = ("payable", "paid")
LINE_STATES = [
    ("pending", "Pending"),
    ("needs_worker", "Needs worker"),
    ("held", "Held"),
    ("billed", "Billed"),
]


def _parse_dt(value):
    if not value:
        return False
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone(UTC).replace(tzinfo=None)
    return parsed


def _money(value):
    return float(Decimal(str(value)))


class PayWindow(models.Model):
    _name = "yantra.pay.window"
    _description = "Yantra pay window"
    _order = "ends_at desc, id desc"

    name = fields.Char(compute="_compute_name", store=True)
    gateway_id = fields.Char("Gateway window id", required=True, copy=False, index=True)
    starts_at = fields.Datetime(required=True)
    ends_at = fields.Datetime(required=True)
    currency_id = fields.Many2one("res.currency", required=True)
    status = fields.Char("Gateway status", required=True)
    gross_total = fields.Monetary("Gross total (gateway)", currency_field="currency_id")
    held_total = fields.Monetary("Held total (gateway)", currency_field="currency_id")
    paid_at = fields.Datetime()
    rail_reference = fields.Char()
    line_ids = fields.One2many("yantra.pay.window.line", "window_id", string="Lines")
    line_count = fields.Integer(compute="_compute_counts")
    needs_worker_count = fields.Integer(compute="_compute_counts")
    pending_count = fields.Integer(compute="_compute_counts")
    bill_count = fields.Integer(compute="_compute_counts")
    billed_gross = fields.Monetary("Gross total (bills)", compute="_compute_billed_gross", currency_field="currency_id")
    reconciled = fields.Boolean(compute="_compute_reconciled")

    _gateway_id_uniq = models.Constraint("unique(gateway_id)", "This pay window is already imported.")

    @api.depends("starts_at", "ends_at")
    def _compute_name(self):
        for window in self:
            window.name = f"Pay window {window._period_label()}"

    def _period_label(self):
        self.ensure_one()
        starts = fields.Datetime.to_datetime(self.starts_at)
        ends = fields.Datetime.to_datetime(self.ends_at)
        return f"{starts:%Y-%m-%d}–{ends:%Y-%m-%d}" if starts and ends else "?"

    @api.depends("line_ids.state", "line_ids.bill_id")
    def _compute_counts(self):
        for window in self:
            lines = window.line_ids
            window.line_count = len(lines)
            window.needs_worker_count = len(lines.filtered(lambda l: l.state == "needs_worker"))
            window.pending_count = len(lines.filtered(lambda l: l.state == "pending"))
            window.bill_count = len(lines.bill_id)

    @api.depends("line_ids.bill_id.invoice_line_ids.price_subtotal", "line_ids.bill_id.invoice_line_ids.yantra_is_tds")
    def _compute_billed_gross(self):
        for window in self:
            bill_lines = window.line_ids.bill_id.invoice_line_ids
            earnings = bill_lines.filtered(lambda l: l.display_type == "product" and not l.yantra_is_tds)
            window.billed_gross = sum(earnings.mapped("price_subtotal"))

    @api.depends("gross_total", "billed_gross", "needs_worker_count", "pending_count")
    def _compute_reconciled(self):
        for window in self:
            all_billed = not window.needs_worker_count and not window.pending_count
            window.reconciled = (
                all_billed and float_compare(window.gross_total, window.billed_gross, precision_digits=2) == 0
            )

    def action_open_bills(self):
        self.ensure_one()
        return {
            "type": "ir.actions.act_window",
            "name": _("Bills"),
            "res_model": "account.move",
            "view_mode": "list,form",
            "domain": [("id", "in", self.line_ids.bill_id.ids)],
        }

    def action_bill_pending_lines(self):
        self.line_ids._bill_pending()
        return True

    # Cron ------------------------------------------------------------------------------------------------

    @api.model
    def action_pull_paid_windows(self):
        """The button: the same pull, but a refusal is shown to the person who clicked."""
        if not gateway_client.is_configured(self.env):
            raise UserError(_("Yantra is not configured: set the gateway and Keycloak settings first."))
        try:
            self._pull_paid_windows()
        except GatewayError as exc:
            raise UserError(
                _("The gateway refused the pull: %(code)s (request %(rid)s).", code=exc.code, rid=exc.request_id or "-")
            ) from exc

    @api.model
    def _cron_pull_paid_windows(self):
        """The cron: a refusal is one ERROR line with the ids; the next run tries again."""
        if not gateway_client.is_configured(self.env):
            _logger.info("yantra gateway not configured; skipping pull of paid windows")
            return
        try:
            self._pull_paid_windows()
        except GatewayError as exc:
            _logger.error(
                "pull paid windows failed http=%s code=%s request_id=%s", exc.status, exc.code, exc.request_id
            )

    @api.model
    def _pull_paid_windows(self):
        client = GatewayClient(self.env)
        payloads = client.get("/v1/payout/windows", params={"status": "paid"})
        for payload in payloads:
            self._import_window(client, payload)
        self.search([("line_ids.state", "in", ("pending", "needs_worker"))]).line_ids._bill_pending()

    @api.model
    def _import_window(self, client, payload):
        gateway_id = str(payload["id"])
        if self.search_count([("gateway_id", "=", gateway_id)]):
            return
        try:
            lines = client.get(f"/v1/payout/windows/{gateway_id}/lines")
        except GatewayError as exc:
            _logger.error(
                "pull window lines failed window=%s http=%s code=%s request_id=%s",
                gateway_id,
                exc.status,
                exc.code,
                exc.request_id,
            )
            return
        self.create(self._window_vals(payload, lines))

    @api.model
    def _window_vals(self, payload, lines):
        return {
            "gateway_id": str(payload["id"]),
            "starts_at": _parse_dt(payload["starts_at"]),
            "ends_at": _parse_dt(payload["ends_at"]),
            "currency_id": self._currency(payload["currency"]).id,
            "status": payload["status"],
            "gross_total": _money(payload["gross_total"]),
            "held_total": _money(payload["held_total"]),
            "paid_at": _parse_dt(payload.get("paid_at")),
            "rail_reference": payload.get("rail_reference") or False,
            "line_ids": [Command.create(self.env["yantra.pay.window.line"]._line_vals(line)) for line in lines],
        }

    @api.model
    def _currency(self, code):
        currency = self.env["res.currency"].with_context(active_test=False).search([("name", "=", code)], limit=1)
        if not currency:
            raise UserError(_("Currency %s does not exist in Odoo.", code))
        if not currency.active:
            currency.active = True
        return currency


class PayWindowLine(models.Model):
    _name = "yantra.pay.window.line"
    _description = "Yantra pay window line"
    _order = "window_id, id"

    window_id = fields.Many2one("yantra.pay.window", required=True, ondelete="cascade", index=True)
    currency_id = fields.Many2one(related="window_id.currency_id")
    gateway_id = fields.Char("Gateway line id", required=True, copy=False, index=True)
    worker_sub = fields.Char("Keycloak subject", required=True)
    worker_id = fields.Many2one("yantra.worker", compute="_compute_worker_id", store=True)
    gross = fields.Monetary(currency_field="currency_id")
    earning_count = fields.Integer()
    status = fields.Char("Gateway status", required=True)
    hold_reason = fields.Char()
    state = fields.Selection(LINE_STATES, required=True, default="pending")
    bill_id = fields.Many2one("account.move", string="Vendor bill", readonly=True, copy=False)

    _gateway_id_uniq = models.Constraint("unique(gateway_id)", "This pay window line is already imported.")

    @api.model
    def _line_vals(self, line):
        return {
            "gateway_id": str(line["id"]),
            "worker_sub": str(line["worker_id"]),
            "gross": _money(line["gross"]),
            "earning_count": int(line.get("earning_count") or 0),
            "status": line["status"],
            "hold_reason": line.get("hold_reason") or False,
            "state": "pending" if line["status"] in BILLABLE_STATUSES else "held",
        }

    @api.depends("worker_sub")
    def _compute_worker_id(self):
        for line in self:
            line.worker_id = self.env["yantra.worker"].search([("keycloak_sub", "=", line.worker_sub)], limit=1)

    def _bill_pending(self):
        for line in self.filtered(lambda l: l.state in ("pending", "needs_worker") and not l.bill_id):
            line._compute_worker_id()
            if not line.worker_id:
                line.state = "needs_worker"
                continue
            line.bill_id = line._create_bill()
            line.state = "billed"

    def _tds_amount(self, gross, rate):
        """Withholding to the paisa, half-up, from Decimal inputs."""
        return (gross * rate / Decimal(100)).quantize(PAISA, rounding=ROUND_HALF_UP)

    def _create_bill(self):
        self.ensure_one()
        window = self.window_id
        worker = self.worker_id
        journal = self.env["account.journal"].search(
            [("type", "=", "purchase"), ("company_id", "=", self.env.company.id)], limit=1
        )
        if not journal:
            raise UserError(_("No purchase journal: install a chart of accounts before billing pay windows."))
        gross = Decimal(str(self.gross)).quantize(PAISA)
        rate = Decimal(str(worker.tds_rate))
        tds = self._tds_amount(gross, rate)
        lines = [
            Command.create(
                {
                    "name": f"Yantra earnings window {window._period_label()}",
                    "quantity": 1,
                    "price_unit": float(gross),
                    "tax_ids": [Command.clear()],
                }
            )
        ]
        if tds:
            lines.append(
                Command.create(
                    {
                        "name": f"TDS @ {rate.normalize():f}%",
                        "quantity": 1,
                        "price_unit": float(-tds),
                        "tax_ids": [Command.clear()],
                        "yantra_is_tds": True,
                    }
                )
            )
        paid_on = fields.Datetime.to_datetime(window.paid_at)
        return self.env["account.move"].create(
            {
                "move_type": "in_invoice",
                "journal_id": journal.id,
                "partner_id": worker.partner_id.id,
                "currency_id": window.currency_id.id,
                "invoice_date": paid_on.date() if paid_on else fields.Date.context_today(self),
                "ref": f"yantra:{window.gateway_id}:{self.gateway_id}",
                "invoice_origin": window.name,
                "invoice_line_ids": lines,
            }
        )
