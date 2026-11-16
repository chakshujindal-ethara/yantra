"""Sealing a secret at rest (a bank account number): AES-256-GCM under `YANTRA_BANK_KEY`, with the key's id in front
of every sealed value so a rotation can keep opening old values under `YANTRA_BANK_KEY_PREVIOUS`.

    blob = key_id (utf-8) || 0x00 || nonce (12 bytes) || ciphertext and tag

The associated data binds a blob to its row (the worker id): a ciphertext moved to another row does not open."""

import os

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from yantra_common.config import BankKeySettings, bank_key_settings, parse_key

NONCE = 12


class SealError(ValueError):
    """A blob that does not open: unknown key id, tampered bytes, or associated data from another row."""


def _keys(settings: BankKeySettings) -> dict[str, bytes]:
    keys = dict([parse_key(settings.bank_key)])
    if settings.bank_key_previous:
        key_id, raw = parse_key(settings.bank_key_previous)
        keys.setdefault(key_id, raw)
    return keys


def seal(plaintext: bytes, aad: bytes, settings: BankKeySettings | None = None) -> bytes:
    s = settings or bank_key_settings()
    key_id, key = parse_key(s.bank_key)
    nonce = os.urandom(NONCE)
    return key_id.encode() + b"\x00" + nonce + AESGCM(key).encrypt(nonce, plaintext, aad)


def key_id_of(blob: bytes) -> str:
    key_id, sep, _ = blob.partition(b"\x00")
    if not sep:
        raise SealError("not a sealed value")
    return key_id.decode()


def open_sealed(blob: bytes, aad: bytes, settings: BankKeySettings | None = None) -> bytes:
    key_id = key_id_of(blob)
    key = _keys(settings or bank_key_settings()).get(key_id)
    if key is None:
        raise SealError(f"no key with id {key_id}")
    body = blob[len(key_id.encode()) + 1 :]
    try:
        return AESGCM(key).decrypt(body[:NONCE], body[NONCE:], aad)
    except InvalidTag as e:
        raise SealError("the sealed value does not open with this key and row") from e
