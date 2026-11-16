# -*- coding: utf-8 -*-
"""An audio file is Form Studio media exactly like a clip.

It rides the `videoBlock` (label "Video"), publishes onto
`question.video` as a link (never fetched into an image field), is told apart
there by the stored `media_kind`, and reaches the candidate with `kind:
"audio"` on its `videos[]` entry so the exam can play it in an audio player.
Rows that existed before `media_kind` read "video": the column is stored and
computed, so the upgrade that adds it computes every existing row.
"""
from unittest.mock import MagicMock, patch
from uuid import uuid4

from odoo.tests.common import tagged

from odoo.addons.assessments_be_v2.constants import (
    AUDIO_MIME_BY_EXT, FORM_ITEM_KIND_LABELS,
)
from odoo.addons.assessments_be_v2.controllers.api import forms as forms_api
from odoo.addons.assessments_be_v2.controllers.api import serializers
from odoo.addons.assessments_be_v2.models import studio_form as studio_form_mod
from odoo.addons.assessments_be_v2.services import s3_service
from odoo.addons.assessments_be_v2.tests._paging_harness import (
    call_route, status_of,
)
from odoo.addons.assessments_be_v2.tests.test_authored_question_marks import (
    _FormBase,
)

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"
_AUDIO = {"mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4",
          "ogg": "audio/ogg", "aac": "audio/aac", "flac": "audio/flac"}
_MP3 = "/api/v1/forms/media/form_studio/%s/interview.mp3" % ("a" * 32)


def _never(*a, **kw):
    raise AssertionError("publish must store an audio url as a link, "
                         "never fetch it as image bytes")


