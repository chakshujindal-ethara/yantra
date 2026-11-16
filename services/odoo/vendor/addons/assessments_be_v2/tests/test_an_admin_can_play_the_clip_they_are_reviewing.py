"""The bank preview must hand the browser a clip it can actually load.

THE DEFECT, found in a walkthrough on 2026-09-09. A reviewer opening a video
question from the Selected Questions list, or from a generator's bank, saw

    No video yet for this question.

on questions that had one - and the same clips played perfectly for the
candidate sitting the exam.

WHY THE TWO DIFFER. The exam runner puts the URL on a plain `<video src>`: an
ordinary subresource fetch that carries no credential and follows redirects
without asking anyone's permission. The ADMIN plate cannot do that, because the
bank proxy is `auth="user"` - so it fetches with an `Authorization` header, and
an XHR that follows a CROSS-ORIGIN redirect needs CORS headers FROM THE
REDIRECT TARGET. `media_stream.serve_video` answers with a 302 for anything that
has a URL at all ("an mp4 is never proxied through the worker"), so the browser
was handed a redirect to an examiner's CDN, got no CORS headers back, and
discarded a perfectly good clip.

`media_stream.py` documents this exact trap for IMAGES and defaults their
redirect OFF because of it. Videos take the redirect unconditionally, so they
had no such protection.

THE FIX is not to proxy the bytes - that would hold a worker for a clip, which
is the reason the redirect exists. It is to hand over the URL the redirect would
have sent the browser to, so no redirect and no credential are involved.

WHAT THESE TESTS PIN. That every storage shape yields something a `<video>` can
load, and specifically that a plain external file URL is NOT sent through the
proxy - which is the case that broke.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import serializers as S


@tagged("-at_install", "post_install")
class TestAnAdminCanPlayTheClipTheyAreReviewing(TransactionCase):

    def setUp(self):
        super().setUp()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Clip review %s" % uuid4().hex[:6]})
        self.question = self.env["assessments.be.question"].create({
            "name": "Watch the clip",
            "question_type": "video_prompt",
            "prompt": "Watch the clip, then answer.",
            "difficulty": "easy",
            "generator_id": generator.id,
        })

    def _video(self, url=None):
        return self.env["assessments.be.question.video"].create({
            "question_id": self.question.id,
            "slot": "single",
            "label": "Clip",
            "video_url": url or False,
        })

    # ── the case that broke ───────────────────────────────────────────

    def test_a_plain_external_file_url_is_handed_over_directly(self):
        """THE HEADLINE. A direct .mp4 on somebody else's host.

        The proxy could only ever 302 to this same URL, so routing through it
        bought nothing and cost the preview: the admin plate's bearer fetch
        cannot follow that redirect.
        """
        video = self._video("https://cdn.example.com/clips/lockout.mp4")
        self.assertEqual(
            S.admin_video_url(video),
            "https://cdn.example.com/clips/lockout.mp4",
            "an external clip is still routed through the auth-gated proxy, so "
            "the admin plate fetches it with a bearer, gets a cross-origin "
            "redirect, and shows the empty state over a working clip")

    def test_a_query_string_does_not_send_it_back_to_the_proxy(self):
        """The signed-CDN shape - `?sig=...` - is still somebody else's URL."""
        url = "https://cdn.example.com/clips/lockout.mp4?sig=abc123&x=1"
        self.assertEqual(S.admin_video_url(self._video(url)), url)

    def test_a_public_video_page_is_handed_over_as_before(self):
        """YouTube and Vimeo already worked; they must keep working."""
        for url in ("https://www.youtube.com/watch?v=moS5SjJFkt4",
                    "https://vimeo.com/76979871"):
            self.assertEqual(S.admin_video_url(self._video(url)), url)

    # ── the shapes that must still use the proxy ──────────────────────

    def test_bytes_on_the_record_still_go_through_the_proxy(self):
        """No URL means the clip IS the record.

        The proxy streams those bytes and never redirects, so the bearer fetch
        works - this is the one case the proxy is right for.
        """
        video = self._video(None)
        self.assertEqual(
            S.admin_video_url(video),
            "/assessments_be/admin_qvideo/%s" % video.id)

    def test_the_list_row_keeps_its_cache_buster_on_the_proxy_path(self):
        """A replaced clip must not be served from cache.

        Only meaningful on the proxy path: a presigned URL carries its own
        signature, and an external link is not ours to version.
        """
        video = self._video(None)
        busted = S.admin_video_url(video, bust=True)
        self.assertTrue(busted.startswith(
            "/assessments_be/admin_qvideo/%s" % video.id))
        self.assertIn("?v=", busted)

    def test_the_cache_buster_is_never_bolted_onto_someone_elses_url(self):
        video = self._video("https://cdn.example.com/clips/lockout.mp4")
        self.assertNotIn("?v=", S.admin_video_url(video, bust=True))

    # ── the payload, not just the helper ──────────────────────────────

    def test_the_bank_payload_carries_a_playable_url(self):
        """A helper nobody serves fixes nothing."""
        self._video("https://cdn.example.com/clips/lockout.mp4")
        row = S.bank_question_row(self.question)
        videos = row.get("videos") or []
        self.assertTrue(videos, "the bank row carries no video at all")
        self.assertEqual(
            videos[0].get("admin_url"),
            "https://cdn.example.com/clips/lockout.mp4")
