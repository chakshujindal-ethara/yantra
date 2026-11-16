"""What publish decides a media URL IS, and what it stores when it is wrong.

THE DEFECT, reported from Form Studio: "media URLs still do not work (like
google drive, other urls) but only works for Image Address" - Chrome's *Copy
image address*, i.e. a direct file URL. On the server that report had a second,
worse half than the rendering one, and this file pins it.

`_looks_like_video` tested the extension of the WHOLE url string. A YouTube or
Vimeo link has no extension, so it was filed under `images`. `_fetch_media_b64`
then did a plain `requests.get`, saw `resp.ok` and a body under 100 MB, and
base64'd ~1 MB OF YOUTUBE HTML into the question's `image` field. `warnings`
stayed empty. Nobody was told: the examiner saw a successful publish, and the
candidate got a dead plate on a question that had a clip attached in the
designer.

That is strictly worse than failing. The link-only fallback at `_create_images`
only fires when the fetch FAILS, and it produces a working question with an
external dependency. Storing a web page as image bytes produces a broken
question that reports success.

TWO INDEPENDENT FIXES, both pinned here, because either alone leaves a hole:

  * `_looks_like_video` recognises the embed HOSTS, and reads the extension off
    the PATH so a signed CDN URL (`clip.mp4?sig=...`) is not hidden by its
    query. A YouTube prompt now publishes as `video_prompt` and stores a
    `video_url` - a LINK, never fetched, which is correct for an embed.
  * `_fetch_media_b64` requires the response `Content-Type` to be `image/` or
    `video/`. This catches every host the classifier does not know about,
    including the two shapes that answer 200 with HTML rather than an error: an
    unshared Drive file (a sign-in page) and any share/viewer page.

MIRRORS `mediaKindOf` IN THE CLIENT (`video_plate.dart`) and must keep agreeing
with it, which is why the case list here and in `test/assessment/
media_kind_test.dart` are deliberately the same shapes. A disagreement means a
clip renders in the designer and publishes as a picture.
"""
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.models import studio_form as studio_form_mod
from odoo.addons.assessments_be_v2.tests.test_authored_question_marks import (
    _FormBase,
)


@tagged("post_install", "-at_install")
class TestLooksLikeVideo(TransactionCase):
    """The classifier that decides `videos` vs `images` at publish."""

    def setUp(self):
        super().setUp()
        self.looks = self.env["etp.studio.form"]._looks_like_video

    # -- the shape that stored a web page as a picture ------------------

    def test_a_hosted_player_link_is_a_video(self):
        """No extension anywhere, and previously classified as an image."""
        for url in (
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtube.com/watch?v=dQw4w9WgXcQ",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ",
            "https://www.youtube.com/embed/dQw4w9WgXcQ",
            "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            "https://vimeo.com/123456789",
            "https://player.vimeo.com/video/123456789",
        ):
            self.assertTrue(self.looks(url), "%s must publish as a clip" % url)

    def test_an_embed_host_is_matched_as_a_WHOLE_host(self):
        """A substring check for "youtube.com" would fetch an attacker's host.

        This test decides whether publish tries to DOWNLOAD the URL, so a
        lookalike passing here means `_fetch_media_b64` reaches a host the
        examiner named - which is why the host regex is anchored like every
        other host test in this addon.
        """
        for url in (
            "https://youtube.com.evil.test/watch?v=abc",
            "https://evil.test/?u=https://youtube.com/watch?v=abc",
            "https://notvimeo.com/123456789",
            "https://myyoutube.com/watch?v=abc",
        ):
            self.assertFalse(
                self.looks(url),
                "%s must not be treated as an embed host" % url)

    # -- the signed-CDN shape, a direct file that still failed ----------

    def test_the_extension_is_read_off_the_PATH(self):
        """Every signed CDN URL carries a query, and hid the extension.

        `https://cdn/clip.mp4?sig=abc` is as direct a video file as a URL gets,
        and the old whole-string test called it an image.
        """
        for url in (
            "https://cdn.example.test/clip.mp4",
            "https://cdn.example.test/clip.mp4?sig=abc&expires=123",
            "https://cdn.example.test/clip.webm?v=2",
            "https://cdn.example.test/clip.MOV",
            "https://cdn.example.test/clip.mp4#t=10",
            "/api/v1/forms/media/form_studio/deadbeef.mp4",
        ):
            self.assertTrue(self.looks(url), "%s must publish as a clip" % url)

    # -- the default, which must not move -------------------------------

    def test_a_still_is_still_a_still(self):
        """The image DEFAULT is the contract: our own proxy paths carry no
        extension at all, and they are stills."""
        for url in (
            "https://cdn.example.test/plate.png",
            "https://cdn.example.test/plate.jpg?w=800",
            "/api/v1/forms/media/form_studio/deadbeef.png",
            "/web/content/42",
            "/assessments_be/admin_qimage/42",
            # A Drive direct link has no extension - and is a picture.
            "https://drive.google.com/uc?export=view&id=abc",
        ):
            self.assertFalse(self.looks(url), "%s must publish as a still" % url)

    def test_an_embed_host_with_no_video_still_counts_as_a_clip(self):
        """Matched by HOST, so a YouTube URL that embeds nothing is still a clip.

        This is the SAFE way round and a deliberate difference from the client,
        whose `mediaKindOf` needs a video id to mount a player and falls back to
        drawing a still. Here the only consequence of "video" is that the URL is
        stored as a LINK instead of being downloaded - and downloading a YouTube
        page is exactly the defect. A dead link the examiner can see beats a
        stored web page nobody is told about.
        """
        self.assertTrue(self.looks("https://www.youtube.com/feed/subscriptions"))

    def test_empty_and_nonsense_do_not_raise(self):
        for url in ("", "   ", None, "not a url at all"):
            self.assertFalse(self.looks(url), "%r must not be a clip" % (url,))
        # A bare filename IS its own path, so the extension still wins.
        self.assertTrue(self.looks("clip.mp4"))


