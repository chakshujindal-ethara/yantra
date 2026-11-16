# -*- coding: utf-8 -*-
"""Form Studio takes an audio file by Upload and by a Jumpshare link, and
plays clips from S3 itself.

The Flutter app uploads straight to S3 (`/forms/media/presign`, pinned in
`test_form_studio_uploads_straight_to_s3`); the base64 route stays for the
back-office editor. A Jumpshare share page is HTML; the importer reads the
file's own `cdn.jumpshare.com/preview/...` link out of it and fetches that,
every hop still re-checked against the redirect allow-list. The proxy answers
a clip with a 302 to a signed S3 URL, so its bytes never pass through Odoo.
"""
import base64
import io
from unittest.mock import MagicMock, patch

from odoo.http import Response
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import forms as forms_api
from odoo.addons.assessments_be_v2.services import s3_service
from odoo.addons.assessments_be_v2.tests._paging_harness import (
    call_route, status_of,
)

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"
_KEY = "form_studio/%s/interview.mp3" % ("c" * 32)
_SHARE = "https://jumpshare.com/s/IOi4385ylQYXJhakspaA"
_POSTER = "https://cdn.jumpshare.com/preview/Poster_tok-1.jpg"
_CLIP = "https://cdn.jumpshare.com/preview/Clip_tok-2.mp3"


def _resp(content_type, *chunks):
    resp = MagicMock(headers={"Content-Type": content_type})
    resp.iter_content.return_value = list(chunks)
    return resp


@tagged("post_install", "-at_install")
class TestFormStudioTakesAudioByUploadAndByLink(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.api = forms_api.EtpStudioFormsApi()
        self.cli = MagicMock()
        patcher = patch.object(s3_service, "storage_target",
                               return_value=(self.cli, "module-bucket"))
        patcher.start()
        self.addCleanup(patcher.stop)

    def _call(self, method, **params):
        return call_route(forms_api, self.api, method, self.env, **params)

    # -- Upload ------------------------------------------------------------

    def test_an_uploaded_mp3_lands_in_s3_with_its_type(self):
        out = self._call("form_media_upload", name="take.mp3",
                         content_type="audio/mpeg",
                         data=base64.b64encode(b"ID3data").decode())
        self.assertEqual(status_of(out), 200, out)
        put = self.cli.put_object.call_args.kwargs
        self.assertEqual(put["ContentType"], "audio/mpeg")
        self.assertTrue(put["Key"].startswith("form_studio/"), put["Key"])
        self.assertEqual(out["data"]["url"], "/api/v1/forms/media/" + put["Key"])

    def test_a_browser_alias_or_no_type_is_read_off_the_extension(self):
        for sent in ("audio/x-m4a", "", "application/octet-stream"):
            out = self._call("form_media_upload", name="take.m4a",
                             content_type=sent,
                             data=base64.b64encode(b"ftyp").decode())
            self.assertEqual(status_of(out), 200, (sent, out))
            self.assertEqual(
                self.cli.put_object.call_args.kwargs["ContentType"],
                "audio/mp4", sent)

    def test_the_upload_refuses_an_executable(self):
        out = self._call("form_media_upload", name="setup.exe",
                         content_type="application/x-msdownload",
                         data=base64.b64encode(b"MZ\x90\x00").decode())
        self.assertEqual(status_of(out), 400, out)
        self.assertEqual(out["error"]["code"], "unsupported_type")
        self.cli.put_object.assert_not_called()

    def _serve(self, key):
        fake = MagicMock(env=self.env)
        fake.make_response.side_effect = lambda body, headers: Response(
            body, headers=headers)
        fake.redirect.side_effect = lambda url, code, local: Response(
            status=code, headers={"Location": url})
        with patch.object(forms_api, "request", fake):
            return forms_api.EtpStudioMediaProxy().form_media_serve(key)

    def test_a_clip_plays_from_s3_not_through_odoo(self):
        signed = "https://module-bucket.s3.amazonaws.com/%s?X-Amz-Signature=s" % _KEY
        with patch.object(s3_service, "presigned_url",
                          return_value=signed) as sign:
            resp = self._serve(_KEY)
        self.assertEqual(resp.status_code, 302)
        self.assertEqual(resp.headers["Location"], signed)
        self.assertEqual(resp.headers["Cache-Control"], "no-store",
                         "a signed URL expires; the redirect must not be cached")
        self.assertEqual(sign.call_args.args[1], _KEY)
        self.cli.get_object.assert_not_called()

    def test_an_image_still_streams_with_its_type(self):
        self.cli.get_object.return_value = {"Body": io.BytesIO(b"\x89PNG")}
        resp = self._serve("form_studio/%s/pic.png" % ("d" * 32))
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.headers["Content-Type"], "image/png")

    # -- Jumpshare link ----------------------------------------------------

    def test_a_jumpshare_link_imports_the_clip_not_its_poster(self):
        page = ('<img src="%s"><script>var f="%s";</script>'
                % (_POSTER, _CLIP)).encode()
        fetched = []

        def fetch(_self, url):
            fetched.append(url)
            if url == _SHARE:
                return _resp("text/html; charset=UTF-8", page), None
            return _resp("audio/mpeg", b"ID3", b"\x00" * 64), None

        with patch.object(forms_api.EtpStudioFormsApi, "_fetch_share_link",
                          fetch):
            out = self._call("form_media_import", url=_SHARE)
        self.assertEqual(status_of(out), 200, out)
        self.assertEqual(fetched, [_SHARE, _CLIP])
        put = self.cli.put_object.call_args.kwargs
        self.assertEqual(put["ContentType"], "audio/mpeg")
        self.assertTrue(put["Key"].endswith(".mp3"), put["Key"])

    def test_a_jumpshare_page_with_no_file_is_refused_in_words(self):
        with patch.object(forms_api.EtpStudioFormsApi, "_fetch_share_link",
                          return_value=(_resp("text/html", b"<p>gone</p>"),
                                        None)):
            out = self._call("form_media_import", url=_SHARE)
        self.assertEqual(status_of(out), 422, out)
        self.assertIn("Jumpshare", out["error"]["message"])
        self.cli.put_object.assert_not_called()

    def test_only_jumpshare_and_its_one_cloudfront_host_are_allowed(self):
        self.assertTrue(forms_api._import_fetch_url(_SHARE))
        self.assertIsNone(forms_api._import_fetch_url(
            "https://jumpshare.com.evil.test/s/abc"))
        allowed = forms_api._redirect_host_allowed
        self.assertTrue(allowed(_CLIP))
        self.assertTrue(allowed("https://d1p1y5pyxk2k6i.cloudfront.net/f.mp3"))
        self.assertFalse(allowed("https://attacker.cloudfront.net/f.mp3"))
