"""Personal data helpers every module shares: the keyed digest under `YANTRA_PII_KEY`, the name comparison, and
the patterns of the Indian identifiers the platform accepts (PAN, IFSC, bank account number)."""

import hashlib
import hmac

from yantra_common.config import pii_settings

PAN = r"^[A-Z]{5}[0-9]{4}[A-Z]$"
IFSC = r"^[A-Z]{4}0[A-Z0-9]{6}$"
ACCOUNT_NUMBER = r"^[0-9]{9,18}$"


def pii_hash(value: str) -> str:
    """HMAC-SHA256 under `YANTRA_PII_KEY`: a digest stored beside the last four digits is reversible by brute
    force when unkeyed (a PAN has ten characters); keyed, it still detects reuse and nothing else."""
    return hmac.new(pii_settings().pii_key.encode(), value.encode(), hashlib.sha256).hexdigest()


def normalise_name(name: str) -> str:
    """Whitespace collapsed, case folded: the comparison the bank step and the eligibility hash share."""
    return " ".join(name.split()).casefold()
