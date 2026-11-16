# -*- coding: utf-8 -*-
"""R6: a release can show the candidate their answers without the key.

With "Show correct answers and feedback" off (`results_show_answers`), the
review keeps the candidate's own answers, their marks per question and their
total, and blanks the correct options, the Correct/Incorrect verdict and the
grader's feedback. Every key stays on the row, so an older app that reads keys
unconditionally keeps working. The setting is read when the review is opened,
so a change applies to results already released. The default (on) is pinned
in `test_the_answer_key_is_shown_by_default`.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import candidate as candidate_api
from ..controllers.api import common as api_common
from ..controllers.api import serializers as S
from ..controllers.api import write as write_api
from ._paging_harness import call_route, status_of

ADMIN_GROUP = "assessments_be_v2.group_assessment_manager"
BLANKED = {"correct": [], "score_raw": None, "feedback": "",
           "score_verdict": "", "deductions": [], "credit": [],
           "verdict": "", "kind": "info"}
KEPT = ("chosen", "justification", "marks_earned", "marks_available", "tags",
        "images", "label_answers", "index", "question_id", "prompt")


@tagged("-at_install", "post_install")
class TestAReleaseCanKeepTheKeyBack(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Key back %s" % uuid4().hex[:6]})
        self.mcq = self._question("mcq", "Pick the capital")
        self.dim = self.env["assessments.be.question.dimension"].create({
            "question_id": self.mcq.id, "name": "Capital",
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": (i + 1) * 10,
                        "is_correct": n == "Paris"})
                for i, n in enumerate(("Paris", "Lyon", "Nice"))],
        })
        self.essay = self._question("subjective_rubric", "Explain why")
        self.unanswered = self._question("subjective_rubric", "And this?")
        self.paper = self.env["assessments.be"].create({
            "name": "Key back paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, (self.mcq | self.essay
                                     | self.unanswered).ids)],
            "question_limit": 3, "duration_minutes": 30,
            "state": "in_progress",
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Key Back",
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        self.ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id,
            "access_token": uuid4().hex,
            "question_order": json.dumps(
                [self.mcq.id, self.essay.id, self.unanswered.id]),
        })
        Response = self.env["assessments.be.response"]
        common = {"assessment_evaluator_id": self.ev.id,
                  "evaluator_id": applicant.id,
                  "assessment_id": self.paper.id}
        lyon = self.dim.option_line_ids.filtered(lambda o: o.name == "Lyon")
        self.wrong = Response.create(dict(common, question_id=self.mcq.id,
                                          line_ids=[(0, 0, {
                                              "question_dimension_id":
                                                  self.dim.id,
                                              "selected_option_id": lyon.id,
                                          })]))
        self.wrong.action_submit()
        self.graded = Response.create(dict(
            common, question_id=self.essay.id, state="submitted",
            justification="Because the sofa is the wrong colour.",
            llm_raw_100=82.0, llm_state="scored",
            llm_feedback="You named the sofa. Say why next time.",
            llm_verdict="Correct call, thinly argued.",
            llm_deductions_json=json.dumps(
                [{"reason": "Thin", "evidence": "one line", "points": -10}]),
            llm_credit_json=json.dumps(
                [{"reason": "Named it", "evidence": "sofa", "points": 30}])))
        self.paper.sudo()._ensure_candidate_user(applicant)
        self.user = self.ev.sudo()._candidate_user()

    def _question(self, qtype, prompt):
        return self.env["assessments.be.question"].create({
            "name": "%s %s" % (qtype, uuid4().hex[:4]), "question_type": qtype,
            "prompt": prompt, "difficulty": "easy",
            "generator_id": self.generator.id,
        })

    def _row(self, question, response, reveal):
        return S.released_answer_review_row(1, question, response, "tok",
                                            reveal=reveal)

    def test_hidden_keeps_the_answer_and_the_marks(self):
        for question, response in ((self.mcq, self.wrong),
                                   (self.essay, self.graded)):
            shown = self._row(question, response, True)
            hidden = self._row(question, response, False)

            self.assertEqual(set(hidden), set(shown), "every key stays")
            self.assertEqual({k: hidden[k] for k in BLANKED}, BLANKED,
                             question.question_type)
            self.assertEqual({k: hidden[k] for k in KEPT},
                             {k: shown[k] for k in KEPT},
                             question.question_type)
        # Positive controls: shown, the same rows do carry what was blanked.
        self.assertEqual(self._row(self.mcq, self.wrong, True)["correct"],
                         ["Paris"])
        self.assertEqual(self._row(self.mcq, self.wrong, True)["chosen"],
                         ["Lyon"])
        shown = self._row(self.essay, self.graded, True)
        self.assertTrue(shown["feedback"] and shown["deductions"]
                        and shown["credit"] and shown["kind"] != "info")

    def test_a_status_still_reads_when_hidden(self):
        hidden = self._row(self.unanswered,
                           self.env["assessments.be.response"], False)
        self.assertEqual((hidden["verdict"], hidden["kind"]),
                         ("Not answered", "info"))

    def _answers(self):
        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(self.env(user=self.user), {})
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            out = candidate_api.EtpAssessmentApiCandidate().exam_answers(
                self.ev.access_token)
        self.assertEqual(out.get("__status", 200), 200, out)
        return {row["question_id"]: row for row in out["data"]["rows"]}

    def test_the_review_reads_the_setting_when_opened(self):
        self.ev.sudo().write({"state": "submitted", "is_locked": True,
                              "results_released": True})
        self.paper.results_show_answers = False
        hidden = self._answers()
        self.assertEqual(hidden[self.mcq.id]["correct"], [])
        self.assertEqual(hidden[self.mcq.id]["chosen"], ["Lyon"])
        self.assertEqual(hidden[self.essay.id]["feedback"], "")

        self.paper.results_show_answers = True
        shown = self._answers()
        self.assertEqual(shown[self.mcq.id]["correct"], ["Paris"])
        self.assertTrue(shown[self.essay.id]["feedback"])

    def test_the_setting_can_change_after_launch(self):
        self.env.user.group_ids = [(4, self.env.ref(ADMIN_GROUP).id)]
        out = call_route(write_api, write_api.EtpAssessmentApiWrite(),
                         "assessment_update", self.env,
                         path={"assessment_id": self.paper.id},
                         results_show_answers=False)

        self.assertEqual(status_of(out), 200, out)
        self.assertFalse(self.paper.results_show_answers)
        self.assertIs(out["data"]["results_show_answers"], False)

    def test_create_keeps_the_setting_off(self):
        """The New Assessment screen sends the switch on create."""
        self.env.user.group_ids = [(4, self.env.ref(ADMIN_GROUP).id)]
        out = call_route(write_api, write_api.EtpAssessmentApiWrite(),
                         "assessment_create", self.env,
                         name="Key back new %s" % uuid4().hex[:4],
                         generator_id=self.generator.id,
                         results_show_answers=False)

        self.assertEqual(status_of(out), 200, out)
        paper = self.env["assessments.be"].browse(out["data"]["id"])
        self.assertFalse(paper.results_show_answers)
        self.assertIs(out["data"]["results_show_answers"], False)
