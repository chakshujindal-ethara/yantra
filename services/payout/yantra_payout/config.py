"""Payout's own settings: which rail pays, its credentials, the caps. Read from `YANTRA_*` like every setting.

`YANTRA_RAIL` picks the rail: `razorpayx` (the real API, or the WireMock emulator on the rig), `file` (a NEFT/IMPS
bulk file finance uploads to the bank, settled by the bank's return file) or `fake` (deterministic, tests only).
Choosing `razorpayx` without its key, secret and business account number, or with a webhook secret shorter than
32 characters (an empty one included), fails the process at boot."""

from decimal import Decimal
from functools import lru_cache
from typing import Literal, Self

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

RailName = Literal["razorpayx", "file", "fake"]
WEBHOOK_SECRET_MIN = 32


class PayoutSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="YANTRA_", extra="ignore")

    rail: RailName = "fake"
    razorpayx_key_id: str | None = None
    razorpayx_key_secret: SecretStr | None = None
    razorpayx_account_number: str | None = None
    razorpayx_webhook_secret: SecretStr | None = None  # unset: the webhook route answers 404 and the poll job settles
    razorpayx_base_url: str = "https://api.razorpay.com/v1"
    razorpayx_rate_limit_per_minute: int = Field(default=300, ge=1)
    razorpayx_timeout_seconds: float = Field(default=10.0, gt=0)
    razorpayx_payout_mode: Literal["NEFT", "IMPS"] = "IMPS"
    webhook_tolerance_seconds: int = Field(default=300, ge=1)
    payout_currencies: list[str] = ["INR"]
    payout_max_per_window: Decimal = Decimal("5000000")
    payout_max_per_worker: Decimal = Decimal("200000")
    validations_per_day: int = Field(default=3, ge=1)
    payout_integrity_hold_days: int = Field(default=30, ge=1)
    # how long a line sits in `processing` before the poll job asks the rail about it (the rig asks sooner)
    payout_poll_after_seconds: int = Field(default=120, ge=1)

    @model_validator(mode="after")
    def _razorpayx_needs_its_keys(self) -> Self:
        if self.rail == "razorpayx":
            missing = [
                name
                for name, value in (
                    ("YANTRA_RAZORPAYX_KEY_ID", self.razorpayx_key_id),
                    ("YANTRA_RAZORPAYX_KEY_SECRET", self.razorpayx_key_secret),
                    ("YANTRA_RAZORPAYX_ACCOUNT_NUMBER", self.razorpayx_account_number),
                )
                if not value
            ]
            if missing:
                raise ValueError(f"YANTRA_RAIL=razorpayx needs {', '.join(missing)}")
            secret = self.razorpayx_webhook_secret
            if secret is not None and len(secret.get_secret_value()) < WEBHOOK_SECRET_MIN:
                raise ValueError(
                    f"YANTRA_RAZORPAYX_WEBHOOK_SECRET must be at least {WEBHOOK_SECRET_MIN} characters (or unset)"
                )
        return self


@lru_cache(maxsize=1)
def payout_settings() -> PayoutSettings:
    return PayoutSettings()
