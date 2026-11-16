"""Question media answers 304 when the browser already holds it (SNo 135).

WHY IT MATTERS HERE. Media is the largest thing on this wire - a few hundred KB
to a couple of MB per plate - and every candidate in a cohort fetches every
plate on their paper. The proxy already sends `private, max-age=3600`, so within
the hour a browser re-uses its copy for nothing. The hour after that it
re-downloads the whole file, because the response carried no validator for it to
ask "is this still current?" with.

WHAT WAS DELIBERATELY NOT DONE. The row also asked for `Cache-Control: public`.
These routes are ACL-checked - `admin_qimage` gates on an internal user, the
exam routes on the attempt token - and `public` invites a shared proxy to cache
the bytes under the URL alone and serve them to whoever asks next. That is
precisely the guarantee an exam image must not give up, and revalidation
recovers the bandwidth without trading it away. So these tests also pin that the
header stays `private`.

THE VALIDATOR IS `write_date`, not a content hash: it moves whenever the bytes
are replaced, and it costs nothing to read - where hashing would mean holding
the whole object to answer a request that is usually going to be a 304.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers import media_stream


class _Req:
    """Just the piece `_not_modified` reads."""

    def __init__(self, headers=None):
        self.httprequest = type("H", (), {"headers": headers or {}})()

    @staticmethod
    def make_response(body, status=200, headers=None):
        return {"body": body, "status": status,
                "headers": dict(headers or [])}


@tagged("-at_install", "post_install")
class TestMediaRevalidatesInsteadOfRedownloading(TransactionCase):

    def setUp(self):
        super().setUp()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Media cache %s" % uuid4().hex[:6]})
        question = self.env["assessments.be.question"].create({
            "name": "Plate", "question_type": "image_prompt",
            "prompt": "Describe it", "difficulty": "easy",
            "generator_id": generator.id,
        })
        self.image = self.env["assessments.be.question.image"].create({
            "question_id": question.id,
            "slot": "single",
            "label": "Aisle",
            "image_url": "https://cdn.example.com/plates/aisle.png",
        })

    # ── the validator ─────────────────────────────────────────────────

    def test_a_record_yields_an_etag_and_a_last_modified(self):
        etag, last_modified = media_stream._validators(self.image)
        self.assertTrue(etag, "no ETag, so a browser can never revalidate")
        self.assertIn(str(self.image.id), etag,
                      "the ETag must identify the record it belongs to")
        self.assertTrue(last_modified)

    def test_the_etag_moves_when_the_bytes_are_replaced(self):
        """THE WHOLE POINT. A validator that never changes is worse than none:
        it pins a stale picture in every candidate's cache."""
        before, _ = media_stream._validators(self.image)
        self.image.write(
            {"image_url": "https://cdn.example.com/plates/aisle-v2.png"})
        self.image.invalidate_recordset()
        after, _ = media_stream._validators(self.image)
        self.assertNotEqual(
            before, after,
            "replacing the image left the ETag unchanged, so browsers would "
            "keep serving the old plate from cache")

    # ── the 304 ───────────────────────────────────────────────────────

    def test_a_matching_if_none_match_is_answered_304(self):
        etag, _ = media_stream._validators(self.image)
        with patch.object(media_stream, "request",
                          _Req({"If-None-Match": etag})):
            out = media_stream._not_modified(etag, None)
        self.assertIsNotNone(out, "the browser holds this exact version and "
                                  "was made to download it again")
        self.assertEqual(out["status"], 304)
        self.assertEqual(out["body"], "", "a 304 carries no body")

    def test_a_stale_if_none_match_is_not_short_circuited(self):
        etag, _ = media_stream._validators(self.image)
        with patch.object(media_stream, "request",
                          _Req({"If-None-Match": '"something-older"'})):
            self.assertIsNone(media_stream._not_modified(etag, None))

    def test_no_conditional_header_means_serve_the_bytes(self):
        etag, _ = media_stream._validators(self.image)
        with patch.object(media_stream, "request", _Req({})):
            self.assertIsNone(media_stream._not_modified(etag, None))

    # ── what must NOT change ──────────────────────────────────────────

    def test_the_cache_is_private_and_stays_private(self):
        """ACL-checked bytes must never be cacheable by a shared proxy."""
        etag, _ = media_stream._validators(self.image)
        with patch.object(media_stream, "request",
                          _Req({"If-None-Match": etag})):
            out = media_stream._not_modified(etag, None)
        cache = out["headers"].get("Cache-Control", "")
        self.assertIn("private", cache)
        self.assertNotIn(
            "public", cache,
            "a shared proxy could then serve an exam image to somebody who "
            "never authenticated for it")
