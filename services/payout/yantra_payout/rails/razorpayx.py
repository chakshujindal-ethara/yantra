"""The RazorpayX adapter: contacts, fund accounts, fund-account validation (the penny drop) and payouts.

Every call has a timeout (10 s, 3 s to connect), goes through a client-side limiter, and is retried at most three
times on 429/5xx (honouring Retry-After, else full-jitter backoff) and on connection errors. A 4xx is a
`RailError` carrying RazorpayX's error code. On `POST /payouts` a read timeout, and a 4xx after an earlier try that
may have reached RazorpayX (a 5xx or a dropped connection), are `RailUnknownOutcome`: the caller looks the payout
up by its `reference_id` (`<line_id>:<attempt>`) before anything is sent again. Bodies are never logged: they carry
names and account numbers. Amounts go out as integer paise; only INR is paid on this rail."""

import logging
import random
import time
import uuid
from collections.abc import Callable
from decimal import Decimal
from typing import Any

import httpx

from yantra_common.metrics import RAIL_CALLS
from yantra_common.ratelimit import SlidingWindowLimiter
from yantra_payout.rails import (
    PayoutRequest,
    PayoutResult,
    PayoutStatus,
    RailError,
    RailUnavailable,
    RailUnknownOutcome,
    Registered,
    Validation,
)

log = logging.getLogger("yantra.payout.razorpayx")
ATTEMPTS = 3
STATUS: dict[str, PayoutStatus] = {
    "queued": "queued",
    "pending": "queued",
    "scheduled": "queued",
    "processing": "processing",
    "processed": "paid",
    "rejected": "failed",
    "cancelled": "failed",
    "failed": "failed",
    "reversed": "returned",
}
NARRATION = 30


def paise(amount: Decimal) -> int:
    return int((amount * 100).to_integral_value())


def narration(text: str) -> str:
    """RazorpayX takes at most 30 letters, digits and spaces."""
    return "".join(c for c in text if c.isalnum() or c == " ")[:NARRATION].strip() or "Yantra payout"


