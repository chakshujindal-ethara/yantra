"""Yantra patch 0002: an S3-compatible store (MinIO) at an endpoint.

The server reaches the store at an internal address (`s3_endpoint_url`, e.g. `http://minio:9000`) while a browser
reaches it at a public one (`s3_public_endpoint_url`, e.g. `http://localhost:9000`). A presigned URL's signature
covers the host, so every URL handed to a browser (presigned GET, presigned POST, proctoring evidence) must be signed
for the public address, and every server call (put, list, head) must go to the internal one. Path addressing, because
MinIO has no virtual-host bucket names. Without an endpoint the behaviour is AWS's, unchanged.
"""
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.services import s3_service


@tagged("post_install", "-at_install")
class TestS3Endpoint(TransactionCase):

    def setUp(self):
        super().setUp()
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param("assessments_be_v2.s3_bucket", "yantra-assess")
        icp.set_param("assessments_be_v2.s3_access_key_id", "yantra")
        icp.set_param("assessments_be_v2.s3_secret_key", "yantra-local-secret")
        icp.set_param("assessments_be_v2.s3_region", "us-east-1")
        icp.set_param("assessments_be_v2.s3_folder", "assess")
        self.icp = icp
        s3_service._S3_CLIENT_CACHE.clear()

    def test_without_an_endpoint_the_client_is_aws_virtual_host(self):
        cli = s3_service._client(self.env)
        self.assertEqual(cli.meta.config.s3["addressing_style"], "virtual")
        self.assertIn("amazonaws.com", cli.meta.endpoint_url)
        self.assertIs(s3_service.presign_client(self.env), s3_service.storage_target(self.env)[0])

    def test_an_endpoint_switches_the_server_client_to_path_addressing(self):
        self.icp.set_param("assessments_be_v2.s3_endpoint_url", "http://minio:9000")
        cli, bucket = s3_service.storage_target(self.env)
        self.assertEqual(cli.meta.endpoint_url, "http://minio:9000")
        self.assertEqual(cli.meta.config.s3["addressing_style"], "path")
        self.assertEqual(bucket, "yantra-assess")

    def test_browser_urls_are_signed_for_the_public_endpoint(self):
        self.icp.set_param("assessments_be_v2.s3_endpoint_url", "http://minio:9000")
        self.icp.set_param("assessments_be_v2.s3_public_endpoint_url", "http://localhost:9000")
        url = s3_service.presigned_url(self.env, "assess/x/clip.mp4")
        self.assertTrue(url.startswith("http://localhost:9000/yantra-assess/assess/x/clip.mp4?"), url)
        post = s3_service.presigned_post(self.env, "evidence/42", "image/jpeg", 400000, 600)
        self.assertEqual(post["url"], "http://localhost:9000/yantra-assess")
        self.assertEqual(post["prefix"], "assess/evidence/42/")
        self.assertEqual(post["fields"]["Content-Type"], "image/jpeg")
        # the server client still talks to the internal address
        self.assertEqual(s3_service.storage_target(self.env)[0].meta.endpoint_url, "http://minio:9000")

    def test_a_cdn_url_on_the_public_bucket_maps_back_to_its_key(self):
        """The rig sets `s3_cdn_url` to the public bucket URL, so stored URLs are recognised as ours."""
        self.icp.set_param("assessments_be_v2.s3_cdn_url", "http://localhost:9000/yantra-assess")
        url, key = s3_service._build_url(self.env, "yantra-assess", "us-east-1", "assess/a.png"), "assess/a.png"
        self.assertEqual(url, "http://localhost:9000/yantra-assess/assess/a.png")
        self.assertEqual(s3_service.object_key_from_url(self.env, url), key)
