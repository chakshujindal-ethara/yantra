"""A deterministic rail for tests: no network, every outcome decided by the input.

- account number ending 0000: the penny drop finds no such account (`invalid_account`)
- account number ending 1111: the bank's registered name is someone else's (`name_mismatch`)
- payout amount whose paise are 13: the rail fails it (`insufficient_funds`); paise 99: the bank returns it
  (`beneficiary_account_closed`); anything else is paid on the first fetch."""

import uuid
from decimal import Decimal

from yantra_payout.rails import PayoutRequest, PayoutResult, PayoutStatus, Registered, Validation

OTHER_NAME = "SOMEONE ELSE"


def outcome(amount: Decimal) -> tuple[PayoutStatus, str | None]:
    paise = int((amount * 100) % 100)
    if paise == 13:
        return "failed", "insufficient_funds"
    if paise == 99:
        return "returned", "beneficiary_account_closed"
    return "paid", None


class FakeRail:
    name = "fake"
    supports_penny_drop = True

    def __init__(self) -> None:
        self.accounts: dict[str, tuple[str, str]] = {}  # fund account id -> (account number, name)
        self.payouts: dict[str, PayoutRequest] = {}  # reference -> request
        self.calls: list[str] = []

    def register(self, worker_id: uuid.UUID, account_name: str, account_number: str, ifsc: str) -> Registered:
        self.calls.append("register")
        fund = f"fa_fake_{worker_id.hex[:12]}_{account_number[-4:]}"
        self.accounts[fund] = (account_number, account_name)
        return Registered(contact_id=f"cont_fake_{worker_id.hex[:12]}", fund_account_id=fund)

    def start_validation(self, fund_account_id: str, account_name: str, worker_id: uuid.UUID) -> Validation:
        self.calls.append("start_validation")
        return Validation(id=f"fav_{fund_account_id}", status="pending")

    def fetch_validation(self, validation_id: str) -> Validation:
        self.calls.append("fetch_validation")
        number, name = self.accounts[validation_id.removeprefix("fav_")]
        if number.endswith("0000"):
            return Validation(id=validation_id, status="failed", reason="invalid_account")
        registered = OTHER_NAME if number.endswith("1111") else name.upper()
        return Validation(id=validation_id, status="verified", registered_name=registered)

    def create_payout(self, request: PayoutRequest) -> PayoutResult:
        self.calls.append("create_payout")
        reference = f"pout_fake_{request.line_id.hex[:12]}_{request.attempt}"
        self.payouts[reference] = request
        return PayoutResult(
            reference=reference, status="processing", amount=request.amount, reference_id=request.reference_id
        )

    def fetch_payout(self, reference: str) -> PayoutResult:
        self.calls.append("fetch_payout")
        request = self.payouts[reference]
        status, reason = outcome(request.amount)
        utr = f"UTR{request.line_id.hex[:12].upper()}" if status == "paid" else None
        return PayoutResult(
            reference, status, utr=utr, reason=reason, amount=request.amount, reference_id=request.reference_id
        )

    def find_payout(self, reference_id: str) -> PayoutResult | None:
        self.calls.append("find_payout")
        mine = [ref for ref, req in self.payouts.items() if req.reference_id == reference_id]
        return self.fetch_payout(mine[0]) if mine else None
