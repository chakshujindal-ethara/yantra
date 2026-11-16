# -*- coding: utf-8 -*-
"""R7: a transcription clip has its own pass bar.

`transcription_threshold` is the cut-off a transcription clip's score must
clear; 0 (not set, every paper made before it) follows the subjective
threshold, so no existing result moves. Every other graded answer keeps the
subjective threshold. Raw scores are stored, so an edit re-decides without
re-grading. Model level; the API wiring is tested beside the routes.
"""
from uuid import uuid4

from odoo.exceptions import ValidationError
from odoo.tests.common import TransactionCase, tagged

from .test_a_running_lane_keeps_what_it_holds import a_lane_is_running
from .test_individual_scoring_stays_individual import _Paper


@tagged("-at_install", "post_install")
class TestTheTranscriptionThresholdIsItsOwn(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def _sitting(self, raw=90):
        """One transcription clip and one essay, both graded ``raw``, with
        two minor mistakes on the clip (under the client's limit of five)."""
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Clip %s" % uuid4().hex[:6],
            "email_from": "clip_%s@example.com" % uuid4().hex[:8],
        })
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id})
        answers = {}
        for qtype in ("transcription", "subjective_rubric"):
            question = self.env["assessments.be.question"].create({
                "name": "%s %s" % (qtype, uuid4().hex[:4]),
                "question_type": qtype,
                "prompt": "Answer",
                "generator_id": self.generator.id,
                "assessment_ids": [(4, self.paper.id)],
            })
            answers[qtype] = self.env["assessments.be.response"].create({
                "assessment_evaluator_id": ev.id,
                "evaluator_id": applicant.id,
                "question_id": question.id,
                "assessment_id": self.paper.id,
                "state": "submitted",
                "justification": "तो ये देखो मेरा नाम राहुल है",
                "llm_state": "scored", "llm_raw_100": raw, "llm_attempts": 1,
                "llm_minor_count": 2 if qtype == "transcription" else 0,
            })
        ev.write({"state": "submitted"})
        ev._compute_subjective_rollup()
        return answers["transcription"], answers["subjective_rubric"]

    def test_zero_follows_the_subjective_threshold(self):
        self.paper.write({"subjective_threshold": 95})
        self.assertEqual(self.paper.transcription_threshold, 0.0,
                         "not set on a new paper")
        clip, essay = self._sitting(raw=90)
        self.assertFalse(clip.llm_passed)
        self.paper.subjective_threshold = 85
        self.assertTrue(clip.llm_passed)
        self.assertTrue(essay.llm_passed)

    def test_the_clip_bar_does_not_move_the_essay(self):
        self.paper.write({"subjective_threshold": 95,
                          "transcription_threshold": 80})
        clip, essay = self._sitting(raw=90)
        self.assertTrue(clip.llm_passed)
        self.assertEqual(clip.llm_score, 1)
        self.assertFalse(essay.llm_passed)
        self.assertEqual(essay.llm_score, 0)

    def test_editing_it_re_decides_without_re_grading(self):
        self.paper.write({"subjective_threshold": 60,
                          "transcription_threshold": 95})
        clip, essay = self._sitting(raw=90)
        self.assertFalse(clip.llm_passed)

        self.paper.transcription_threshold = 85

        self.assertTrue(clip.llm_passed)
        self.assertTrue(essay.llm_passed)
        self.assertEqual((clip.llm_raw_100, clip.llm_state), (90.0, "scored"))

    def test_an_edit_waits_for_a_running_lane(self):
        self.paper.transcription_threshold = 95
        clip, _essay = self._sitting(raw=90)
        self.assertFalse(clip.llm_passed)
        clip.assessment_evaluator_id.llm_state = "scoring"
        with a_lane_is_running(self.env):
            self.paper.transcription_threshold = 85.0
        self.assertTrue(self.paper.threshold_recompute_pending,
                        "the edit is one of the threshold writes")
        self.assertTrue(clip.llm_passed,
                        "the stored mark still follows through its depends")

    def test_outside_0_to_100_is_refused(self):
        self.paper.transcription_threshold = 80
        for bad in (-1, 101):
            # assertRaises, not assertRaisesRegex: only it rolls back to a
            # savepoint, so the refused value does not stay in the cache.
            with self.assertRaises(ValidationError) as refused:
                self.paper.transcription_threshold = bad
                self.env.flush_all()
            self.assertIn("Transcription Pass Threshold",
                          str(refused.exception))
        self.assertEqual(self.paper.transcription_threshold, 80.0)
