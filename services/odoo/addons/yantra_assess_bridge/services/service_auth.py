"""Who may call the bridge's service routes: Yantra's assess adapter, proven by a Keycloak token for the confidential
service client (`yantra-assess`). The token is verified here against the realm's signing keys (RS256 only; issuer,
expiry and the authorised party checked), so the bridge holds no shared secret of its own."""

import logging
import time

import jwt

_logger = logging.getLogger(__name__)
_JWKS = {}
JWKS_LIFESPAN = 600


class ServiceRefused(Exception):
    """The caller is not Yantra's assess adapter."""


def _client(url):
    entry = _JWKS.get(url)
    if entry is None or entry[1] < time.time():
        entry = (jwt.PyJWKClient(url, cache_keys=True, lifespan=JWKS_LIFESPAN, timeout=5), time.time() + JWKS_LIFESPAN)
        _JWKS[url] = entry
    return entry[0]


def bearer(headers):
    value = (headers.get("Authorization") or "").strip()
    return value[7:].strip() if value[:7].lower() == "bearer " else ""


def verify(env, token):
    """The verified claims of a service-client token, or ServiceRefused."""
    if not token:
        raise ServiceRefused("no token")
    params = env["ir.config_parameter"].sudo()
    issuer = params.get_param("yantra_assess_bridge.keycloak_issuer")
    jwks_url = params.get_param("yantra_assess_bridge.jwks_url")
    client_id = params.get_param("yantra_assess_bridge.service_client_id", "yantra-assess")
    if not issuer or not jwks_url:
        raise ServiceRefused("the bridge has no Keycloak settings")
    try:
        key = _client(jwks_url).get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            key.key,
            algorithms=["RS256"],
            issuer=issuer,
            options={"require": ["exp", "iss"], "verify_aud": False},
        )
    except jwt.PyJWTError as exc:
        raise ServiceRefused(f"token refused: {type(exc).__name__}") from exc
    if claims.get("azp") != client_id:
        raise ServiceRefused("token is not the assess service client's")
    return claims
