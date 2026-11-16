from odoo.exceptions import UserError
from odoo.tools import mute_logger

from .common import SUB_A, SUB_B, SUB_UNKNOWN, FakeResponse, YantraCase

WINDOW_ID = "aaaaaaaa-0000-4000-8000-000000000001"
WINDOW_LOG = "odoo.addons.yantra_bridge.models.pay_window"

WINDOW = {
    "id": WINDOW_ID,
    "starts_at": "2026-10-24T18:30:00+00:00",
    "ends_at": "2026-10-31T18:29:59+00:00",
    "currency": "INR",
    "status": "paid",
    "gross_total": "1250.490000",
    "held_total": "20.000000",
    "paid_at": "2026-11-02T09:00:00Z",
    "rail_reference": "BANKFILE-42",
}
LINES = [
    {
        "id": "l-1",
        "worker_id": SUB_A,
        "gross": "1000.500000",
        "earning_count": 40,
        "status": "paid",
        "hold_reason": None,
    },
    {"id": "l-2", "worker_id": SUB_B, "gross": "199.990000", "earning_count": 8, "status": "paid", "hold_reason": None},
    {
        "id": "l-3",
        "worker_id": SUB_UNKNOWN,
        "gross": "50.000000",
        "earning_count": 2,
        "status": "payable",
        "hold_reason": None,
    },
    {
        "id": "l-4",
        "worker_id": "44444444-4444-4444-8444-444444444444",
        "gross": "20.000000",
        "earning_count": 1,
        "status": "held",
        "hold_reason": "first_payout",
    },
]


