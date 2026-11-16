# -*- coding: utf-8 -*-
"""A transcription key writes every number as words (R7, 15 Oct).

The client's QC rules count a digit in a transcription as a Critical mistake,
so the key a candidate is judged against must not carry one. Publishing used
to convert Devanagari digits to English ones and keep them; it now refuses the
key and says how to write it.
"""
import json
from unittest.mock import patch

from odoo.tests.common import tagged

from odoo.addons.assessments_be_v2.models import studio_form as studio_form_mod
from odoo.addons.assessments_be_v2.tests.test_authored_question_marks import (
    _FormBase,
)

_MP3 = "/api/v1/forms/media/form_studio/%s/clip.mp3" % ("c" * 32)


def _never(*a, **kw):
    raise AssertionError("publish must not fetch a clip")


@tagged("-at_install", "post_install")
class TestATranscriptionKeyWritesNumbersAsWords(_FormBase):

    def _transcription(self, golden, category="none"):
        return self._item("transcription", title="Type what you hear",
                          media_url=_MP3, media_kind="audio",
                          transcription_language="hi", golden_answer=golden,
                          golden_clip={"category": category,
                                       "characteristics": [], "speakers": []})

    def test_a_key_with_a_digit_is_refused(self):
        for golden in ("नंबर 10 है", "नंबर १० है"):
            with self.subTest(golden=golden):
                form, result = self._publish(self._transcription(golden))
                self._refused(form, result,
                              "write every number as words",
                              "A digit in a transcription is a critical "
                              "mistake")

        with patch.object(studio_form_mod.requests, "get", _never):
            form, result = self._publish(self._transcription("नंबर दस है"))
        self.assertEqual(json.loads(self._published_one(
            form, result).solution_json)["transcription"], "नंबर दस है")

        # A clip that is not transcribed keeps no text, so nothing to refuse.
        with patch.object(studio_form_mod.requests, "get", _never):
            form, result = self._publish(
                self._transcription("10", category="no_speech"))
        self.assertEqual(json.loads(self._published_one(
            form, result).solution_json)["transcription"], "")
