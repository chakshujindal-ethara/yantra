"""Only Yantra's assess adapter may call the service routes: a Keycloak token for the service client, RS256, from the
right issuer, not expired, signed by the realm's key."""

from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.yantra_assess_bridge.services import service_auth

from .common import OTHER_KEY, bridge_settings, keycloak_keys, service_token


@tagged("post_install", "-at_install")
class TestServiceAuth(TransactionCase):
    def setUp(self):
        super().setUp()
        bridge_settings(self.env)

    def test_the_service_clients_token_is_accepted(self):
        with keycloak_keys():
            claims = service_auth.verify(self.env, service_token())
        self.assertEqual(claims["azp"], "yantra-assess")

    def test_every_other_token_is_refused(self):
        cases = {
            "no token": "",
            "another client": service_token(azp="yantra-app"),
            "another issuer": service_token(issuer="http://evil/realms/yantra"),
            "expired": service_token(exp_in=-60),
            "another key": service_token(key=OTHER_KEY),
            "hmac instead of rsa": service_token(alg="HS256"),
        }
        with keycloak_keys():
            for label, token in cases.items():
                with self.subTest(label), self.assertRaises(service_auth.ServiceRefused):
                    service_auth.verify(self.env, token)

    def test_no_keycloak_settings_means_no_service_caller(self):
        self.env["ir.config_parameter"].sudo().set_param("yantra_assess_bridge.jwks_url", "")
        with self.assertRaises(service_auth.ServiceRefused):
            service_auth.verify(self.env, service_token())

    def test_the_bearer_header_is_read_case_blind_and_nothing_else_counts(self):
        self.assertEqual(service_auth.bearer({"Authorization": "bearer abc"}), "abc")
        self.assertEqual(service_auth.bearer({"Authorization": "Basic abc"}), "")
        self.assertEqual(service_auth.bearer({}), "")

    def test_the_key_client_is_cached_for_its_lifespan(self):
        service_auth._JWKS.clear()
        with patch.object(service_auth.jwt, "PyJWKClient") as make:
            service_auth._client("http://keys")
            service_auth._client("http://keys")
        make.assert_called_once()
        service_auth._JWKS.clear()
