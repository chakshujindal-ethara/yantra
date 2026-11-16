"""The shared PII helpers: a keyed digest, a name comparison, the identifier patterns."""

import hashlib
import hmac
import re

from yantra_common.config import LOCAL_PII_KEY
from yantra_common.pii import ACCOUNT_NUMBER, IFSC, PAN, normalise_name, pii_hash


def test_the_digest_is_keyed_and_the_name_is_compared_folded():
    assert pii_hash("ABCDE1234F") == hmac.new(LOCAL_PII_KEY.encode(), b"ABCDE1234F", hashlib.sha256).hexdigest()
    assert normalise_name("  Asha   RANI ") == "asha rani"


def test_the_identifier_patterns():
    assert re.fullmatch(PAN, "ABCDE1234F") and not re.fullmatch(PAN, "ABCD1234F")
    assert re.fullmatch(IFSC, "HDFC0001234") and not re.fullmatch(IFSC, "HDFC1001234")
    assert re.fullmatch(ACCOUNT_NUMBER, "123456789") and not re.fullmatch(ACCOUNT_NUMBER, "12345678")
