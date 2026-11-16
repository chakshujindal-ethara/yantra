"""Form Studio media must be PRESIGNABLE, or every clip streams through Odoo.

THE DEFECT THIS PINS. `media_stream.serve_video` exists to make sure an mp4
never goes through the worker: it presigns the object and 302s to S3. It can
only do that when `s3_service.object_key_from_url` hands it a key.

Form Studio stores its media as this app's own RELATIVE proxy path -
`/api/v1/forms/media/form_studio/<uuid>.<ext>` - because the bucket is private.
A relative path has no netloc, so it fell past every host check in that
function and returned None. The consequence, for EVERY Form Studio video
whether uploaded or imported from a link:

  * the clip was proxied whole through the Odoo worker, which reads the object
    into memory (`obj["Body"].read(...)`);
  * that proxy answers no `Accept-Ranges`, so `<video>` could not seek - a
    candidate could not skip back to re-watch a detail;
  * a cohort all loading the same clip put that memory and bandwidth on the
    worker instead of on S3.

Measured before the fix: `Range: bytes=0-1023` against the proxy answered
`HTTP 200` with the full `Content-Length`, no `Content-Range`.

WHAT THE SECOND GROUP IS FOR. The matcher must claim ONLY our own stored
shape. If it accepted any URL containing that path segment, an external link
would be turned into a presigned URL for our bucket - pointing at a key that
is not there, so a working external image would start 404ing.
"""
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.services import s3_service

_KEY = "form_studio/b92dccc62c4943cbaca93c594087da08.jpg"
_PROXY = "/api/v1/forms/media/" + _KEY


@tagged("post_install", "-at_install")
class TestFormMediaObjectKey(TransactionCase):

    def _key(self, url):
        return s3_service.object_key_from_url(self.env, url)

    # -- our own proxy path resolves to the object key ------------------

    def test_the_stored_proxy_path_yields_the_s3_key(self):
        self.assertEqual(
            self._key(_PROXY), _KEY,
            "serve_video presigns only when this returns a key; None is what "
            "sent every Form Studio clip through the worker")

    def test_video_and_other_extensions_too(self):
        for ext in ("mp4", "webm", "mov", "png", "webp"):
            url = "/api/v1/forms/media/form_studio/abc123.%s" % ext
            self.assertEqual(self._key(url), "form_studio/abc123.%s" % ext)

    def test_a_query_or_fragment_is_not_part_of_the_key(self):
        # An S3 key containing "?v=2" is a different object, and a miss here
        # would 404 a file that is present.
        self.assertEqual(self._key(_PROXY + "?v=2"), _KEY)
        self.assertEqual(self._key(_PROXY + "#top"), _KEY)

    def test_traversal_is_refused(self):
        """Same guard the proxy route itself applies before reading."""
        self.assertIsNone(
            self._key("/api/v1/forms/media/form_studio/../../etc/passwd"))

    # -- and claims nothing else ---------------------------------------

    def test_an_external_url_carrying_the_same_path_is_not_claimed(self):
        """Anchored on a RELATIVE url, so this cannot be hijacked.

        Claiming it would presign a key in OUR bucket for someone else's file,
        turning a working external image into a 404.
        """
        self.assertIsNone(self._key(
            "https://evil.test/api/v1/forms/media/form_studio/abc.jpg"))
        self.assertIsNone(self._key(
            "https://cdn.example.com/forms/media/form_studio/abc.jpg"))

    def test_an_ordinary_external_url_is_still_external(self):
        for url in ("https://cdn.example.com/plate.png",
                    "https://drive.google.com/uc?export=view&id=abc",
                    "https://youtu.be/dQw4w9WgXcQ"):
            self.assertIsNone(self._key(url), "%s must stay external" % url)

    def test_media_outside_the_form_studio_prefix_is_not_claimed(self):
        # Only Form Studio's own prefix is served by that route, and its own
        # guard refuses anything else - so a key must not be invented here.
        self.assertIsNone(self._key("/api/v1/forms/media/other/abc.jpg"))

    def test_empty_and_none(self):
        self.assertIsNone(self._key(None))
        self.assertIsNone(self._key(""))
