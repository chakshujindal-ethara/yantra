# -*- coding: utf-8 -*-
"""A re-grade that cannot produce a trustworthy mark keeps the old one (W6).

Two ways a re-grade of a scored answer still wrote a zero over its mark
(2026-09-22 review):

  * a labelling answer whose grader reply carried a score but no
    `box_scores`: every box stored 0;
  * an image A/B answer whose answer key has drifted: the key-drift guard
    stores 0 and a re-grade went through it like a first grade.

A first grade keeps its remaining attempts (labelling) or is scored as
the guard decides (A/B key drift); neither takes a mark from the reply
that failed.
"""
import json
from types import SimpleNamespace
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger

from ..services import scoring as scoring_svc
from .test_individual_scoring_stays_individual import _Paper


@tagged("-at_install", "post_install")
class TestAFailedRegradeKeepsTheOldMark(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def _answer(self, question_type, regrade, **question):
        ev = self._candidate(1)
        answer = self._answers(ev)
        answer.question_id.write(dict(question, question_type=question_type))
        answer.write({"justification": json.dumps(
            {"1": "Opens the menu", "2": "Closes the menu"})
            if question_type == "image_label" else "B warps the logo.",
            "llm_state": "scored" if regrade else "pending",
            "llm_raw_100": 75.0 if regrade else 0.0,
            "llm_attempts": 1 if regrade else 0,
            "rescore_request_key": "a-click" if regrade else False})
        return answer

    def _grade_label(self, answer):
        job = SimpleNamespace(
            gradable=[answer], served_models=[], model="gemini-x",
            prompt_version="bundled:x",
            rules={answer.id: ("P3 DENSE UI LABELLING", [])},
            prescored=0, total=1)
        # A usable score, and no `box_scores` at all.
        reply = [{"id": answer.id, "score": 70, "verdict": "ok",
                  "deductions": [{"points": -30, "reason": "x",
                                  "evidence": "y"}]}]
        with patch.object(scoring_svc, "_label_total_boxes", lambda q: 2):
            scoring_svc._settle_submission(self.env, job, reply, None)

    def test_a_label_regrade_with_no_box_scores(self):
        answer = self._answer("image_label", regrade=True)

        self._grade_label(answer)

        self.assertEqual((answer.llm_state, answer.llm_raw_100),
                         ("scored", 75.0), "the old mark was replaced")
        self.assertFalse(answer.rescore_request_key)

    def test_a_first_label_grade_with_no_box_scores_is_retried(self):
        """A labelling mark comes from `box_scores`, so a reply carrying none
        is the reply most in need of another ask - it used to be stored as a
        silent zero on the first try (qa-grading-edge-2). A re-grade above
        keeps its old mark; a first grade gets its remaining attempts."""
        answer = self._answer("image_label", regrade=False)

        self._grade_label(answer)

        self.assertEqual((answer.llm_state, answer.llm_attempts),
                         ("failed", 1))

    def _drift(self, answer):
        with patch.object(scoring_svc, "_ab_key_drift",
                          lambda resp: ["Q1: stored A, construction B"]), \
                mute_logger("odoo.addons.assessments_be_v2.services.scoring"):
            scoring_svc._prepare_submission(self.env, answer)

    def test_an_ab_regrade_whose_key_drifted(self):
        answer = self._answer("image_ab", regrade=True,
                              official_reasoning="A keeps the logo.")

        self._drift(answer)

        self.assertEqual((answer.llm_state, answer.llm_raw_100),
                         ("scored", 75.0), "the old mark was replaced")
        self.assertFalse(answer.rescore_request_key)
        self.assertIn("key drift", answer.assessment_evaluator_id.llm_error)

    def test_a_first_ab_grade_whose_key_drifted_is_unchanged(self):
        answer = self._answer("image_ab", regrade=False,
                              official_reasoning="A keeps the logo.")

        self._drift(answer)

        self.assertEqual((answer.llm_state, answer.llm_raw_100),
                         ("scored", 0.0))