@tagged("post_install", "-at_install")
class TestDriveMediaIsNotGuessedFromTheUrl(TransactionCase):
    """A Google Drive link cannot say which medium it is, so it is not asked.

    THE DEFECT THIS PINS, and it reached a candidate. A Drive link has no
    extension and is on no embed host, so `_looks_like_video` said "image" and
    publish fetched the clip's bytes into the question's IMAGE field. The
    candidate got a dead 0:00 player for a video the examiner had attached and
    previewed. Nothing anywhere reported a fault.

    The designer now probes the content type when the link is pasted and records
    it as `media_kind` on the item, which is the ONLY signal that can tell the
    two apart - `drive.google.com/file/d/<id>/view` serves either medium, and
    `lh3.googleusercontent.com` answers `image/jpeg` even for a video (a poster
    thumbnail), so no url test can substitute for it.
    """

    def setUp(self):
        super().setUp()
        Form = self.env["etp.studio.form"]
        self.looks = Form._looks_like_video
        self.decide = Form._item_media_is_video

    # -- the url test, for what it CAN answer ---------------------------

    def test_the_rewritten_video_host_is_a_video(self):
        """The host the designer rewrites a Drive CLIP to.

        It answers `video/mp4` with `accept-ranges: bytes`, which is what lets a
        `<video>` element stream and seek it.
        """
        self.assertTrue(self.looks(
            "https://drive.usercontent.google.com/download"
            "?id=1A9qBxVtHCuE-o-5gi5GiHlwOPCA4ke3g&export=view"))

    def test_the_video_host_is_matched_as_a_WHOLE_host(self):
        """Anchored, like every other host test in this addon."""
        for url in (
            "https://drive.usercontent.google.com.evil.test/download?id=x",
            "https://notdrive.usercontent.google.com/download?id=x",
            "https://evil.test/?u=drive.usercontent.google.com",
        ):
            self.assertFalse(self.looks(url), "%s must not pass" % url)

    def test_the_image_CDN_is_NOT_listed_as_a_video_host(self):
        """`lh3` is an IMAGE host by content type whatever the file is.

        It returns a poster thumbnail for a clip, so listing it here would file
        a still under `videos` - the mirror image of the bug being fixed.
        """
        self.assertFalse(self.looks(
            "https://lh3.googleusercontent.com/d/"
            "1dvYrRhY6NP9c--vg3_PSX4M5jG8E4kji"))

    def test_a_raw_share_link_cannot_be_classified_and_says_so(self):
        """The honest answer for a `/view` link is "not a video by the url"."""
        self.assertFalse(self.looks(
            "https://drive.google.com/file/d/1A9qBx/view?usp=sharing"))

    # -- the item test, which is the one publish uses -------------------

    def test_the_probed_kind_decides_a_raw_share_link(self):
        raw = "https://drive.google.com/file/d/1A9qBx/view?usp=sharing"
        self.assertTrue(self.decide({"media_kind": "video"}, raw))
        self.assertFalse(self.decide({"media_kind": "image"}, raw))

    def test_videoBlock_is_a_declaration_and_outranks_everything(self):
        """Choosing the video block IS the examiner stating the medium."""
        still = ("https://lh3.googleusercontent.com/d/"
                 "1dvYrRhY6NP9c--vg3_PSX4M5jG8E4kji")
        self.assertTrue(self.decide({}, still, "videoBlock"))
        self.assertTrue(
            self.decide({"media_kind": "image"}, still, "videoBlock"))

    def test_imageBlock_is_a_DEFAULT_and_does_not_force_a_still(self):
        """The trap that a first draft of this walked into.

        `imageBlock` is the designer's default media block, so an examiner drops
        a YouTube link into one routinely. Treating the block as a declaration
        made such a link publish as a picture - which is the very defect
        `TestPublishedMediaIsNeverAWebPage` was written to stop.
        """
        yt = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        self.assertTrue(self.decide({}, yt, "imageBlock"))
        self.assertTrue(self.decide({"media_kind": "image"}, yt, "imageBlock"))

    def test_a_url_that_is_plainly_a_clip_beats_a_stale_probe(self):
        """The probe records one host's answer; an embed link it cannot fetch
        at all still outranks it."""
        self.assertTrue(self.decide(
            {"media_kind": "image"}, "https://vimeo.com/123456789"))
        self.assertTrue(self.decide(
            {"media_kind": "image"}, "https://cdn.test/clip.mp4"))

    def test_no_recorded_kind_falls_back_to_the_url(self):
        """Every form authored before `media_kind` existed still publishes."""
        self.assertTrue(self.decide({}, "https://cdn.test/clip.mp4"))
        self.assertTrue(
            self.decide({}, "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        self.assertFalse(self.decide({}, "https://cdn.test/still.png"))

    def test_an_unrecognised_kind_is_ignored_rather_than_trusted(self):
        """A junk value must not decide by accident; the url still answers."""
        # NOT in this list: "IMAGE " or " Video ". The reader strips and
        # lowercases, so those are VALID values, pinned separately below.
        for junk in ("clip", "movie", "still", None, 0, []):
            self.assertTrue(
                self.decide({"media_kind": junk}, "https://cdn.test/a.mp4"),
                "media_kind=%r must fall through to the url" % (junk,))

    def test_the_recorded_kind_is_case_and_space_tolerant(self):
        """Whatever casing or padding the probe's value arrives with.

        Both cases use a url the url-test cannot classify, because a url that
        plainly IS a clip outranks a recorded kind - see
        `test_a_url_that_is_plainly_a_clip_beats_a_stale_probe`.
        """
        no_hint = "https://drive.google.com/file/d/1A9qBxVtHC/view"
        self.assertTrue(self.decide({"media_kind": " Video "}, no_hint))
        self.assertFalse(self.decide({"media_kind": "IMAGE"}, no_hint))
        self.assertFalse(self.decide({"media_kind": "  image  "}, no_hint))

    def test_a_missing_item_does_not_raise(self):
        self.assertFalse(self.decide(None, "https://cdn.test/a.png"))
        self.assertTrue(self.decide(None, "https://cdn.test/a.mp4"))


class TestPublishedMediaIsNeverAWebPage(_FormBase):
    """End to end: a YouTube prompt must publish as a LINK, with no blob.

    This is the regression test for the report. `TestLooksLikeVideo` pins the
    decision; this pins what actually lands in the database, which is the thing
    the candidate sees.
    """

    YT = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    def test_a_youtube_prompt_publishes_as_a_video_url_and_no_image(self):
        def never(*a, **kw):
            raise AssertionError(
                "publish must not fetch an embed link - the old code stored "
                "the watch page as the question's image")

        with patch.object(studio_form_mod.requests, "get", never):
            form, result = self._publish(self._item(
                "promptWriting",
                title="Write the prompt for this clip",
                media_url=self.YT,
                golden_answer="A slow dolly across a rainy street at night.",
            ))
        question = self._published_one(form, result)

        self.assertEqual(
            question.question_type, "video_prompt",
            "a hosted player link is a clip, so the runner must render the "
            "video layout")
        self.assertFalse(
            question.image_ids,
            "no image row may exist - this is where ~1MB of YouTube HTML used "
            "to be stored as the question's picture")
        self.assertEqual(len(question.video_ids), 1)
        self.assertEqual(question.video_ids.video_url, self.YT,
                         "an embed is stored as a link, never fetched")

    def test_an_imageBlock_carrying_a_youtube_link_publishes_as_a_clip_too(self):
        """Same guarantee on the kind an examiner is most likely to use.

        `imageBlock` is the default media kind in the designer, so a pasted
        YouTube link lands here more often than on `promptWriting`.
        """
        def never(*a, **kw):
            raise AssertionError("an embed link must not be fetched")

        with patch.object(studio_form_mod.requests, "get", never):
            form, result = self._publish(self._item(
                "imageBlock",
                title="Watch this and answer",
                media_url=self.YT,
                options=self._opts(("Yes", True), ("No", False)),
            ))
        question = self._published_one(form, result)
        self.assertFalse(question.image_ids)
        self.assertTrue(question.video_ids)
        self.assertEqual(question.video_ids.video_url, self.YT)


class _FakeResponse:
    """Just enough of `requests.Response` for `_fetch_media_b64`."""

    def __init__(self, status_code=200, headers=None, content=b""):
        self.status_code = status_code
        self.headers = headers or {}
        self.content = content

    @property
    def ok(self):
        return self.status_code < 400


@tagged("post_install", "-at_install")
class TestFetchMediaB64RefusesNonMedia(TransactionCase):
    """The content-type gate, which is what stops defect 3 for good.

    The classifier can only know the hosts we listed. This gate needs to know
    nothing: whatever the host is, if the bytes are not an image or a video they
    are not stored, and the examiner is TOLD - which turns a silently broken
    question into a working one with a link and a warning.

    A fake transport is right here for the same reason as in the importer tests:
    the assertion is about our branch on `Content-Type`, and reaching a real
    host would make it a network test.
    """

    def setUp(self):
        super().setUp()
        self.form = self.env["etp.studio.form"].create({
            "client_uid": "form-ctype-probe",
            "title": "Content type probe",
            "structure_json": [],
        })

    def _fetch(self, response, url="https://cdn.example.test/whatever"):
        with patch.object(studio_form_mod.requests, "get",
                          return_value=response), \
                patch.object(studio_form_mod.net_guard, "is_safe_url",
                             return_value=True):
            return self.form._fetch_media_b64(url)

    # -- the shapes that answer 200 with HTML ---------------------------

    def test_an_html_page_is_not_stored_and_the_examiner_is_told(self):
        """A viewer page, a sign-in page, a watch page - all 200, all HTML.

        This is the exact response that used to become a question's image.
        """
        b64, warning = self._fetch(_FakeResponse(
            200, {"Content-Type": "text/html; charset=utf-8"},
            b"<!doctype html><title>Sign in</title>" * 500))

        self.assertFalse(b64, "a web page must never be stored as image bytes")
        self.assertTrue(warning, "the examiner must be told why")
        self.assertIn("not an image or a video", warning)
        self.assertIn("text/html", warning,
                      "naming the type we got is what makes it actionable")

    def test_a_missing_content_type_is_refused(self):
        b64, warning = self._fetch(_FakeResponse(200, {}, b"\x00\x01"))
        self.assertFalse(b64)
        self.assertIn("no content type", warning)

    def test_json_and_plain_text_are_refused(self):
        for ctype in ("application/json", "text/plain",
                      "application/octet-stream", "text/xml"):
            b64, warning = self._fetch(
                _FakeResponse(200, {"Content-Type": ctype}, b"{}"))
            self.assertFalse(b64, "%s must not be stored as media" % ctype)
            self.assertTrue(warning)

    # -- and real media still works -------------------------------------

    def test_a_real_image_IS_stored(self):
        """The gate must not break the case that always worked.

        A hotlinkable direct URL - "Image Address" in the report - is the one
        shape that already worked, and it has to keep working.
        """
        b64, warning = self._fetch(_FakeResponse(
            200, {"Content-Type": "image/png"}, b"\x89PNG\r\n\x1a\n" + b"x" * 64))
        self.assertTrue(b64, "an image/png response must be stored")
        self.assertIsNone(warning)

    def test_a_charset_or_uppercase_content_type_still_passes(self):
        """Hosts send `IMAGE/JPEG` and `image/jpeg; charset=binary`."""
        for ctype in ("IMAGE/JPEG", "image/jpeg; charset=binary",
                      " image/webp ", "video/mp4"):
            b64, warning = self._fetch(
                _FakeResponse(200, {"Content-Type": ctype}, b"x" * 32))
            self.assertTrue(b64, "%r must be accepted" % ctype)
            self.assertIsNone(warning)

    # -- the errors, which must warn rather than raise ------------------

    def test_an_error_status_keeps_the_link(self):
        b64, warning = self._fetch(_FakeResponse(404, {}, b""))
        self.assertFalse(b64)
        self.assertIn("404", warning)
        self.assertIn("keeps a link", warning)

    def test_an_absolute_url_that_resolves_internally_is_never_fetched(self):
        """An examiner's pasted URL reaches this `requests.get`.

        Without the guard a manager could name `169.254.169.254` and have
        publish fetch the instance metadata service - the same SSRF the media
        importer's allow-list exists to prevent, on a route that had none.
        """
        with patch.object(studio_form_mod.net_guard, "is_safe_url",
                          return_value=False), \
                patch.object(studio_form_mod.requests, "get") as get:
            b64, warning = self.form._fetch_media_b64(
                "http://169.254.169.254/latest/meta-data/")

        self.assertFalse(b64)
        self.assertIn("not a public web address", warning)
        get.assert_not_called()

    def test_a_RELATIVE_path_is_not_guarded_because_it_is_ours(self):
        """It joins OUR configured origin, which is `localhost:8069` locally.

        Guarding this would refuse our own media in local development, and the
        examiner does not control the origin it joins - so there is nothing to
        guard against.
        """
        with patch.object(studio_form_mod.requests, "get",
                          return_value=_FakeResponse(
                              200, {"Content-Type": "image/png"}, b"x" * 16)), \
                patch.object(studio_form_mod.net_guard, "is_safe_url",
                             return_value=False) as guard:
            b64, warning = self.form._fetch_media_b64("/some/local/path.png")

        self.assertTrue(b64, "our own origin must still be fetchable")
        self.assertIsNone(warning)
        guard.assert_not_called()

    def test_a_relative_path_is_joined_against_ODOO_not_the_client(self):
        """THE ASSERTION THE FIX NEEDED, and the only one that tells the two
        versions apart.

        This branch used to read `assessments_be_v2.candidate_app_base_url`
        before `web.base.url`. That parameter is the FLUTTER CLIENT's origin,
        and every relative path reaching here is an Odoo route: the two shapes
        the client serves are handled above this branch, off S3 and off the
        attachment store. Joined onto the client host they hit a static bundle
        whose nginx answers `try_files ... /index.html` with 200 text/html, and
        the content-type gate below rejects the media naming a host that never
        served it.

        Latent only because no deployment has ever set that parameter - which is
        exactly the kind of bug that fires the day somebody follows the
        documentation. The test above passes either way, because locally both
        parameters would resolve to the same place; this one sets them apart.
        """
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param("web.base.url", "https://projects.example.test")
        icp.set_param("assessments_be_v2.candidate_app_base_url",
                      "https://assessment.example.test")

        with patch.object(studio_form_mod.requests, "get",
                          return_value=_FakeResponse(
                              200, {"Content-Type": "image/png"},
                              b"x" * 16)) as get:
            self.form._fetch_media_b64("/web/image/1234")

        get.assert_called_once()
        fetched = get.call_args[0][0]
        self.assertTrue(
            fetched.startswith("https://projects.example.test"),
            "a relative Odoo path must be fetched from Odoo; got %r" % fetched)
        self.assertNotIn(
            "assessment.example.test", fetched,
            "the client host serves none of these paths")

    # -- our own store, under any api prefix ----------------------------

    def test_our_own_media_path_is_read_from_STORAGE_not_over_http(self):
        """And under any `/api/vN`, not only v1.

        The client builds this path from `kApiPrefix`, so pinning `/api/v1`
        sent an `/api/v2` bundle's own uploads down the network branch to be
        re-fetched over HTTP - which works by accident when the origin is
        reachable and fails silently when it is not.
        """
        for prefix in ("/api/v1", "/api/v2", "/api/v17"):
            url = "%s/forms/media/form_studio/deadbeef.png" % prefix
            with patch.object(self.env["etp.studio.form"].__class__,
                              "_fetch_s3_object",
                              return_value=b"\x89PNG\r\n\x1a\n") as s3, \
                    patch.object(studio_form_mod.requests, "get") as get:
                b64, warning = self.form._fetch_media_b64(url)

            self.assertTrue(b64, "%s must read from storage" % url)
            self.assertIsNone(warning)
            get.assert_not_called()
            s3.assert_called_once_with("form_studio/deadbeef.png")
