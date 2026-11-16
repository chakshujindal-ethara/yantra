"""Shared fixtures: a fake `requests` session routed by (method, path), the settings, a loaded chart."""

from dataclasses import dataclass, field
from unittest.mock import patch

from odoo.addons.yantra_bridge import gateway_client
from odoo.tests import TransactionCase, tagged

GATEWAY = "http://gateway.test"
KEYCLOAK = "http://keycloak.test"
TOKEN_URL = f"{KEYCLOAK}/realms/yantra/protocol/openid-connect/token"
SUB_A = "11111111-1111-4111-8111-111111111111"
SUB_B = "22222222-2222-4222-8222-222222222222"
SUB_UNKNOWN = "33333333-3333-4333-8333-333333333333"


@dataclass
class FakeResponse:
    status_code: int = 200
    body: object = None
    headers: dict = field(default_factory=dict)

    @property
    def content(self):
        return b"" if self.body is None else b"{}"

    def json(self):
        return self.body


@dataclass
class Call:
    method: str
    url: str
    params: object
    json: object
    headers: dict

    @property
    def path(self):
        return self.url.removeprefix(GATEWAY)


class FakeSession:
    """Routes (method, path) to a response or a list of responses consumed in order. Records gateway calls."""

    def __init__(self):
        self.routes = {}
        self.calls = []
        self.token_calls = 0

    def route(self, method, path, *responses):
        self.routes[(method, path)] = list(responses)

    def request(self, method, url, params=None, json=None, headers=None, data=None, timeout=None):
        if url == TOKEN_URL:
            self.token_calls += 1
            assert data["grant_type"] == "client_credentials"
            return FakeResponse(200, {"access_token": "tok-1", "expires_in": 300})
        call = Call(method, url, params, json, headers or {})
        self.calls.append(call)
        queue = self.routes.get((method, call.path))
        if not queue:
            raise AssertionError(f"unexpected gateway call {method} {call.path}")
        return queue.pop(0) if len(queue) > 1 else queue[0]

    def gateway_calls(self, method=None):
        return [c for c in self.calls if method is None or c.method == method]


@tagged("post_install", "-at_install")
class YantraCase(TransactionCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.env["account.chart.template"].try_loading("generic_coa", company=cls.env.company, install_demo=False)
        icp = cls.env["ir.config_parameter"].sudo()
        icp.set_param("yantra.gateway_url", GATEWAY)
        icp.set_param("yantra.keycloak_url", KEYCLOAK)
        icp.set_param("yantra.keycloak_client_id", "yantra-odoo")
        icp.set_param("yantra.keycloak_client_secret", "s3cret")
        icp.set_param("yantra.default_tds_rate", "10")
        cls.gate = cls.env["yantra.cert.gate"].create({"code": "labelling_v1", "name": "Labelling v1"})

    def setUp(self):
        super().setUp()
        self.session = FakeSession()
        self.sleeps = []
        for target, replacement in (("SESSION", self.session), ("_sleep", self.sleeps.append)):
            patcher = patch.object(gateway_client, target, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)
        gateway_client._TOKENS.clear()
        self.addCleanup(gateway_client._TOKENS.clear)

    def make_worker(self, sub=SUB_A, complete=True, **vals):
        base = {"name": "Asha Worker", "email": "asha@example.test", "keycloak_sub": sub}
        if complete:
            base.update(
                agreement_signed_at="2026-10-01 10:00:00",
                dpdp_consent_at="2026-10-01 10:05:00",
                dpdp_consent_text="I consent.",
                account_holder="Asha Worker",
                bank_ifsc="HDFC0000001",
                bank_account_number="123456789012",
                pan="ABCDE1234F",
                cert_gate_ids=[(6, 0, self.gate.ids)],
            )
        base.update(vals)
        return self.env["yantra.worker"].create(base)
