# -*- coding: utf-8 -*-
"""Form Studio media goes from the browser straight to S3, and back through
the proxy, without a base64 body crossing Odoo.

`/forms/media/presign` mints a policy for a fresh `form_studio/<uuid4>/`
prefix at the bucket ROOT (`under_folder=False`): the proxy route and
`object_key_from_url` only recognise `form_studio/...` there, so a key under
the module folder would upload fine and never be served. `/forms/media/
complete` then looks at what actually landed (`head_object`) and deletes
anything of a type the allow-list does not name. The base64 route and the
proxy are pinned in `test_form_studio_takes_audio_by_upload_and_by_link`.

boto3 is stubbed: these pin our own branches, not S3.
"""
import re
from unittest.mock import MagicMock, patch

from botocore.exceptions import ClientError

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import forms as forms_api
from odoo.addons.assessments_be_v2.services import s3_service
from odoo.addons.assessments_be_v2.tests._paging_harness import (
    call_route, status_of,
)

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"
_URL = "https://module-bucket.s3.ap-south-1.amazonaws.com/"
_PREFIX = re.compile(r"^form_studio/[0-9a-f]{32}/$")
_KEY = "form_studio/%s/interview.mp3" % ("c" * 32)


@tagged("post_install", "-at_install")
class TestFormStudioUploadsStraightToS3(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param("assessments_be_v2.s3_bucket", "module-bucket")
        icp.set_param("assessments_be_v2.s3_region", "ap-south-1")
        icp.set_param("assessments_be_v2.s3_access_key_id", "AKIATESTKEY000000000")
        icp.set_param("assessments_be_v2.s3_secret_key", "s" * 40)
        icp.set_param("assessments_be_v2.s3_folder", "etp_assessment")
        self.api = forms_api.EtpStudioFormsApi()
        self.cli = MagicMock()
        self.cli.generate_presigned_post.return_value = {
            "url": _URL, "fields": {"key": "k", "policy": "p"}}
        for target, value in (("_connector", None), ("_client", self.cli)):
            patcher = patch.object(s3_service, target, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def _call(self, method, **params):
        return call_route(forms_api, self.api, method, self.env, **params)

    def _refused(self, out, status, code):
        self.assertEqual(status_of(out), status, out)
        self.assertEqual(out["error"]["code"], code, out)

    # -- presign -------------------------------------------------------

    def test_presign_refuses_a_bad_type_and_an_oversize(self):
        for bad in ("application/x-msdownload", "text/html", "", "image/svg+xml"):
            self._refused(self._call("form_media_presign", name="a.exe",
                                     content_type=bad, size=10),
                          400, "unsupported_type")
        self._refused(self._call("form_media_presign", name="big.mp4",
                                 content_type="video/mp4",
                                 size=100 * 1024 * 1024 + 1),
                      413, "too_large")
        self._refused(self._call("form_media_presign", name="a.mp3",
                                 content_type="audio/mpeg"),
                      400, "bad_request")
        self.cli.generate_presigned_post.assert_not_called()

    def test_the_policy_prefix_is_form_studio_uuid_with_no_module_folder(self):
        out = self._call("form_media_presign", name="My interview (final).MP3",
                         content_type="audio/mpeg; charset=binary", size=2048)
        self.assertEqual(status_of(out), 200, out)
        kwargs = self.cli.generate_presigned_post.call_args.kwargs
        prefix = kwargs["Conditions"][0][2]
        self.assertRegex(prefix, _PREFIX)
        self.assertNotIn("etp_assessment", prefix)
        self.assertEqual(kwargs["Key"], prefix + "${filename}")
        self.assertEqual(kwargs["Conditions"][1], ["content-length-range", 0, 2048])
        self.assertEqual(kwargs["Fields"], {"Content-Type": "audio/mpeg"})

        data = out["data"]
        self.assertEqual(data["key"], prefix + "My_interview_final.mp3")
        self.assertEqual(data["upload"]["prefix"], prefix)
        self.assertEqual(data["upload"]["url"], _URL)
        self.assertEqual(data["upload"]["fields"]["key"], data["key"],
                         "posting the fields verbatim must land on `key`")
        self.assertEqual(data["upload"]["fields"]["policy"], "p")
        self.assertTrue(data["upload"]["expires_at"])

    def test_the_key_extension_follows_the_type_not_the_filename(self):
        out = self._call("form_media_presign", name="clip",
                         content_type="video/quicktime", size=10)
        self.assertTrue(out["data"]["key"].endswith("/clip.mov"), out)
        out = self._call("form_media_presign", name="../../.env",
                         content_type="image/png", size=10)
        self.assertRegex(out["data"]["key"], r"^form_studio/[0-9a-f]{32}/media\.png$")

    def test_the_default_still_leads_with_the_module_folder(self):
        """Task 7's proctoring calls pass no keyword and must not move."""
        out = s3_service.presigned_post(
            self.env, "evidence/42", "image/jpeg", 1024, 900)
        self.assertEqual(out["prefix"], "etp_assessment/evidence/42/")

    # -- complete ------------------------------------------------------

    def _head(self, content_type, length=2048):
        self.cli.head_object.return_value = {
            "ContentType": content_type, "ContentLength": length}

    def test_complete_verifies_with_head_object_and_returns_the_proxy_url(self):
        self._head("audio/mpeg")
        out = self._call("form_media_complete", key=_KEY)
        self.assertEqual(status_of(out), 200, out)
        self.assertEqual(out["data"], {"url": "/api/v1/forms/media/" + _KEY,
                                       "storage": "s3", "public": True})
        self.cli.head_object.assert_called_once_with(
            Bucket="module-bucket", Key=_KEY)
        self.cli.delete_object.assert_not_called()

    def test_complete_refuses_a_key_outside_form_studio(self):
        for key in ("etp_assessment/form_studio/%s/a.mp3" % ("c" * 32),
                    "form_studio/../secrets/a.mp3",
                    "form_studio/%s/../a.mp3" % ("c" * 32),
                    "form_studio/%s.png" % ("c" * 32),
                    ""):
            self._refused(self._call("form_media_complete", key=key),
                          400, "bad_key")
        self.cli.head_object.assert_not_called()
        self.cli.delete_object.assert_not_called()

    def test_complete_deletes_an_object_whose_type_is_not_allowed(self):
        self._head("text/html")
        self._refused(self._call("form_media_complete", key=_KEY),
                      400, "unsupported_type")
        self.cli.delete_object.assert_called_once_with(
            Bucket="module-bucket", Key=_KEY)

    def test_complete_deletes_an_oversize_object(self):
        self._head("video/mp4", length=100 * 1024 * 1024 + 1)
        self._refused(self._call("form_media_complete", key=_KEY),
                      413, "too_large")
        self.cli.delete_object.assert_called_once()

    def test_complete_answers_404_when_nothing_was_uploaded(self):
        self.cli.head_object.side_effect = ClientError(
            {"Error": {"Code": "404", "Message": "Not Found"}}, "HeadObject")
        self._refused(self._call("form_media_complete", key=_KEY),
                      404, "not_found")
        self.cli.delete_object.assert_not_called()
