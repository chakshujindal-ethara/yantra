# -*- coding: utf-8 -*-
"""MT2FA-02: the Responses list shows a written answer instead of "Left blank".

`response_row` built `answer_summary` from option picks only and never sent the
written text, so every written answer in the org-wide list read "Left blank".
It now carries `justification_preview`: the text on one line, first 200
characters with "..." when cut, and "" once the candidate's data is erased.
"""
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import serializers as S
from .test_individual_scoring_stays_individual import _Paper


@tagged("-at_install", "post_install")
class TestAWrittenAnswerShowsInTheResponsesList(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_the_row_carries_a_preview_until_the_data_is_erased(self):
        asha = self._candidate(2)
        short, long_ = self._answers(asha)
        long_.justification = "  word\n\n  " * 60

        self.assertEqual(
            S.response_row(short)["justification_preview"],
            "A considered written answer, number 0, long enough to grade.")
        preview = S.response_row(long_)["justification_preview"]
        self.assertEqual(preview, ("word " * 60)[:200] + "...")

        asha.action_erase_candidate_data()
        self.assertEqual(S.response_row(short)["justification_preview"], "")