class RazorpayXRail:
    name = "razorpayx"
    supports_penny_drop = True

    def __init__(
        self,
        key_id: str,
        key_secret: str,
        account_number: str,
        base_url: str = "https://api.razorpay.com/v1",
        timeout: float = 10.0,
        rate_limit_per_minute: int = 300,
        mode: str = "IMPS",
        client: httpx.Client | None = None,
        sleep: Callable[[float], None] = time.sleep,
        rng: Callable[[float, float], float] = random.uniform,
        limiter: SlidingWindowLimiter | None = None,
    ) -> None:
        self.account_number, self.mode = account_number, mode
        self.http = client or httpx.Client(
            base_url=base_url, auth=(key_id, key_secret), timeout=httpx.Timeout(timeout, connect=3.0)
        )
        self.sleep, self.rng = sleep, rng
        self.limiter = limiter or SlidingWindowLimiter(rate_limit_per_minute)

    # ---------- transport ----------

    def _wait_for_slot(self) -> None:
        while (wait := self.limiter.check("razorpayx")) > 0:
            self.sleep(wait)

    def _call(
        self,
        method: str,
        path: str,
        json: dict[str, Any] | None = None,
        params: dict[str, str] | None = None,
        idempotency_key: str | None = None,
    ) -> dict[str, Any]:
        headers = {"X-Payout-Idempotency": idempotency_key} if idempotency_key else {}
        paying = method == "POST" and path == "/payouts"
        ambiguous = False  # an earlier try may have created the payout
        for attempt in range(1, ATTEMPTS + 1):
            self._wait_for_slot()
            try:
                r = self.http.request(method, path, json=json, params=params, headers=headers)
            except httpx.ReadTimeout as e:
                RAIL_CALLS.labels("razorpayx", "timeout").inc()
                if paying:
                    log.warning("razorpayx payout timed out path=%s attempt=%s", path, attempt)
                    raise RailUnknownOutcome(path) from e
                log.warning("razorpayx timeout path=%s attempt=%s", path, attempt)
                self._backoff(attempt, None)
                continue
            except httpx.TransportError as e:
                RAIL_CALLS.labels("razorpayx", "unreachable").inc()
                log.warning("razorpayx unreachable path=%s attempt=%s", path, attempt)
                ambiguous = ambiguous or not isinstance(e, httpx.ConnectError | httpx.ConnectTimeout)
                self._backoff(attempt, None)
                continue
            if r.status_code == 429 or r.status_code >= 500:
                RAIL_CALLS.labels("razorpayx", "retry").inc()
                log.warning("razorpayx retry path=%s status=%s attempt=%s", path, r.status_code, attempt)
                ambiguous = ambiguous or r.status_code >= 500
                self._backoff(attempt, r.headers.get("Retry-After"))
                continue
            if r.status_code >= 400:
                error = _error(r)
                RAIL_CALLS.labels("razorpayx", "refused").inc()
                log.warning("razorpayx refused path=%s status=%s code=%s", path, r.status_code, error.code)
                if paying and ambiguous:
                    raise RailUnknownOutcome(path) from error
                raise error
            body: dict[str, Any] = r.json()
            RAIL_CALLS.labels("razorpayx", "ok").inc()
            return body
        raise RailUnavailable(f"{method} {path} failed after {ATTEMPTS} attempts")

    def _backoff(self, attempt: int, retry_after: str | None) -> None:
        if attempt == ATTEMPTS:
            return
        if retry_after is not None and retry_after.isdigit():
            self.sleep(min(float(retry_after), 30.0))
        else:
            self.sleep(self.rng(0.0, min(8.0, 0.5 * 2**attempt)))

    # ---------- accounts ----------

    def register(self, worker_id: uuid.UUID, account_name: str, account_number: str, ifsc: str) -> Registered:
        contact = self._call(
            "POST", "/contacts", {"name": account_name, "type": "vendor", "reference_id": str(worker_id)}
        )
        fund = self._call(
            "POST",
            "/fund_accounts",
            {
                "contact_id": contact["id"],
                "account_type": "bank_account",
                "bank_account": {"name": account_name, "ifsc": ifsc, "account_number": account_number},
            },
        )
        return Registered(contact_id=str(contact["id"]), fund_account_id=str(fund["id"]))

    def start_validation(self, fund_account_id: str, account_name: str, worker_id: uuid.UUID) -> Validation:
        body = self._call(
            "POST",
            "/fund_accounts/validations",
            {
                "account_number": self.account_number,
                "fund_account": {"id": fund_account_id},
                "amount": 100,
                "currency": "INR",
                "notes": {"worker_id": str(worker_id)},
            },
        )
        return validation_of(body)

    def fetch_validation(self, validation_id: str) -> Validation:
        return validation_of(self._call("GET", f"/fund_accounts/validations/{validation_id}"))

    # ---------- payouts ----------

    def create_payout(self, request: PayoutRequest) -> PayoutResult:
        if request.currency != "INR":
            raise RailError("currency_not_supported", f"RazorpayX pays INR only, not {request.currency}")
        body = self._call(
            "POST",
            "/payouts",
            {
                "account_number": self.account_number,
                "fund_account_id": request.fund_account_id,
                "amount": paise(request.amount),
                "currency": "INR",
                "mode": self.mode,
                "purpose": "payout",
                "queue_if_low_balance": True,
                "reference_id": request.reference_id,
                "narration": narration(request.narration),
            },
            idempotency_key=request.idempotency_key,
        )
        return payout_of(body)

    def fetch_payout(self, reference: str) -> PayoutResult:
        return payout_of(self._call("GET", f"/payouts/{reference}"))

    def find_payout(self, reference_id: str) -> PayoutResult | None:
        """The payout of exactly this attempt. RazorpayX lists newest first; only an exact reference counts."""
        body = self._call(
            "GET", "/payouts", params={"account_number": self.account_number, "reference_id": reference_id}
        )
        items = [item for item in body.get("items") or [] if item.get("reference_id") == reference_id]
        return payout_of(items[0]) if items else None


def _error(r: httpx.Response) -> RailError:
    try:
        error = r.json().get("error") or {}
    except ValueError:
        error = {}
    return RailError(
        str(error.get("code") or f"http_{r.status_code}"), str(error.get("description") or ""), r.status_code
    )


def validation_of(body: dict[str, Any]) -> Validation:
    results = body.get("results") or {}
    status = body.get("status")
    if status == "completed":
        if results.get("account_status") == "active":
            return Validation(str(body["id"]), "verified", registered_name=results.get("registered_name"))
        return Validation(str(body["id"]), "failed", reason="invalid_account")
    if status == "failed":
        return Validation(str(body["id"]), "failed", reason="rail_error")
    return Validation(str(body["id"]), "pending")


def payout_of(body: dict[str, Any]) -> PayoutResult:
    raw = str(body.get("status") or "processing")
    details = body.get("status_details") or {}
    reason = details.get("reason") or body.get("failure_reason")
    amount = body.get("amount")
    reference_id = body.get("reference_id")
    return PayoutResult(
        reference=str(body["id"]),
        status=STATUS.get(raw, "processing"),
        utr=body.get("utr") or None,
        reason=str(reason) if reason else None,
        amount=None if amount is None else Decimal(int(amount)) / 100,
        reference_id=str(reference_id) if reference_id else None,
    )
