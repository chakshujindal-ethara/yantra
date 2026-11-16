# -*- coding: utf-8 -*-
"""A labelling question is marked out of the boxes it actually sent, and its
reply is judged by the field the mark comes from.

qa-grading-edge-1 - `_label_boxes` sends the authored `ideal_labels` when
there is no behavioural key and no detection, so `_label_total_boxes` counts
them too; otherwise the denominator is 0 and every candidate scores 0 on a
billed question. A free-text `ideal_labels` has no numbered box: the question
is keyless (`lacks_answer_key`), so Launch warns and the answer is flagged
`no_answer_key`.

qa-grading-edge-2 - a labelling mark comes from `box_scores`, not the
top-level `score`. A reply with complete box scores and no top-level score is
a result; a reply with a score and no (or partial) box scores is retried, and
scored anyway on the last attempt.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc

_ICP = "assessments_be_v2.%s"


@tagged("-at_install", "post_install")
class _LabelPaper(TransactionCase):

    def setUp(self):
        super().setUp()
        icp = self.env["ir.config_parameter"].sudo()
        for key, value in (("llm_max_attempts", "3"),
                           ("daily_llm_cap_usd", "0"),
                           ("per_evaluator_llm_cap_usd", "0"),
                           ("vertex_max_rpm", "0")):
            icp.set_param(_ICP % key, value)
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Labels %s" % uuid4().hex[:6]})

    def _question(self, key):
        """An image_label question whose ONLY key is ``key`` - no behavioural
        key and no detections, which is the authoring shape that was billed
        and always marked 0."""
        return self.env["assessments.be.question"].create({
            "name": "Label %s" % uuid4().hex[:6],
            "question_type": "image_label",
            "prompt": "Label each numbered control.",
            "generator_id": self.generator.id,
            "subjective_rubric_json": json.dumps(key),
        })

    def _answer(self, question, labels):
        paper = self.env["assessments.be"].create({
            "name": "Label paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
            "subjective_threshold": 70,
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "c_%s@example.com" % uuid4().hex[:8],
        })
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id,
            "state": "submitted"})
        return self.env["assessments.be.response"].create({
            "assessment_evaluator_id": ev.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "assessment_id": paper.id,
            "state": "submitted",
            "justification": json.dumps(labels),
            "llm_state": "pending",
        })

    def _grade(self, resp, item):
        reply = json.dumps({"results": [dict(item, id=resp.id)]})
        with patch.object(vertex_svc, "_call_vertex", return_value=reply):
            return scoring_svc._score_submission(self.env, resp)


class TestAnIdealLabelsKeyIsARealKey(_LabelPaper):

    KEY = {"ideal_labels": {"1": "Opens the menu",
                            "2": "Saves the draft",
                            "3": "Closes the dialog"}}

    def test_the_boxes_sent_are_the_boxes_counted(self):
        question = self._question(self.KEY)
        self.assertEqual(
            sorted(scoring_svc._label_boxes(question)), ["1", "2", "3"],
            "these are the boxes the grader is sent")
        self.assertEqual(
            scoring_svc._label_total_boxes(question), 3,
            "so they are what the answer is marked out of")

    def test_the_answer_is_marked_instead_of_scoring_zero(self):
        question = self._question(self.KEY)
        resp = self._answer(question, {"1": "Opens the menu",
                                       "2": "Saves the draft",
                                       "3": "Closes the dialog"})

        self._grade(resp, {"score": 95,
                           "box_scores": {"1": 95, "2": 95, "3": 95}})

        self.assertEqual(resp.llm_state, "scored")
        self.assertEqual(json.loads(resp.label_box_scores_json),
                         {"1": 95.0, "2": 95.0, "3": 95.0})
        mark, _raw, _fraction = resp._label_marks(70)
        self.assertEqual(mark, 1.0,
                         "a correct answer to a keyed question earns its mark")

    def test_a_free_text_ideal_label_is_keyless_not_pretend_keyed(self):
        """No numbered box means nothing per box to mark against: Launch warns
        and the answer is flagged `no_answer_key` rather than silently 0."""
        question = self._question({"ideal_labels": "label the buttons"})
        self.assertEqual(scoring_svc._label_boxes(question), {})
        self.assertTrue(scoring_svc.lacks_answer_key(question))


class TestALabellingReplyIsJudgedByItsBoxScores(_LabelPaper):

    KEY = {"ideal_labels": {"1": "Opens the menu", "2": "Saves the draft"}}

    def _two_box_answer(self):
        question = self._question(self.KEY)
        return self._answer(question, {"1": "Opens the menu",
                                       "2": "Saves the draft"})

    def test_complete_box_scores_with_no_top_level_score_are_a_result(self):
        resp = self._two_box_answer()

        self._grade(resp, {"box_scores": {"1": 90, "2": 80}})

        self.assertEqual(resp.llm_state, "scored",
                         "the mark comes from box_scores; there is nothing "
                         "missing about this reply")
        self.assertEqual(json.loads(resp.label_box_scores_json),
                         {"1": 90.0, "2": 80.0})

    def test_a_reply_with_no_box_scores_is_retried_not_stored_as_zero(self):
        resp = self._two_box_answer()

        self._grade(resp, {"score": 70})

        self.assertNotEqual(
            resp.llm_state, "scored",
            "a labelling reply carrying no box score at all is the worst "
            "case, not an exempt one")
        self.assertEqual(resp.llm_state, "failed")
        self.assertEqual(resp.llm_attempts, 1)

    def test_a_partial_reply_is_still_retried(self):
        resp = self._two_box_answer()
        self._grade(resp, {"score": 70, "box_scores": {"1": 90}})
        self.assertEqual(resp.llm_state, "failed")

    def test_the_last_attempt_scores_anyway(self):
        resp = self._two_box_answer()
        resp.llm_attempts = 2          # one try left
        self._grade(resp, {"score": 70})
        self.assertEqual(resp.llm_state, "scored",
                         "an answer that never scores strands the paper")
