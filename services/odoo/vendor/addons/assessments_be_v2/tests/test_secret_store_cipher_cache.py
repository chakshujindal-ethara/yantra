"""Deriving the Fernet key is expensive, so it happens ONCE per master secret.

THE MEASUREMENT. `_fernet` runs PBKDF2-HMAC-SHA256 at 100,000 rounds, which
takes ~11.5 ms and is exactly what a KDF is supposed to cost. The defect was
paying it per call: `services/s3_service` reads a stored secret about five times
to serve ONE media object, so an uncached derive put ~58 ms of pure
single-threaded CPU in front of every image before any S3 byte moved. Measured
on this machine, 5 uncached derives = 57.9 ms; cached = 0.002 ms.

At a 1,000-candidate cohort - 35 questions, ~1.17 images each, ~41,000 media
requests - that is roughly 40 MINUTES of worker CPU spent hashing the same
string, on the path that showed a 908 ms mean for handing back a picture it had
already fetched.

WHAT THESE TESTS PROTECT, in order of what would actually break:

1. Correctness first. A cached cipher must decrypt what an uncached one wrote,
   or the cache would silently strand every stored secret.
2. Rotation must still work. Keying the cache on the database name instead of
   the secret would keep serving the OLD cipher after `database.secret` changed
   - the failure mode is "rotation appeared to work and did nothing".
3. The derive must actually be skipped. Proven by counting PBKDF2 calls, not by
   timing, because a timing assertion on a shared CI box is a flake generator.
"""
import base64
import hashlib

from odoo.tests.common import TransactionCase
from odoo.tools import mute_logger

from ..services import secret_store


class TestSecretStoreCipherCache(TransactionCase):

    def setUp(self):
        super().setUp()
        # A cipher cached by an earlier test in the same process would make
        # every assertion here pass for the wrong reason.
        secret_store._FERNET_CACHE.clear()
        self.addCleanup(secret_store._FERNET_CACHE.clear)
        self.ICP = self.env["ir.config_parameter"].sudo()
        self.ICP.set_param("database.secret", "test-master-secret-aaaa")

    def test_round_trip_still_works(self):
        """The whole point of the cipher, unchanged by caching."""
        token = secret_store.encrypt(self.env, "hunter2")
        self.assertTrue(secret_store.is_encrypted(token))
        self.assertEqual(secret_store.decrypt(self.env, token), "hunter2")

    def test_a_cached_cipher_decrypts_what_an_uncached_one_encrypted(self):
        """The cache must not fork the key.

        Encrypt with a cold cache, clear it, then decrypt with a freshly derived
        one. If the derivation were not pure - or the cache keyed wrongly - this
        is where a stored secret becomes unreadable.
        """
        token = secret_store.encrypt(self.env, "s3-secret-key-value")
        secret_store._FERNET_CACHE.clear()
        self.assertEqual(
            secret_store.decrypt(self.env, token), "s3-secret-key-value")

    def test_the_kdf_runs_once_across_many_calls(self):
        """THE FIX ITSELF. Counted, not timed.

        Ten encrypt/decrypt calls - roughly two media requests' worth of secret
        reads - must derive the key exactly once.
        """
        calls = []
        real = hashlib.pbkdf2_hmac

        def counting(*args, **kwargs):
            calls.append(args[:2])
            return real(*args, **kwargs)

        self.patch(hashlib, "pbkdf2_hmac", counting)
        for _ in range(5):
            token = secret_store.encrypt(self.env, "value")
            secret_store.decrypt(self.env, token)

        self.assertEqual(
            len(calls), 1,
            "the KDF ran %d times; uncached this is one per call and ~11.5 ms "
            "each" % len(calls))

    def test_negative_control_without_the_cache_the_kdf_runs_every_time(self):
        """Proves the test above is measuring the cache and not a coincidence.

        Reproduces the pre-fix `_fernet` verbatim - no cache lookup - and shows
        the same ten calls derive ten times. Without this, a broken cache and a
        working one would produce the same green tick.
        """
        calls = []
        real = hashlib.pbkdf2_hmac

        def counting(*args, **kwargs):
            calls.append(args[:2])
            return real(*args, **kwargs)

        self.patch(hashlib, "pbkdf2_hmac", counting)

        def uncached_fernet(env):
            from cryptography.fernet import Fernet
            master = (env["ir.config_parameter"].sudo()
                      .get_param("database.secret") or "").strip()
            if not master:
                return None
            key = hashlib.pbkdf2_hmac(
                "sha256", master.encode("utf-8"), secret_store._KDF_SALT,
                100_000, dklen=32)
            return Fernet(base64.urlsafe_b64encode(key))

        self.patch(secret_store, "_fernet", uncached_fernet)
        for _ in range(5):
            token = secret_store.encrypt(self.env, "value")
            secret_store.decrypt(self.env, token)

        self.assertEqual(len(calls), 10, "pre-fix behaviour: one derive per call")

    @mute_logger("odoo.addons.assessments_be_v2.services.secret_store")
    def test_rotating_database_secret_derives_a_new_cipher(self):
        """Keyed on the SECRET, not the database.

        Keyed on the database name, a rotated `database.secret` would keep using
        the retired cipher - rotation would look successful and change nothing.
        A value written under the old secret must also stop being readable,
        which is what rotation MEANS.
        """
        old_token = secret_store.encrypt(self.env, "written-under-old-secret")

        self.ICP.set_param("database.secret", "test-master-secret-bbbb")
        new_token = secret_store.encrypt(self.env, "written-under-new-secret")

        self.assertEqual(
            secret_store.decrypt(self.env, new_token),
            "written-under-new-secret")
        self.assertEqual(len(secret_store._FERNET_CACHE), 2,
                         "each distinct master secret gets its own cipher")
        # The old ciphertext is no longer readable, and fails CLOSED (empty
        # string, loud log) rather than leaking ciphertext to a caller that
        # asked for a secret.
        self.assertEqual(secret_store.decrypt(self.env, old_token), "")

    def test_no_master_secret_means_no_cipher_and_no_cache_entry(self):
        """The documented fail-safe: plaintext with a warning, never a crash.

        Also asserts the cache is not populated with a None, which would make
        the next call skip the derive and stay broken after the secret was set.
        """
        self.ICP.set_param("database.secret", "")
        self.assertIsNone(secret_store._fernet(self.env))
        self.assertEqual(secret_store.encrypt(self.env, "plain"), "plain")
        self.assertEqual(secret_store._FERNET_CACHE, {})
