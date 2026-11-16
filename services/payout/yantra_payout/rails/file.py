"""The bank-file rail: no API. Finance downloads a NEFT/IMPS bulk file of the processing lines, uploads it to the
bank, and later uploads the bank's return file (`reference,status,utr,reason`) which settles each line. There is
no penny drop on this rail: an account is registered as given, recorded as `verification=none`."""

import uuid

from yantra_payout.rails import PayoutRequest, PayoutResult, Registered, Validation


class FileRail:
    name = "file"
    supports_penny_drop = False

    def register(self, worker_id: uuid.UUID, account_name: str, account_number: str, ifsc: str) -> Registered:
        return Registered(contact_id=f"file-{worker_id.hex[:12]}", fund_account_id=f"file-{worker_id.hex[:12]}")

    def start_validation(self, fund_account_id: str, account_name: str, worker_id: uuid.UUID) -> Validation:
        return Validation(id=f"none-{fund_account_id}", status="verified")

    def fetch_validation(self, validation_id: str) -> Validation:
        return Validation(id=validation_id, status="verified")

    def create_payout(self, request: PayoutRequest) -> PayoutResult:
        return PayoutResult(
            reference=f"FILE-{request.line_id.hex[:8]}-{request.attempt}",
            status="processing",
            reference_id=request.reference_id,
        )

    def fetch_payout(self, reference: str) -> PayoutResult:
        return PayoutResult(reference=reference, status="processing")  # the bank's return file settles it

    def find_payout(self, reference_id: str) -> PayoutResult | None:
        return None
