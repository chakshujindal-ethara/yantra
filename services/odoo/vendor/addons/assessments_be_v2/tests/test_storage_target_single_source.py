"""Reads and writes must resolve the SAME bucket, and video must not dead-end.

THE DEFECT THIS PINS, diagnosed from a candidate's clip on stage sitting at
0:00 with nothing in any log to say why:

  * uploads resolved the bucket CONNECTOR-FIRST (`s3.connector` record, else
    `assessments_be_v2.s3_*`);
  * `presigned_url` only ever read `assessments_be_v2.s3_bucket`.

When those two name different buckets the bytes really are stored - just not
where playback looks - so S3 answers `NoSuchKey` on a URL whose route, key
extraction and signature are all correct. Verified on stage: the presigned URL
was well-formed and `HeadObject` against the configured bucket 404ed while ten
other Form Studio videos were present.

It could not reproduce locally, and that is the point: with no connector record
both halves fell through to the same module settings and were incapable of
disagreeing. The bug was invisible in every environment that had not configured
a connector.

`s3_service.storage_target` is now the single resolver, so the two halves cannot
diverge whatever a deployment has configured.

SECOND DEFECT, same symptom. `serve_video` returned `not_found()` when it could
not presign and NEVER looked at the on-record Binary field - so a clip whose
bytes were present still played as a dead player. `serve_image` has always
preferred bytes. Video now falls back the same way, after the redirect has been
tried so a large clip still leaves the worker alone in the normal case.
"""
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.services import s3_service


@tagged("post_install", "-at_install")
class TestStorageTargetIsSingleSourced(TransactionCase):

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()

    def _set_module_s3(self, bucket="module-bucket"):
        self.icp.set_param("assessments_be_v2.s3_bucket", bucket)
        self.icp.set_param("assessments_be_v2.s3_access_key_id", "AKIATESTKEY000000000")
        self.icp.set_param("assessments_be_v2.s3_secret_key", "s" * 40)

    # -- resolution ----------------------------------------------------

    def test_module_settings_are_used_when_there_is_no_connector(self):
        """The local shape, and the behaviour that must not change."""
        self._set_module_s3("module-bucket")
        with patch.object(s3_service, "_connector", return_value=None), \
             patch.object(s3_service, "_client", return_value="MODULE_CLIENT"):
            cli, bucket = s3_service.storage_target(self.env)
        self.assertEqual(bucket, "module-bucket")
        self.assertEqual(cli, "MODULE_CLIENT")

    def test_the_connector_wins_when_one_exists(self):
        """Matching the precedence uploads have always used."""
        self._set_module_s3("module-bucket")

        class _Conn:
            name = "connector-bucket"

            def _get_s3_client(self):
                return "CONNECTOR_CLIENT"

        with patch.object(s3_service, "_connector", return_value=_Conn()):
            cli, bucket = s3_service.storage_target(self.env)
        self.assertEqual(
            bucket, "connector-bucket",
            "the connector is the team's canonical bucket and uploads have "
            "always preferred it; reads must agree")
        self.assertEqual(cli, "CONNECTOR_CLIENT")

    def test_nothing_configured_is_reported_as_nothing(self):
        for key in ("assessments_be_v2.s3_bucket",
                    "assessments_be_v2.s3_access_key_id",
                    "assessments_be_v2.s3_secret_key"):
            self.icp.set_param(key, "")
        with patch.object(s3_service, "_connector", return_value=None):
            cli, bucket = s3_service.storage_target(self.env)
        self.assertIsNone(cli)
        self.assertFalse(bucket)

    def test_a_connector_alone_counts_as_configured(self):
        """A connector-only deployment has working storage.

        `is_configured` used to read the module keys only, so such a deployment
        was told S3 was "not configured" while uploads were succeeding through
        the connector.
        """
        for key in ("assessments_be_v2.s3_bucket",
                    "assessments_be_v2.s3_access_key_id",
                    "assessments_be_v2.s3_secret_key"):
            self.icp.set_param(key, "")

        class _Conn:
            name = "connector-bucket"

            def _get_s3_client(self):
                return "CONNECTOR_CLIENT"

        with patch.object(s3_service, "_connector", return_value=_Conn()):
            self.assertTrue(s3_service.is_configured(self.env))

    # -- url matching --------------------------------------------------

    def test_a_url_naming_either_bucket_is_recognised(self):
        """A stored URL may name whichever bucket was configured when it was
        written; losing recognition would make present media read as external
        and stop it being presigned."""
        self._set_module_s3("module-bucket")

        class _Conn:
            name = "connector-bucket"

            def _get_s3_client(self):
                return "C"

        with patch.object(s3_service, "_connector", return_value=_Conn()):
            for host_bucket in ("connector-bucket", "module-bucket"):
                url = f"https://{host_bucket}.s3.amazonaws.com/etp/x.mp4"
                self.assertEqual(
                    s3_service.object_key_from_url(self.env, url), "etp/x.mp4",
                    "%s must be recognised as ours" % host_bucket)

    def test_a_third_party_url_is_still_external(self):
        self._set_module_s3("module-bucket")
        with patch.object(s3_service, "_connector", return_value=None):
            self.assertIsNone(s3_service.object_key_from_url(
                self.env, "https://someone-else.s3.amazonaws.com/x.mp4"))
