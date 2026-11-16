import re

from odoo.exceptions import UserError, ValidationError
from odoo.tools import mute_logger

from .common import SUB_A, FakeResponse, YantraCase

IDEMPOTENCY_KEY = re.compile(r"^[A-Za-z0-9._:-]{8,200}$")
WORKER_LOG = "odoo.addons.yantra_bridge.models.worker"


class TestWorker(YantraCase):
    def test_partner_auto_created_as_supplier(self):
        worker = self.make_worker(complete=False)
        self.assertTrue(worker.partner_id)
        self.assertEqual(worker.partner_id.name, "Asha Worker")
        self.assertEqual(worker.partner_id.email, "asha@example.test")
        self.assertEqual(worker.partner_id.supplier_rank, 1)
        self.assertEqual(worker.tds_rate, 10.0)

    def test_keycloak_sub_must_be_uuid(self):
        with self.assertRaises(ValidationError):
            self.make_worker(sub="not-a-uuid", complete=False)

    def test_keycloak_sub_unique(self):
        self.make_worker(complete=False)
        with self.assertRaises(Exception), mute_logger("odoo.sql_db"):
            self.make_worker(complete=False)

    def test_bank_account_lives_on_partner_bank(self):
        worker = self.make_worker()
        self.assertEqual(worker.bank_id.partner_id, worker.partner_id)
        self.assertEqual(worker.bank_id.acc_number, "123456789012")
        self.assertEqual(worker.bank_account_last4, "9012")
        self.assertEqual(worker.bank_id.acc_holder_name, "Asha Worker")
        self.assertFalse(
            "bank_account_number" in self.env["yantra.worker"]._fields
            and self.env["yantra.worker"]._fields["bank_account_number"].store
        )

    def test_eligibility_refusals_name_the_field(self):
        for missing, label in (
            ("agreement_signed_at", "Agreement signed at"),
            ("dpdp_consent_at", "DPDP consent at"),
        ):
            with self.subTest(missing=missing):
                worker = self.make_worker(sub=self._fresh_sub(missing), **{missing: False})
                with self.assertRaises(UserError) as ctx:
                    worker.action_mark_eligible()
                self.assertIn(missing, str(ctx.exception))
                self.assertIn(label, str(ctx.exception))
                self.assertEqual(worker.status, "draft")
        worker = self.make_worker(sub=self._fresh_sub("bank"), bank_account_number=False)
        with self.assertRaises(UserError) as ctx:
            worker.action_mark_eligible()
        self.assertIn("bank_id", str(ctx.exception))
        self.assertEqual(worker.status, "draft")
        self.assertEqual(self.session.gateway_calls(), [])

    def test_mark_eligible_pushes_worker(self):
        worker = self.make_worker()
        self.session.route("PUT", f"/v1/workers/{SUB_A}", FakeResponse(200, {"id": SUB_A}))
        worker.action_mark_eligible()
        self.assertEqual(worker.status, "eligible")
        (call,) = self.session.gateway_calls("PUT")
        self.assertEqual(call.path, f"/v1/workers/{SUB_A}")
        self.assertEqual(
            call.json, {"status": "eligible", "cert_gates": ["labelling_v1"], "partner_ref": worker.partner_id.id}
        )
        self.assertEqual(call.headers["Authorization"], "Bearer tok-1")
        self.assertRegex(call.headers["Idempotency-Key"], IDEMPOTENCY_KEY)
        self.assertEqual(self.session.token_calls, 1)

    @mute_logger(WORKER_LOG)
    def test_push_failure_keeps_draft_and_names_the_code(self):
        worker = self.make_worker()
        refused = FakeResponse(
            503, {"code": "upstream_unavailable", "message": "try again", "request_id": "r-9"}, {"Retry-After": "2"}
        )
        self.session.route("PUT", f"/v1/workers/{SUB_A}", refused, refused)
        with self.assertRaises(UserError) as ctx:
            worker.action_mark_eligible()
        self.assertIn("upstream_unavailable", str(ctx.exception))
        self.assertIn("r-9", str(ctx.exception))
        self.assertEqual(worker.status, "draft")
        self.assertEqual(len(self.session.gateway_calls("PUT")), 2, "exactly one retry")
        self.assertEqual(len(self.sleeps), 1)
        self.assertGreaterEqual(self.sleeps[0], 2)
        self.assertLess(self.sleeps[0], 2.5)

    def test_retry_once_on_429_then_success(self):
        worker = self.make_worker()
        self.session.route(
            "PUT",
            f"/v1/workers/{SUB_A}",
            FakeResponse(
                429, {"code": "rate_limited", "message": "slow down", "request_id": "r-1"}, {"Retry-After": "1"}
            ),
            FakeResponse(200, {"id": SUB_A}),
        )
        worker.action_mark_eligible()
        self.assertEqual(worker.status, "eligible")
        self.assertEqual(len(self.session.gateway_calls("PUT")), 2)

    def test_token_is_cached_across_actions(self):
        worker = self.make_worker()
        self.session.route("PUT", f"/v1/workers/{SUB_A}", FakeResponse(200, {}))
        worker.action_mark_eligible()
        worker.action_activate()
        worker.action_suspend()
        worker.action_offboard()
        self.assertEqual(worker.status, "offboarded")
        self.assertEqual(self.session.token_calls, 1)
        self.assertEqual(
            [c.json["status"] for c in self.session.gateway_calls("PUT")],
            ["eligible", "active", "suspended", "offboarded"],
        )
        keys = {c.headers["Idempotency-Key"] for c in self.session.gateway_calls("PUT")}
        self.assertEqual(len(keys), 4, "one Idempotency-Key per logical action")

    def test_illegal_transition_refused_without_push(self):
        worker = self.make_worker()
        with self.assertRaises(UserError):
            worker.action_activate()
        self.assertEqual(self.session.gateway_calls(), [])

    def test_unconfigured_gateway_is_a_user_error(self):
        self.env["ir.config_parameter"].sudo().set_param("yantra.keycloak_client_secret", "")
        worker = self.make_worker()
        with self.assertRaises(UserError) as ctx:
            worker.action_mark_eligible()
        self.assertIn("yantra.keycloak_client_secret", str(ctx.exception))
        self.assertEqual(worker.status, "draft")

    @staticmethod
    def _fresh_sub(seed):
        import uuid

        return str(uuid.uuid5(uuid.NAMESPACE_DNS, seed))


