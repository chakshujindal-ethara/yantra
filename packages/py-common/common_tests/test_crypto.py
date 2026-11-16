"""Sealing: round trip, a row's associated data, tampering, rotation, and malformed keys refused at load."""

import base64

import pytest
from pydantic import ValidationError

from yantra_common.config import LOCAL_BANK_KEY, BankKeySettings, bank_key_settings, parse_key
from yantra_common.crypto import SealError, key_id_of, open_sealed, seal

KEY_A = "a1:" + base64.b64encode(b"A" * 32).decode()
KEY_B = "b2:" + base64.b64encode(b"B" * 32).decode()


def test_a_sealed_value_opens_only_with_its_row():
    s = BankKeySettings(bank_key=KEY_A)
    blob = seal(b"123456789012", b"worker-1", s)
    assert b"123456789012" not in blob and key_id_of(blob) == "a1"
    assert open_sealed(blob, b"worker-1", s) == b"123456789012"
    with pytest.raises(SealError, match="does not open"):
        open_sealed(blob, b"worker-2", s)
    tampered = blob[:-1] + bytes([blob[-1] ^ 1])
    with pytest.raises(SealError):
        open_sealed(tampered, b"worker-1", s)


def test_a_rotation_keeps_old_values_open_and_seals_new_ones_under_the_new_key():
    old = seal(b"acct", b"w", BankKeySettings(bank_key=KEY_A))
    rotated = BankKeySettings(bank_key=KEY_B, bank_key_previous=KEY_A)
    assert open_sealed(old, b"w", rotated) == b"acct"
    assert key_id_of(seal(b"acct", b"w", rotated)) == "b2"
    with pytest.raises(SealError, match="no key with id a1"):
        open_sealed(old, b"w", BankKeySettings(bank_key=KEY_B))
    with pytest.raises(SealError, match="not a sealed value"):
        key_id_of(b"no-separator")


def test_the_default_settings_seal_with_the_local_key(monkeypatch):
    monkeypatch.delenv("YANTRA_BANK_KEY", raising=False)
    bank_key_settings.cache_clear()
    try:
        assert bank_key_settings().bank_key == LOCAL_BANK_KEY
        assert open_sealed(seal(b"x", b"r"), b"r") == b"x"
    finally:
        bank_key_settings.cache_clear()


@pytest.mark.parametrize(
    ("value", "message"),
    [
        ("nokey", "a key is"),
        (":" + base64.b64encode(b"A" * 32).decode(), "a key is"),
        ("x" * 17 + ":" + base64.b64encode(b"A" * 32).decode(), "a key is"),
        ("k:not base64!", "not valid base64"),
        ("k:" + base64.b64encode(b"A" * 31).decode(), "32 bytes"),
    ],
)
def test_a_malformed_key_is_refused(value, message):
    with pytest.raises(ValueError, match=message):
        parse_key(value)
    with pytest.raises(ValidationError):
        BankKeySettings(bank_key=value)
