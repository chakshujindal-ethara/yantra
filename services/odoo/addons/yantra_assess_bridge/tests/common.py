"""Test helpers: a local RSA key standing in for Keycloak's, and service-client tokens signed with it."""

import time
from contextlib import contextmanager
from unittest.mock import patch

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

from odoo.addons.yantra_assess_bridge.services import service_auth

ISSUER = "http://localhost:8180/realms/yantra"
JWKS_URL = "http://keycloak:8080/realms/yantra/protocol/openid-connect/certs"
CLIENT = "yantra-assess"
KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def service_token(azp=CLIENT, issuer=ISSUER, exp_in=300, key=KEY, alg="RS256", **extra):
    claims = {"iss": issuer, "azp": azp, "exp": int(time.time()) + exp_in, "sub": "service-account", **extra}
    return jwt.encode(claims, key if alg.startswith("RS") else "not-a-secret", algorithm=alg)


class _Key:
    key = KEY.public_key()


class _Client:
    def get_signing_key_from_jwt(self, token):
        return _Key()


@contextmanager
def keycloak_keys():
    """The realm's signing keys, served from memory instead of Keycloak."""
    with patch.object(service_auth, "_client", return_value=_Client()):
        yield


def bridge_settings(env):
    params = env["ir.config_parameter"].sudo()
    params.set_param("yantra_assess_bridge.keycloak_issuer", ISSUER)
    params.set_param("yantra_assess_bridge.jwks_url", JWKS_URL)
    params.set_param("yantra_assess_bridge.service_client_id", CLIENT)
    params.set_param("yantra_assess_bridge.app_url", "http://localhost:8096")
    params.set_param("yantra_assess_bridge.return_origins", "http://localhost:8095")
    params.set_param("yantra_assess_bridge.suppress_invitations", "1")
    params.set_param("yantra_assess_bridge.ticket_ttl_seconds", "120")