class TestWorkerGuards(YantraCase):
    def test_transitions_are_one_worker_at_a_time(self):
        a = self.make_worker()
        b = self.make_worker(sub="44444444-4444-4444-8444-444444444444", name="Bina Worker", email="bina@example.test")
        with self.assertRaisesRegex(UserError, "one worker at a time"):
            (a | b).action_mark_eligible()
        self.assertEqual(self.session.gateway_calls("PUT"), [])

    def test_a_gate_change_on_an_eligible_worker_is_pushed_at_once(self):
        worker = self.make_worker()
        self.session.route("PUT", f"/v1/workers/{SUB_A}", FakeResponse(200, {"id": SUB_A}), FakeResponse(200, {"id": SUB_A}))
        worker.action_mark_eligible()
        gate = self.env["yantra.cert.gate"].create({"code": "transcription_v2", "name": "Transcription v2"})
        worker.write({"cert_gate_ids": [(4, gate.id)]})
        first, second = self.session.gateway_calls("PUT")
        self.assertEqual(sorted(second.json["cert_gates"]), ["labelling_v1", "transcription_v2"])
        draft = self.make_worker(sub="55555555-5555-4555-8555-555555555555", name="Dev Worker", email="dev@example.test")
        draft.write({"cert_gate_ids": [(4, gate.id)]})
        self.assertEqual(len(self.session.gateway_calls("PUT")), 2)  # a draft worker is not pushed
