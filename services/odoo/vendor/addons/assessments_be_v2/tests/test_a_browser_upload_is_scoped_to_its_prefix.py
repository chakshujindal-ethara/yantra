"""A browser upload policy may write only inside its own prefix.

`s3_service.presigned_post` hands a BROWSER a short-lived S3 POST policy so
evidence and Form Studio media go straight to the bucket instead of through a
base64 body. The policy is the only thing standing between a leaked form and
"write anything anywhere", so the tests pin each limit it must carry: the key
template, the two conditions that bound key and size, the exact Content-Type,
the folder prefix, and the client config that keeps S3 from answering 400
before CORS (which the browser reports as an opaque CORS failure).

The boto3 client is stubbed except in the last test, which signs a real policy
offline (no network, fake credentials) to prove the config produces the URL and
policy shape a browser can actually use.
"""
import base64
import json
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.services import s3_service

_URL = "https://module-bucket.s3.ap-south-1.amazonaws.com/"


@tagged("post_install", "-at_install")
class TestABrowserUploadIsScopedToItsPrefix(TransactionCase):

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()
        self.icp.set_param("assessments_be_v2.s3_bucket", "module-bucket")
        self.icp.set_param("assessments_be_v2.s3_region", "ap-south-1")
        self.icp.set_param("assessments_be_v2.s3_access_key_id", "AKIATESTKEY000000000")
        self.icp.set_param("assessments_be_v2.s3_secret_key", "s" * 40)
        self.icp.set_param("assessments_be_v2.s3_folder", "etp_assessment")
        # No client survives from another test, so the config under test is
        # the config that built the client in front of us.
        cache = patch.dict(s3_service._S3_CLIENT_CACHE, clear=True)
        cache.start()
        self.addCleanup(cache.stop)

    def _stub_client(self):
        cli = MagicMock()
        cli.generate_presigned_post.return_value = {
            "url": _URL, "fields": {"key": "k", "policy": "p"}}
        return cli

    def _mint(self, cli, key_prefix="evidence/42", content_type="image/jpeg",
              max_bytes=400 * 1024, expires_in=900):
        with patch.object(s3_service, "_connector", return_value=None), \
             patch.object(s3_service, "_client", return_value=cli):
            return s3_service.presigned_post(
                self.env, key_prefix, content_type, max_bytes, expires_in)

    # -- the policy ----------------------------------------------------

    def test_the_policy_pins_key_size_and_type(self):
        cli = self._stub_client()
        out = self._mint(cli)
        kwargs = cli.generate_presigned_post.call_args.kwargs
        self.assertEqual(kwargs["Bucket"], "module-bucket")
        self.assertEqual(kwargs["Key"], "etp_assessment/evidence/42/${filename}")
        self.assertEqual(kwargs["Fields"], {"Content-Type": "image/jpeg"})
        self.assertEqual(kwargs["ExpiresIn"], 900)
        self.assertEqual(kwargs["Conditions"], [
            ["starts-with", "$key", "etp_assessment/evidence/42/"],
            ["content-length-range", 0, 400 * 1024],
            {"Content-Type": "image/jpeg"},
        ])
        self.assertEqual(out["url"], _URL)
        self.assertEqual(out["fields"], {"key": "k", "policy": "p"})
        self.assertEqual(out["prefix"], "etp_assessment/evidence/42/")

    def test_a_prefix_is_normalised_to_end_with_one_slash(self):
        for given in ("evidence/42", "evidence/42/", "/evidence/42/"):
            cli = self._stub_client()
            out = self._mint(cli, key_prefix=given)
            self.assertEqual(out["prefix"], "etp_assessment/evidence/42/", given)
            self.assertEqual(
                cli.generate_presigned_post.call_args.kwargs["Key"],
                "etp_assessment/evidence/42/${filename}", given)

    def test_the_configured_folder_leads_every_prefix(self):
        self.icp.set_param("assessments_be_v2.s3_folder", "/stage_folder/")
        out = self._mint(self._stub_client(), key_prefix="form_studio")
        self.assertEqual(out["prefix"], "stage_folder/form_studio/")

    def test_a_blank_folder_falls_back_like_every_other_key(self):
        self.icp.set_param("assessments_be_v2.s3_folder", "")
        out = self._mint(self._stub_client(), key_prefix="form_studio")
        self.assertEqual(out["prefix"], "etp_assessment/form_studio/")

    def test_a_blank_prefix_is_refused_not_widened_to_the_folder(self):
        for given in ("", "/", None):
            with self.assertRaises(ValueError, msg=repr(given)):
                self._mint(self._stub_client(), key_prefix=given)

    def test_expiry_is_reported_in_utc(self):
        before = datetime.now(timezone.utc).replace(microsecond=0)
        out = self._mint(self._stub_client(), expires_in=900)
        at = datetime.fromisoformat(out["expires_at"])
        self.assertEqual(at.utcoffset(), timedelta(0))
        self.assertGreaterEqual(at, before + timedelta(seconds=900))
        self.assertLessEqual(at, before + timedelta(seconds=905))

    # -- no storage ----------------------------------------------------

    def test_nothing_configured_is_none_and_signs_nothing(self):
        for key in ("assessments_be_v2.s3_bucket",
                    "assessments_be_v2.s3_access_key_id",
                    "assessments_be_v2.s3_secret_key"):
            self.icp.set_param(key, "")
        with patch.object(s3_service, "_connector", return_value=None), \
             patch("boto3.client") as boto_client, \
             self.assertLogs(s3_service._logger, "WARNING"):
            out = s3_service.presigned_post(
                self.env, "evidence/42", "image/jpeg", 1024, 900)
        self.assertIsNone(out)
        boto_client.assert_not_called()

    # -- client config -------------------------------------------------

    def test_the_module_client_signs_v4_with_virtual_addressing(self):
        with patch("boto3.client") as boto_client:
            s3_service._client(self.env)
        kwargs = boto_client.call_args.kwargs
        self.assertEqual(kwargs["region_name"], "ap-south-1")
        cfg = kwargs["config"]
        self.assertEqual(cfg.signature_version, "s3v4")
        self.assertEqual(cfg.s3, {"addressing_style": "virtual"})
        self.assertEqual(cfg.retries, {"max_attempts": 3, "mode": "standard"},
                         "the retry config must survive")

    def test_the_connector_path_gets_the_same_config_without_touching_it(self):
        """The connector's own `_get_s3_client` sets neither s3v4 nor virtual
        addressing and is another team's code, so presigning must not use it."""
        connectors_own = self._stub_client()

        class _Conn:
            name = "connector-bucket"
            region_name = "ap-south-1"
            aws_access_key_id = "AKIACONNECTOR0000000"
            aws_secret_access_key = "c" * 40

            def _get_s3_client(self):
                return connectors_own

        with patch.object(s3_service, "_connector", return_value=_Conn()), \
             patch("boto3.client") as boto_client:
            boto_client.return_value = self._stub_client()
            out = s3_service.presigned_post(
                self.env, "evidence/42", "image/jpeg", 1024, 900)
        kwargs = boto_client.call_args.kwargs
        self.assertEqual(kwargs["aws_access_key_id"], "AKIACONNECTOR0000000")
        self.assertEqual(kwargs["region_name"], "ap-south-1")
        self.assertEqual(kwargs["config"].signature_version, "s3v4")
        self.assertEqual(kwargs["config"].s3, {"addressing_style": "virtual"})
        self.assertEqual(
            boto_client.return_value.generate_presigned_post.call_args
            .kwargs["Bucket"], "connector-bucket",
            "the connector's bucket wins, matching storage_target")
        self.assertEqual(out["prefix"], "etp_assessment/evidence/42/")
        connectors_own.generate_presigned_post.assert_not_called()

    # -- the real signer -----------------------------------------------

    def test_a_real_signed_policy_is_virtual_hosted_and_carries_the_limits(self):
        with patch.object(s3_service, "_connector", return_value=None):
            out = s3_service.presigned_post(
                self.env, "spikes/presign-test", "image/jpeg", 400 * 1024, 900)
        self.assertEqual(out["url"], _URL,
                         "path-style would be https://s3.ap-south-1.amazonaws.com/<bucket>")
        self.assertEqual(out["fields"]["x-amz-algorithm"], "AWS4-HMAC-SHA256")
        self.assertEqual(out["fields"]["Content-Type"], "image/jpeg")
        self.assertEqual(out["fields"]["key"],
                         "etp_assessment/spikes/presign-test/${filename}")
        self.assertIn("/ap-south-1/s3/aws4_request",
                      out["fields"]["x-amz-credential"])
        policy = json.loads(base64.b64decode(out["fields"]["policy"]))
        self.assertIn(["starts-with", "$key", "etp_assessment/spikes/presign-test/"],
                      policy["conditions"])
        self.assertIn(["content-length-range", 0, 400 * 1024], policy["conditions"])
        self.assertIn({"Content-Type": "image/jpeg"}, policy["conditions"])
        self.assertIn({"bucket": "module-bucket"}, policy["conditions"])
