"""The rails that move money. One protocol, three adapters: RazorpayX (the real API; on the rig, a WireMock
emulator of it), a bank file (NEFT/IMPS bulk upload, settled by the bank's return file) and a deterministic fake
for tests. Stripe would be one more adapter behind the same protocol.

Rules every adapter keeps: a payout carries `<line_id>:<attempt>` both as its reference and as its idempotency
key, so the rail itself refuses a second payout of one attempt and a lookup finds exactly one attempt (never an
older one); a timeout after a payout request was sent is an unknown outcome (`RailUnknownOutcome`), resolved by
looking the payout up by that reference, never by sending it again blindly."""

import uuid
from dataclasses import dataclass
from decimal import Decimal
from typing import TYPE_CHECKING, Literal, Protocol

if TYPE_CHECKING:
    from yantra_payout.config import PayoutSettings

ValidationStatus = Literal["pending", "verified", "failed"]
PayoutStatus = Literal["queued", "processing", "paid", "failed", "returned"]


@dataclass(frozen=True)
class Registered:
    contact_id: str
    fund_account_id: str


@dataclass(frozen=True)
class Validation:
    id: str
    status: ValidationStatus
    registered_name: str | None = None
    reason: str | None = None


@dataclass(frozen=True)
class PayoutRequest:
    line_id: uuid.UUID
    attempt: int
    fund_account_id: str
    amount: Decimal
    currency: str
    narration: str

    @property
    def reference_id(self) -> str:
        """The attempt, as the rail's `reference_id`: at most 40 characters (a UUID, a colon, up to 999)."""
        return f"{self.line_id}:{self.attempt}"

    @property
    def idempotency_key(self) -> str:
        return self.reference_id


@dataclass(frozen=True)
class PayoutResult:
    reference: str
    status: PayoutStatus
    utr: str | None = None
    reason: str | None = None
    amount: Decimal | None = None
    reference_id: str | None = None  # the `<line_id>:<attempt>` the payout was sent for, when the rail says


class RailError(Exception):
    """The rail refused the request (a 4xx): retrying the same request will not help."""

    def __init__(self, code: str, message: str = "", status: int = 400) -> None:
        super().__init__(message or code)
        self.code, self.status = code, status


class RailUnavailable(Exception):
    """The rail did not answer usefully after every retry: try the whole step again later."""


class RailUnknownOutcome(Exception):
    """A payout request may have reached the rail but no answer came back: look it up by reference."""


class Rail(Protocol):
    name: str
    supports_penny_drop: bool

    def register(self, worker_id: uuid.UUID, account_name: str, account_number: str, ifsc: str) -> Registered: ...

    def start_validation(self, fund_account_id: str, account_name: str, worker_id: uuid.UUID) -> Validation: ...

    def fetch_validation(self, validation_id: str) -> Validation: ...

    def create_payout(self, request: PayoutRequest) -> PayoutResult: ...

    def fetch_payout(self, reference: str) -> PayoutResult: ...

    def find_payout(self, reference_id: str) -> PayoutResult | None: ...


def select_rail(settings: "PayoutSettings") -> Rail:
    """The rail `YANTRA_RAIL` names, built from the payout settings."""
    from yantra_payout.rails.fake import FakeRail
    from yantra_payout.rails.file import FileRail
    from yantra_payout.rails.razorpayx import RazorpayXRail

    if settings.rail == "razorpayx":
        assert settings.razorpayx_key_id and settings.razorpayx_key_secret and settings.razorpayx_account_number
        return RazorpayXRail(
            key_id=settings.razorpayx_key_id,
            key_secret=settings.razorpayx_key_secret.get_secret_value(),
            account_number=settings.razorpayx_account_number,
            base_url=settings.razorpayx_base_url,
            timeout=settings.razorpayx_timeout_seconds,
            rate_limit_per_minute=settings.razorpayx_rate_limit_per_minute,
            mode=settings.razorpayx_payout_mode,
        )
    if settings.rail == "file":
        return FileRail()
    return FakeRail()
