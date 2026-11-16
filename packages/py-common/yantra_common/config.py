"""Settings come from the environment, never from code. One object per process.
`YANTRA_DATABASE_URL` is required: a misconfigured process fails at boot instead of talking to localhost.
`YANTRA_PII_KEY` keys the HMAC under which talent stores a PAN, an account number or a legal name: with a secret
key a digest kept beside the last four digits cannot be brute-forced back to the value. The default is for the
local rig only."""

import base64
import binascii
import os
from collections.abc import Mapping
from functools import lru_cache
from typing import Literal

from pydantic import PostgresDsn, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

LOCAL_PII_KEY = "local-dev-pii-key-change-me"
# `v0:` + base64 of 32 bytes. For a developer's machine only, like the PII key; every deployed environment sets its
# own `YANTRA_BANK_KEY` and keeps the previous one in `YANTRA_BANK_KEY_PREVIOUS` while sealed values are rotated.
LOCAL_BANK_KEY = "v0:" + base64.b64encode(b"local-dev-bank-key-change-me-32b").decode()
RIG_BANK_KEY = "v1:bG9jYWwtcmlnLWJhbmsta2V5LTMyLWJ5dGVzLW9rISE="  # deployment/local/compose.yaml, values-local.yaml
RIG_BANK_KEYS = frozenset({LOCAL_BANK_KEY, RIG_BANK_KEY})
Env = Literal["local", "staging", "prod"]
# values that ship in this repository (code defaults, deployment/local/compose.yaml, the kind values, the WireMock
# RazorpayX emulator): a deployed environment refuses to boot on any of them
KNOWN_LOCAL_SECRETS = frozenset(
    {
        LOCAL_PII_KEY,
        "local-rig-pii-key",
        "yantra",  # the owner role's password, the MinIO root user
        "yantra_work",
        "yantra_money",
        "yantra-local-secret",  # MinIO
        "rzp_test_yantra",  # the emulator's RazorpayX key id
        "yantra-local-razorpayx-secret",
        "yantra-odoo-local-secret",
        "yantra-assess-local-secret",  # the Assessment v2 bridge's Keycloak service client
        *RIG_BANK_KEYS,
    }
)
# settings other modules own (object storage, the RazorpayX rail), checked by name so this module imports neither
NAMED_SECRETS = (
    "YANTRA_ASSESS_CLIENT_SECRET",
    "YANTRA_S3_ACCESS_KEY",
    "YANTRA_S3_SECRET_KEY",
    "YANTRA_RAZORPAYX_KEY_ID",
    "YANTRA_RAZORPAYX_KEY_SECRET",
    "YANTRA_RAZORPAYX_WEBHOOK_SECRET",
)
MIN_SECRET_LENGTH = 32


def parse_key(value: str) -> tuple[str, bytes]:
    """`<id>:<base64 of 32 bytes>` into the id and the key. The id is stored beside every sealed value."""
    key_id, sep, encoded = value.partition(":")
    if not sep or not key_id or len(key_id) > 16:
        raise ValueError("a key is '<id>:<base64 of 32 bytes>' with an id of at most 16 characters")
    try:
        raw = base64.b64decode(encoded, validate=True)
    except binascii.Error as e:
        raise ValueError("the key is not valid base64") from e
    if len(raw) != 32:
        raise ValueError("the key must decode to 32 bytes (AES-256)")
    return key_id, raw


class PiiSettings(BaseSettings):
    """The PII key alone, so a module can hash without the whole process configuration (a test needs no database URL
    to hash a PAN). `Settings` carries the same field."""

    model_config = SettingsConfigDict(env_prefix="YANTRA_", extra="ignore")

    pii_key: str = LOCAL_PII_KEY


class BankKeySettings(BaseSettings):
    """The AES-256-GCM key that seals bank account numbers (`yantra_common.crypto`), and the previous one while a
    rotation is under way. Checked at load: a key that is not 32 bytes fails the process at boot."""

    model_config = SettingsConfigDict(env_prefix="YANTRA_", extra="ignore")

    env: Env = "local"  # YANTRA_ENV: anything but `local` refuses the rig's secrets
    bank_key: str = LOCAL_BANK_KEY
    bank_key_previous: str | None = None

    @field_validator("bank_key", "bank_key_previous")
    @classmethod
    def _well_formed(cls, value: str | None) -> str | None:
        if value is not None:
            parse_key(value)
        return value


class Settings(PiiSettings, BankKeySettings):
    database_url: PostgresDsn
    # YANTRA_REQUIRES_BANK_KEY: set on the money processes only (they seal and open account numbers), so a deployed
    # one refuses to boot without its own key; work never holds the bank key
    requires_bank_key: bool = False
    nats_url: str = "nats://localhost:4222"
    rate_limit_per_minute: int = 120
    max_body_bytes: int = 8 * 1024 * 1024
    smtp_host: str | None = None  # unset: notifications stay in the inbox, no email leaves
    smtp_port: int = 1025
    mail_from: str = "Yantra <no-reply@yantra.local>"
    outbox_stuck_seconds: int = 300  # an events process whose oldest unpublished row is older, not draining: unready
    events_port: int = 8085  # the events process's own /health, /ready (money runs it on 8086)
    scheduler_concurrency: int = 2


class RigSecretsRefused(RuntimeError):
    """A deployed environment configured with a key or password this repository publishes."""


BANK_KEY_PROBLEM = "YANTRA_BANK_KEY / YANTRA_BANK_KEY_PREVIOUS (not the local key)"


def _rig_bank_key(s: BankKeySettings) -> bool:
    return bool({s.bank_key, s.bank_key_previous} & RIG_BANK_KEYS)


def refuse_rig_secrets(s: Settings, environ: Mapping[str, str] | None = None) -> None:
    """Staging and production never run on a key or password this repository publishes: the process fails at boot,
    naming the settings, never their values (a pydantic validator would echo the input into the boot log).
    `environ` (default: the process environment) holds the settings other modules own, checked by name."""
    if s.env == "local":
        return
    env = os.environ if environ is None else environ
    problems = []
    if s.pii_key in KNOWN_LOCAL_SECRETS or len(s.pii_key) < MIN_SECRET_LENGTH:
        problems.append(f"YANTRA_PII_KEY (a secret of at least {MIN_SECRET_LENGTH} characters)")
    if s.requires_bank_key and _rig_bank_key(s):
        problems.append(BANK_KEY_PROBLEM)
    if s.database_url.hosts()[0].get("password") in KNOWN_LOCAL_SECRETS:
        problems.append("the YANTRA_DATABASE_URL password")
    problems.extend(name for name in NAMED_SECRETS if env.get(name) in KNOWN_LOCAL_SECRETS)
    if problems:
        raise RigSecretsRefused(f"YANTRA_ENV={s.env} refuses the local rig's values for: " + "; ".join(problems))


@lru_cache(maxsize=1)
def settings() -> Settings:
    s = Settings()  # pydantic-settings reads the required field from the environment
    refuse_rig_secrets(s)
    return s


@lru_cache(maxsize=1)
def pii_settings() -> PiiSettings:
    return PiiSettings()


@lru_cache(maxsize=1)
def bank_key_settings() -> BankKeySettings:
    """Read where a value is sealed or opened: a deployed process that never set its own key fails there, even one
    that booted without YANTRA_REQUIRES_BANK_KEY."""
    s = BankKeySettings()
    if s.env != "local" and _rig_bank_key(s):
        raise RigSecretsRefused(f"YANTRA_ENV={s.env} refuses the local rig's values for: {BANK_KEY_PROBLEM}")
    return s