class TestPayWindow(YantraCase):
    def setUp(self):
        super().setUp()
        self.worker_a = self.make_worker(sub=SUB_A, tds_rate=10.0)
        self.worker_b = self.make_worker(sub=SUB_B, name="Bilal Worker", email="bilal@example.test", tds_rate=7.5)
        self.session.route("GET", "/v1/payout/windows", FakeResponse(200, [WINDOW]))
        self.session.route("GET", f"/v1/payout/windows/{WINDOW_ID}/lines", FakeResponse(200, LINES))
        self.Window = self.env["yantra.pay.window"]

    def pull(self):
        self.Window._cron_pull_paid_windows()
        return self.Window.search([("gateway_id", "=", WINDOW_ID)])

    def test_import_creates_bills_once(self):
        window = self.pull()
        self.assertEqual(len(window), 1)
        self.assertEqual(window.name, "Pay window 2026-10-24–2026-10-31")
        self.assertEqual(window.status, "paid")
        self.assertEqual(window.rail_reference, "BANKFILE-42")
        self.assertEqual(len(window.line_ids), 4)
        bills = window.line_ids.bill_id
        self.assertEqual(len(bills), 2)
        self.assertEqual(set(bills.mapped("move_type")), {"in_invoice"})
        self.assertEqual(set(bills.mapped("state")), {"draft"})
        self.assertEqual(self.session.gateway_calls("GET")[0].params, {"status": "paid"})

        self.pull()
        self.assertEqual(self.Window.search_count([("gateway_id", "=", WINDOW_ID)]), 1)
        self.assertEqual(window.line_ids.bill_id, bills, "a second run creates no second bill")
        self.assertEqual(self.env["account.move"].search_count([("ref", "like", "yantra:")]), 2)

    def test_bill_contents_and_tds_to_the_paisa(self):
        window = self.pull()
        line_a = window.line_ids.filtered(lambda l: l.worker_sub == SUB_A)
        bill = line_a.bill_id
        self.assertEqual(bill.partner_id, self.worker_a.partner_id)
        self.assertEqual(bill.currency_id.name, "INR")
        self.assertEqual(str(bill.invoice_date), "2026-11-02")
        earning, tds = bill.invoice_line_ids.sorted("price_unit", reverse=True)
        self.assertEqual(earning.name, "Yantra earnings window 2026-10-24–2026-10-31")
        self.assertAlmostEqual(earning.price_unit, 1000.50, places=2)
        self.assertFalse(earning.tax_ids)
        self.assertEqual(tds.name, "TDS @ 10%")
        self.assertTrue(tds.yantra_is_tds)
        self.assertAlmostEqual(tds.price_unit, -100.05, places=2)
        self.assertAlmostEqual(bill.amount_total, 900.45, places=2)

        line_b = window.line_ids.filtered(lambda l: l.worker_sub == SUB_B)
        tds_b = line_b.bill_id.invoice_line_ids.filtered("yantra_is_tds")
        self.assertEqual(tds_b.name, "TDS @ 7.5%")
        self.assertAlmostEqual(tds_b.price_unit, -15.00, places=2, msg="199.99 x 7.5% = 14.99925 rounds half-up")
        self.assertAlmostEqual(line_b.bill_id.amount_total, 184.99, places=2)

    def test_unknown_worker_goes_to_needs_worker_then_bills_later(self):
        window = self.pull()
        unknown = window.line_ids.filtered(lambda l: l.worker_sub == SUB_UNKNOWN)
        self.assertEqual(unknown.state, "needs_worker")
        self.assertFalse(unknown.bill_id)
        self.assertEqual(window.needs_worker_count, 1)
        self.assertAlmostEqual(window.billed_gross, 1200.49, places=2)
        self.assertFalse(window.reconciled)

        self.make_worker(sub=SUB_UNKNOWN, name="Chitra Worker", email="chitra@example.test")
        self.pull()
        self.assertEqual(unknown.state, "billed")
        self.assertTrue(unknown.bill_id)
        self.assertEqual(window.needs_worker_count, 0)
        self.assertAlmostEqual(window.billed_gross, 1250.49, places=2)
        self.assertTrue(window.reconciled)

    def test_held_line_is_never_billed(self):
        window = self.pull()
        held = window.line_ids.filtered(lambda l: l.status == "held")
        self.assertEqual(held.state, "held")
        self.assertEqual(held.hold_reason, "first_payout")
        self.assertFalse(held.bill_id)

    def test_reconciled_false_when_gross_differs_by_a_paisa(self):
        self.make_worker(sub=SUB_UNKNOWN, name="Chitra Worker", email="chitra@example.test")
        window = self.pull()
        self.assertTrue(window.reconciled)
        window.gross_total = 1250.50
        self.assertFalse(window.reconciled)
        window.gross_total = 1250.49
        self.assertTrue(window.reconciled)

    @mute_logger(WINDOW_LOG)
    def test_gateway_failure_imports_nothing(self):
        refused = FakeResponse(
            503, {"code": "upstream_unavailable", "message": "x", "request_id": "r-2"}, {"Retry-After": "1"}
        )
        self.session.route("GET", "/v1/payout/windows", refused, refused)
        self.assertFalse(self.pull())
        self.assertEqual(len(self.session.gateway_calls("GET")), 2)

    @mute_logger(WINDOW_LOG)
    def test_lines_failure_imports_no_window(self):
        refused = FakeResponse(500, {"code": "internal", "message": "x", "request_id": "r-3"})
        self.session.route("GET", f"/v1/payout/windows/{WINDOW_ID}/lines", refused)
        self.assertFalse(self.pull())

    def test_unconfigured_cron_is_a_noop(self):
        self.env["ir.config_parameter"].sudo().set_param("yantra.gateway_url", "")
        self.assertFalse(self.pull())
        self.assertEqual(self.session.gateway_calls(), [])


class TestPullButton(YantraCase):
    def test_the_button_shows_a_refusal_the_cron_only_logs(self):
        refused = FakeResponse(503, {"code": "upstream_unavailable", "message": "x", "request_id": "r-9"}, {"Retry-After": "1"})
        self.session.route("GET", "/v1/payout/windows", refused, refused)
        with self.assertRaisesRegex(UserError, "upstream_unavailable"):
            self.env["yantra.pay.window"].action_pull_paid_windows()
        self.env["ir.config_parameter"].sudo().set_param("yantra.gateway_url", "")
        with self.assertRaisesRegex(UserError, "not configured"):
            self.env["yantra.pay.window"].action_pull_paid_windows()