@tagged("post_install", "-at_install")
class TestAnAudioClipIsMediaLikeAVideo(_FormBase):

    def setUp(self):
        super().setUp()
        self.Video = self.env["assessments.be.question.video"]
        self.looks_audio = self.Form._looks_like_audio
        self.host = self.Question.create({
            "name": "Host %s" % uuid4().hex[:6], "question_type": "mcq",
            "prompt": "Listen"})

    def _row(self, **vals):
        return self.Video.create(dict(vals, question_id=self.host.id))

    # -- the kind, by extension ----------------------------------------

    def test_each_audio_extension_is_audio_everywhere_it_is_read(self):
        self.assertEqual(AUDIO_MIME_BY_EXT, _AUDIO)
        self.assertEqual(FORM_ITEM_KIND_LABELS["videoBlock"],
                         "Video")
        for ext, mime in _AUDIO.items():
            url = "/api/v1/forms/media/form_studio/%s/a.%s" % ("b" * 32, ext)
            self.assertTrue(self.looks_audio(url), ext)
            self.assertTrue(
                self.looks_audio("https://cdn.test/a.%s?sig=x" % ext.upper()),
                "%s behind a query, upper case" % ext)
            self.assertFalse(self.Form._looks_like_video(url),
                             "%s must not read as a video file" % ext)
            self.assertEqual(self._row(video_url=url).media_kind, "audio", ext)
            self.assertEqual(
                self._row(video_filename="take.%s" % ext).media_kind, "audio",
                "%s by filename when there is no url" % ext)
            self.assertEqual(forms_api.MEDIA_MIME[ext], mime)
            self.assertIn(mime, forms_api.UPLOAD_TYPES)

    def test_a_clip_or_a_link_is_still_video(self):
        for url in ("https://cdn.test/clip.mp4", "https://cdn.test/c.webm",
                    "/api/v1/forms/media/form_studio/x.mov",
                    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                    "https://cdn.test/mp3/clip.mp4"):
            self.assertFalse(self.looks_audio(url), url)
            self.assertEqual(self._row(video_url=url).media_kind, "video", url)
        for empty in ("", "   ", None):
            self.assertFalse(self.looks_audio(empty))

    def test_a_draft_over_an_audio_clip_says_audio(self):
        """The draft's Medium reads "Audio" when its bank question's clip is
        audio, "Video" for a clip."""
        self.host.question_type = "video_prompt"
        draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": self.env["assessments.be.prompt"].create(
                {"name": "Medium %s" % uuid4().hex[:6]}).id,
            "name": "Listen", "question_type": "video_prompt",
            "approved_question_id": self.host.id})
        clip = self._row(video_url="https://cdn.test/interview.mp3")
        self.assertEqual(draft.medium_display, "Audio")
        clip.video_url = "https://cdn.test/clip.mp4"
        self.assertEqual(draft.medium_display, "Video")

    def test_a_row_that_predates_media_kind_reads_video(self):
        """A binary-only row (no url, no filename) defaults to video, and the
        upgrade left no row of this table without a kind."""
        self.assertEqual(self._row().media_kind, "video")
        self.env.flush_all()
        self.env.cr.execute(
            "SELECT count(*) FROM assessments_be_question_video "
            "WHERE media_kind IS NULL")
        self.assertEqual(self.env.cr.fetchone()[0], 0)

    # -- publish -------------------------------------------------------

    def test_an_mp3_in_a_videoBlock_publishes_onto_question_video(self):
        with patch.object(studio_form_mod.requests, "get", _never):
            form, result = self._publish(self._item(
                "videoBlock", title="What did the caller ask for",
                media_url=_MP3,
                options=self._opts(("A refund", True), ("A callback", False))))
        question = self._published_one(form, result)
        self.assertFalse(question.image_ids)
        self.assertEqual(len(question.video_ids), 1)
        self.assertEqual(question.video_ids.video_url, _MP3)
        self.assertEqual(question.video_ids.media_kind, "audio")

    def test_an_mp3_in_the_default_imageBlock_is_not_fetched_as_a_picture(self):
        """`imageBlock` is the designer's default media block, and a stale
        "image" probe must not turn an audio url into image bytes."""
        with patch.object(studio_form_mod.requests, "get", _never):
            form, result = self._publish(self._item(
                "imageBlock", title="Listen and answer", media_url=_MP3,
                media_kind="image",
                options=self._opts(("Yes", True), ("No", False))))
        question = self._published_one(form, result)
        self.assertFalse(question.image_ids)
        self.assertEqual(question.video_ids.media_kind, "audio")

    def test_a_probed_audio_kind_puts_an_unclassifiable_link_on_video(self):
        drive = "https://drive.google.com/file/d/1A9qBxVtHC/view"
        self.assertTrue(self.Form._item_media_is_video(
            {"media_kind": "audio"}, drive, "imageBlock"))

    # -- the candidate payload -----------------------------------------

    def test_the_candidate_payload_names_the_kind(self):
        with patch.object(studio_form_mod.requests, "get", _never):
            form, result = self._publish(self._item(
                "videoBlock", media_url=_MP3,
                options=self._opts(("Yes", True), ("No", False))))
        question = self._published_one(form, result)
        self.Video.create({"question_id": question.id, "sequence": 99,
                           "video_url": "https://cdn.test/clip.mp4"})
        _images, videos = serializers.question_media(question, "tok")
        self.assertEqual([v["kind"] for v in videos], ["audio", "video"])
        self.assertEqual(
            videos[0]["url"],
            "/assessments_be/exam/qvideo/tok/%s" % question.video_ids[0].id,
            "audio streams through the same qvideo route as a clip")

    def test_the_admin_payloads_name_the_kind_too(self):
        """The bank list row and the bank detail each carry `kind`, so a
        reviewer's preview plays audio in an audio player, not a blank video
        box."""
        self._row(video_url=_MP3, sequence=1)
        self._row(video_url="https://cdn.test/clip.mp4", sequence=2)
        for serialize in (serializers.bank_question_row,
                          serializers.bank_question_detail):
            videos = serialize(self.host)["videos"]
            self.assertEqual([v["kind"] for v in videos], ["audio", "video"],
                             serialize.__name__)

    # -- the share-link importer ---------------------------------------

    def test_the_importer_accepts_audio_mpeg_and_stores_that_type(self):
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        resp = MagicMock(headers={"Content-Type": "audio/mpeg"})
        resp.iter_content.return_value = [b"ID3", b"\x00" * 64]
        cli = MagicMock()
        with patch.object(forms_api.EtpStudioFormsApi, "_fetch_share_link",
                          return_value=(resp, None)), \
                patch.object(s3_service, "storage_target",
                             return_value=(cli, "bucket")):
            out = call_route(
                forms_api, forms_api.EtpStudioFormsApi(), "form_media_import",
                self.env,
                url="https://dl.dropboxusercontent.com/s/abc/interview.mp3")
        self.assertEqual(status_of(out), 200, out)
        put = cli.put_object.call_args.kwargs
        self.assertEqual(put["ContentType"], "audio/mpeg")
        self.assertTrue(put["Key"].startswith("form_studio/"))
        self.assertTrue(put["Key"].endswith(".mp3"), put["Key"])
        self.assertEqual(out["data"]["url"], "/api/v1/forms/media/" + put["Key"])
        self.assertEqual(
            self._row(video_url=out["data"]["url"]).media_kind, "audio",
            "an imported mp3 publishes as audio")
