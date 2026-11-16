from odoo.exceptions import UserError
from odoo.tools import mute_logger

from .common import FakeResponse, YantraCase

BATCH_ID = "bbbbbbbb-0000-4000-8000-000000000001"
BATCH_LOG = "odoo.addons.yantra_bridge.models.client_project"


class TestBatch(YantraCase):
    def setUp(self):
        super().setUp()
        customer = self.env["res.partner"].create({"name": "Acme Labs", "is_company": True, "customer_rank": 1})
        self.project = self.env["yantra.client.project"].create(
            {"name": "Acme labelling", "partner_id": customer.id, "gateway_id": "pppppppp-0000-4000-8000-000000000001"}
        )
        self.batch = self.env["yantra.batch"].create(
            {"gateway_id": BATCH_ID, "project_id": self.project.id, "title": "Acme batch 7"}
        )
        self.manifest_path = f"/v1/batches/{BATCH_ID}/manifest"

    @mute_logger(BATCH_LOG)
    def test_manifest_409_batch_held_raises_with_counts(self):
        self.session.route(
            "GET",
            self.manifest_path,
            FakeResponse(
                409,
                {
                    "code": "batch_held",
                    "message": "not every unit is accepted",
                    "request_id": "r-7",
                    "pending": 3,
                    "rejected": 1,
                },
            ),
        )
        with self.assertRaises(UserError) as ctx:
            self.batch.action_invoice_batch()
        message = str(ctx.exception)
        self.assertIn("batch_held", message)
        self.assertIn("pending=3", message)
        self.assertIn("rejected=1", message)
        self.assertFalse(self.batch.invoice_id)

    def test_manifest_200_creates_one_invoice_and_reopens_it(self):
        self.session.route(
            "GET",
            self.manifest_path,
            FakeResponse(
                200,
                {
                    "batch_id": BATCH_ID,
                    "project_id": self.project.gateway_id,
                    "title": "Acme batch 7",
                    "currency": "INR",
                    "unit_price": "12.500000",
                    "accepted_units": 40,
                    "total_price": "500.000000",
                    "units": [
                        {
                            "unit_id": "u-1",
                            "external_ref": "row-1",
                            "answer": {"label": "cat"},
                            "rubric_version": 2,
                            "submitted_at": "2026-10-30T10:00:00+00:00",
                        }
                    ],
                },
            ),
        )
        action = self.batch.action_invoice_batch()
        invoice = self.batch.invoice_id
        self.assertTrue(invoice)
        self.assertEqual(action["res_id"], invoice.id)
        self.assertEqual(invoice.move_type, "out_invoice")
        self.assertEqual(invoice.partner_id, self.project.partner_id)
        self.assertEqual(invoice.currency_id.name, "INR")
        (line,) = invoice.invoice_line_ids
        self.assertEqual(line.quantity, 40)
        self.assertAlmostEqual(line.price_unit, 12.5, places=2)
        self.assertFalse(line.tax_ids)
        self.assertAlmostEqual(invoice.amount_total, 500.0, places=2)
        self.assertEqual(self.batch.accepted_units, 40)
        self.assertAlmostEqual(self.batch.total_price, 500.0, places=2)

        again = self.batch.action_invoice_batch()
        self.assertEqual(again["res_id"], invoice.id)
        self.assertEqual(len(self.session.gateway_calls("GET")), 1, "second click opens, never re-fetches")
        self.assertEqual(self.env["account.move"].search_count([("ref", "=", f"yantra:batch:{BATCH_ID}")]), 1)

    def test_manifest_total_mismatch_refused(self):
        self.session.route(
            "GET",
            self.manifest_path,
            FakeResponse(
                200,
                {
                    "batch_id": BATCH_ID,
                    "currency": "INR",
                    "unit_price": "12.5",
                    "accepted_units": 40,
                    "total_price": "499.99",
                    "units": [],
                },
            ),
        )
        with self.assertRaises(UserError):
            self.batch.action_invoice_batch()
        self.assertFalse(self.batch.invoice_id)
