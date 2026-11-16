# -*- coding: utf-8 -*-
"""M-8: encryption-at-rest for the high-value secrets the module stores in
``ir.config_parameter`` - the S3 secret access key, the Vertex service-account
JSON (which contains a private key), and the two Vertex bearer credentials
(``vertex_api_key``, ``vertex_access_token``). See ``SECRET_PARAM_KEYS`` below,
which is the authoritative list.

Design
------
* A single choke point: ``encrypt`` on write, ``decrypt`` on read. The settings
  page and the two readers (``services/s3_service`` creds, ``services/vertex``
  bearer minting) route their secret access through here.
* Key material is derived from Odoo's own ``database.secret`` (the per-database
  master secret already used to sign sessions), via PBKDF2-HMAC-SHA256 into a
  Fernet key. No new key to manage; a DB dump alone (without the master secret)
  cannot decrypt the values.
* Ciphertext is tagged with a version marker ``enc:v1:``. ``decrypt`` returns any
  value WITHOUT that marker unchanged, so a legacy plaintext secret keeps working
  and is transparently re-encrypted the next time settings are saved (no forced
  migration, no downtime).
* Fail-safe: if ``cryptography`` is somehow unavailable or the key cannot be
  derived, the value is stored/returned as plaintext with a loud log rather than
  breaking S3/Vertex - availability is not sacrificed for the hardening.
"""
import base64
import hashlib
import logging

_logger = logging.getLogger(__name__)

_ENC_PREFIX = "enc:v1:"
_KDF_SALT = b"assessments_be_v2.secret_store.v1"

# Derived ciphers, keyed by the master secret they came from.
#
# WHY THIS CACHE EXISTS, measured rather than guessed. The KDF below is
# deliberately expensive - 100,000 PBKDF2 rounds, ~11.5 ms - which is correct for
# key derivation and wrong to pay per request. `s3_service` reads a secret about
# five times to serve ONE media object, so an uncached derive put ~57 ms of pure
# single-threaded CPU in front of every image, before any S3 I/O. That is the
# arithmetic behind a 908 ms mean on a route whose whole job is to hand back a
# picture it has already got, and at 1,000 candidates x 35 questions it is hours
# of worker time spent hashing the same string.
#
# Keyed on the master secret, NOT on the database name: rotating
# `database.secret` must produce a new cipher rather than silently keep using the
# old one, and two databases in one process cannot collide because a different
# secret is a different key. Same shape as `_S3_CLIENT_CACHE` in `s3_service`.
#
# Unbounded is fine here - the cardinality is "number of distinct master secrets
# this process has seen", which is 1 in production and a handful in a test run.
_FERNET_CACHE = {}


def _fernet(env):
    """Build the Fernet cipher from Odoo's database.secret. Returns None if the
    crypto stack or the master secret is unavailable (callers fall back to
    plaintext with a warning).

    Cached per master secret - see _FERNET_CACHE. The derivation is pure, so the
    cipher for a given secret is always the same object and reusing it cannot
    change any result."""
    try:
        from cryptography.fernet import Fernet
    except Exception:  # noqa: BLE001
        return None
    master = (env["ir.config_parameter"].sudo().get_param("database.secret")
              or "").strip()
    if not master:
        return None
    cached = _FERNET_CACHE.get(master)
    if cached is not None:
        return cached
    key = hashlib.pbkdf2_hmac("sha256", master.encode("utf-8"), _KDF_SALT,
                              100_000, dklen=32)
    cipher = Fernet(base64.urlsafe_b64encode(key))
    _FERNET_CACHE[master] = cipher
    return cipher


def is_encrypted(value):
    return isinstance(value, str) and value.startswith(_ENC_PREFIX)


def encrypt(env, plaintext):
    """Encrypt a secret for storage. Empty/blank passes through unchanged (so an
    empty setting stays empty, not an encrypted blob)."""
    if not plaintext:
        return plaintext or ""
    if is_encrypted(plaintext):
        return plaintext
    f = _fernet(env)
    if f is None:
        _logger.warning(
            "etp_assessment secret_store: no cipher available; storing secret "
            "as PLAINTEXT. Set a database.secret and re-save settings.")
        return plaintext
    token = f.encrypt(plaintext.encode("utf-8")).decode("ascii")
    return _ENC_PREFIX + token


def decrypt(env, stored):
    """Decrypt a stored secret. A value without the enc marker is legacy plaintext
    and returned as-is. A marked value that fails to decrypt returns '' with a
    loud log (never leaks ciphertext to a caller expecting a real secret)."""
    if not stored or not is_encrypted(stored):
        return stored or ""
    f = _fernet(env)
    if f is None:
        _logger.error(
            "etp_assessment secret_store: encrypted secret present but no cipher "
            "available to decrypt it (missing database.secret or cryptography).")
        return ""
    try:
        token = stored[len(_ENC_PREFIX):].encode("ascii")
        return f.decrypt(token).decode("utf-8")
    except Exception:  # noqa: BLE001
        _logger.error(
            "etp_assessment secret_store: failed to decrypt a stored secret "
            "(wrong database.secret, or corrupted value).")
        return ""


# The ir.config_parameter keys whose values are secret and must be encrypted.
#
# THIS TUPLE IS THE DEFINITION, and every path that touches a secret derives
# from it: `res_config_settings.get_values` decrypts these for the form,
# `set_values` re-encrypts them after super() has written plaintext, and the
# readers below go through `get_secret`. Adding a key here is therefore the
# whole change - but a reader that still calls `get_param` directly will be
# handed ciphertext, which is exactly how the two Vertex credentials came to be
# encrypted on write by /api/v1/settings/update and never decrypted on read.
SECRET_PARAM_KEYS = (
    "assessments_be_v2.s3_secret_key",
    "assessments_be_v2.vertex_service_account_json",
    "assessments_be_v2.vertex_api_key",
    "assessments_be_v2.vertex_access_token",
)


def get_secret(env, key, default=""):
    """Read + decrypt a secret config parameter."""
    raw = env["ir.config_parameter"].sudo().get_param(key, default)
    return decrypt(env, raw)


def set_secret(env, key, plaintext):
    """Encrypt + write a secret config parameter."""
    env["ir.config_parameter"].sudo().set_param(key, encrypt(env, plaintext))
