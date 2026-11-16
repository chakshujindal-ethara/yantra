"""Gateway settings. The issuer and audience pin which Keycloak realm may mint tokens for this gateway."""

from functools import lru_cache
from typing import Literal

from pydantic import Field, HttpUrl, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class GatewaySettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="YANTRA_GATEWAY_", extra="ignore")

    env: Literal["local", "staging", "prod"] = Field("local", validation_alias="YANTRA_ENV")
    keycloak_issuer: HttpUrl
    keycloak_jwks_url: HttpUrl | None = None  # where the keys are fetched from when that differs from the issuer
    allow_insecure_jwks: bool = False  # http:// keys only inside a private network (the local rig)
    audience: str = "yantra"
    allowed_origins: list[str] = []  # browser origins (the app); empty means no browser may call the gateway
    redis_url: str = "redis://localhost:6390/0"
    work_url: HttpUrl = HttpUrl("http://localhost:8081")
    money_url: HttpUrl = HttpUrl("http://localhost:8082")
    rate_limit_per_minute: int = 120
    upstream_timeout_seconds: float = 10.0
    idempotency_ttl_seconds: int = 48 * 3600
    max_body_bytes: int = 8 * 1024 * 1024

    @model_validator(mode="after")
    def _insecure_keys_only_on_the_rig(self) -> "GatewaySettings":
        """`ALLOW_INSECURE_JWKS` is for the local rig's private network; anywhere else it fails the boot."""
        if self.allow_insecure_jwks and self.env != "local":
            raise ValueError("YANTRA_GATEWAY_ALLOW_INSECURE_JWKS is only allowed with YANTRA_ENV=local")
        return self

    @model_validator(mode="after")
    def _keys_come_from_the_issuer_realm(self) -> "GatewaySettings":
        """A JWKS URL must belong to the issuer's realm and travel over TLS: whoever serves the keys decides who
        is a worker."""
        if self.keycloak_jwks_url is None:
            return self
        issuer_realm = str(self.keycloak_issuer).rstrip("/").rsplit("/realms/", 1)[-1]
        jwks_realm = str(self.keycloak_jwks_url).split("/realms/", 1)[-1].split("/", 1)[0]
        if issuer_realm != jwks_realm:
            raise ValueError(f"keycloak_jwks_url realm {jwks_realm!r} is not the issuer's realm {issuer_realm!r}")
        if self.keycloak_jwks_url.scheme != "https" and not self.allow_insecure_jwks:
            raise ValueError("keycloak_jwks_url must be https unless YANTRA_GATEWAY_ALLOW_INSECURE_JWKS=true")
        return self

    @property
    def jwks_url(self) -> str:
        """Inside a cluster the issuer is the public URL and the keys come from the internal one."""
        if self.keycloak_jwks_url is not None:
            return str(self.keycloak_jwks_url)
        return str(self.keycloak_issuer).rstrip("/") + "/protocol/openid-connect/certs"


@lru_cache(maxsize=1)
def gateway_settings() -> GatewaySettings:
    return GatewaySettings()  # pydantic-settings reads the required issuer from the environment
