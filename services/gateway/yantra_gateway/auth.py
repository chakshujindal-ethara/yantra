"""Keycloak-issued JWTs at the edge. The token's `sub` is the worker id; the realm role `ops` makes an operator.
Keys come from the realm's JWKS endpoint and rotate without a restart (PyJWKClient caches them for five minutes).
A token naming a key id the cache lacks refreshes the keys at most once a minute, so a stream of made-up key ids
never turns into a stream of fetches against the identity provider. A key fetch that fails is the identity provider
being away, not a bad token: it is a 503, logged at ERROR."""

import logging
import time
import uuid
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any

import jwt
from jwt import PyJWK, PyJWKClient, PyJWKClientConnectionError, PyJWKClientError

from yantra_common.errors import DomainError

log = logging.getLogger("yantra.gateway")
ALGORITHMS = ["RS256"]
REFRESH_SECONDS = 60.0  # an unknown key id refreshes the key set at most this often


class Unauthorized(DomainError):
    status = 401
    code = "unauthorized"


class IdentityProviderUnavailable(DomainError):
    status = 503
    code = "identity_unavailable"


@dataclass(frozen=True)
class Caller:
    worker_id: uuid.UUID
    roles: frozenset[str]
    token_id: str
    name: str | None = None  # the token's `name`, else `preferred_username`: a display string, never an identity
    email: str | None = None  # the token's `email` claim, when it has one
    email_verified: bool = False  # Keycloak's `email_verified`: only a verified address may bind an account


class Verifier:
    """Validates signature, issuer, audience, type and expiry; maps claims to a Caller."""

    def __init__(
        self,
        issuer: str,
        audience: str,
        jwks_url: str,
        leeway_seconds: int = 30,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.issuer = issuer.rstrip("/")
        self.audience = audience
        self.leeway = leeway_seconds
        self._jwks = PyJWKClient(jwks_url, cache_keys=True, lifespan=300, timeout=3)
        self.loaded = False  # keys fetched at least once: what the gateway's /ready reports
        self._clock = clock
        self._refreshed_at: float | None = None  # the last refresh an unknown key id caused

    def warm(self) -> bool:
        """Fetch the keys once at start-up so the first caller does not pay for it and /ready can tell whether the
        identity provider is reachable. A failure is logged and left for the first request to retry."""
        try:
            self._jwks.get_jwk_set()
        except PyJWKClientError as e:
            log.error("jwks warm-up failed url=%s reason=%s", self._jwks.uri, type(e).__name__)
            return False
        self.loaded = True
        return True

    def signing_key(self, token: str) -> Any:
        """The key the token's `kid` names, from the cached set. A kid the cache lacks (a rotation, or a forged
        header) refreshes the set, but at most once per REFRESH_SECONDS; inside that time it is refused at once."""
        kid = jwt.get_unverified_header(token).get("kid")
        found = _match(self._jwks.get_signing_keys(), kid)
        if found is not None:
            return found.key
        now = self._clock()
        if self._refreshed_at is not None and now - self._refreshed_at < REFRESH_SECONDS:
            raise PyJWKClientError("no signing key matches the token's kid (the key set was refreshed recently)")
        self._refreshed_at = now
        found = _match(self._jwks.get_signing_keys(refresh=True), kid)
        if found is None:
            raise PyJWKClientError("no signing key matches the token's kid")
        return found.key

    def verify(self, token: str) -> Caller:
        """Synchronous on purpose; the app runs it in a worker thread so a key fetch never blocks the loop."""
        try:
            key = self.signing_key(token)
        except PyJWKClientConnectionError as e:
            log.error("jwks unavailable url=%s reason=%s", self._jwks.uri, type(e).__name__)
            raise IdentityProviderUnavailable("identity provider unavailable") from e
        except PyJWKClientError as e:
            # the keys were fetched but none matches: a token from another realm, or stale keys at the JWKS URL
            log.warning("no signing key for token url=%s reason=%s", self._jwks.uri, type(e).__name__)
            raise Unauthorized("invalid token") from e
        except jwt.PyJWTError as e:
            log.info("token rejected reason=%s", type(e).__name__)
            raise Unauthorized("invalid token") from e
        try:
            claims = jwt.decode(
                token,
                key,
                algorithms=ALGORITHMS,
                audience=self.audience,
                issuer=self.issuer,
                leeway=self.leeway,
                options={"require": ["exp", "iat", "sub", "iss"]},
            )
        except jwt.PyJWTError as e:
            log.info("token rejected reason=%s", type(e).__name__)
            raise Unauthorized("invalid token") from e
        if claims.get("typ") != "Bearer":
            raise Unauthorized("not an access token")
        try:
            worker_id = uuid.UUID(str(claims["sub"]))
        except ValueError as e:
            raise Unauthorized("token subject is not a worker id") from e
        roles = frozenset(str(r) for r in (claims.get("realm_access") or {}).get("roles", []))
        self.loaded = True
        name = claims.get("name") or claims.get("preferred_username")
        return Caller(
            worker_id=worker_id,
            roles=roles,
            token_id=str(claims.get("jti", "")),
            name=str(name) if name else None,
            email=str(claims["email"]) if claims.get("email") else None,
            email_verified=claims.get("email_verified") is True,
        )


def _match(keys: Sequence[PyJWK], kid: object) -> PyJWK | None:
    return next((k for k in keys if k.key_id == kid), None)


def bearer_token(authorization: str | None) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise Unauthorized("bearer token required")
    return authorization[7:].strip()
