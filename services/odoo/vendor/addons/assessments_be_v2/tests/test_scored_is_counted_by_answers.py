# -*- coding: utf-8 -*-
""""Scored" is a fact about a candidate's ANSWERS, not their `llm_state`.

`docs/ETP_PLANS_AND_STRATEGY.md` §2.5 (W3.3): "Scored X/Y" counted candidates whose
`llm_state` is `scored` - and an objective-only paper is never graded, so it
never gets there and the line undercounted for ever. Scored = submitted, and no
answer that needs the grader is left unscored; Score Pending is the rest of the
submitted. `assessments.be.evaluator._answers_scored_domain` is that one
definition, and Score All (`action_llm_score_all`) selects with it too: one
query, not a walk over every answer of the cohort in Python.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as admin_api
from ..controllers.api import common as api_common


@tagged("-at_install", "post_install")
class TestScoredIsCountedByAnswers(TransactionCase):

    def setUp(self):
        super().setUp()
        self.paper = self.env["assessments.be"].create(
            {"name": "Answers %s" % uuid4().hex[:6]})
        self.written = self._question("subjective_rubric")
        self.choice = self._question("mcq")
        E = self.env["assessments.be.evaluator"]
        self.objective_only = self._candidate([(self.choice, "", None)],
                                              "pending")
        self.graded = self._candidate(
            [(self.choice, "", None), (self.written, "text", "scored")],
            "scored")
        self.left_blank = self._candidate([(self.written, "", None)],
                                          "pending")
        self.waiting = self._candidate([(self.written, "text", "pending")],
                                       "pending")
        self.errored = self._candidate([(self.written, "text", "error")],
                                       "error")
        self.sitting = self._candidate([(self.written, "text", "scored")],
                                       "scored", state="in_progress")
        self.scored = (self.objective_only | self.graded | self.left_blank)
        self.pending = self.waiting | self.errored
        self.E = E

    def _question(self, kind):
        return self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:4],
            "question_type": kind,
            "prompt": "Answer this",
            "assessment_ids": [(4, self.paper.id)],
        })

    def _candidate(self, answers, llm_state, state="submitted"):
        applicant = self.env["hr.applicant"].create(
            {"partner_name": "Cand %s" % uuid4().hex[:6]})
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id})
        for question, text, graded in answers:
            self.env["assessments.be.response"].create({
                "assessment_evaluator_id": ev.id,
                "evaluator_id": applicant.id,
                "question_id": question.id,
                "assessment_id": self.paper.id,
                "state": "submitted",
                "justification": text,
                "llm_state": graded or "not_needed",
            })
        ev.write({"state": state, "llm_state": llm_state})
        return ev

    def _in_paper(self, scored):
        return self.E.search([("assessment_id", "=", self.paper.id)]
                             + self.E._answers_scored_domain(scored=scored))

    def test_the_definition_splits_the_submitted_in_two(self):
        self.assertEqual(self._in_paper(True), self.scored)
        self.assertEqual(self._in_paper(False), self.pending)

    def test_the_finished_line_counts_the_objective_only_candidate(self):
        self.paper.invalidate_recordset()
        self.assertEqual(self.paper.scoring_phase, "idle")
        self.assertEqual(
            (self.paper.scoring_scored_count,
             self.paper.scoring_candidate_count), (3, 5),
            "Scored X/Y is counted by answers: the objective-only and the "
            "blank-answer candidates are scored; the one still sitting is "
            "not a candidate yet")

    def test_the_queue_click_queues_score_pending_without_reading_answers(self):
        self.env.invalidate_all()

        self.paper.action_llm_score_all()

        self.assertEqual(
            self.E.search([("assessment_id", "=", self.paper.id),
                           ("scoring_requested", "=", True)]), self.pending)
        answers = self.env["assessments.be.response"].search(
            [("assessment_id", "=", self.paper.id)])
        cached = self.env["assessments.be.response"]._fields[
            "needs_llm"]._get_cache(self.env)
        self.assertFalse(
            set(answers.ids) & set(cached),
            "the click walked the cohort's answers in Python again")

    def test_the_queue_route_reports_what_it_queued(self):
        self.env.ref(
            "assessments_be_v2.group_assessment_manager"
        ).sudo().write({"user_ids": [(4, self.env.user.id)]})
        stub = type("Req", (), {
            "env": self.env, "params": {"assessment_id": self.paper.id}})()
        with patch.object(admin_api, "request", stub), \
                patch.object(api_common, "request", stub):
            reply = admin_api.EtpAssessmentApiAdmin().scoring_queue()
        # `skipped` joined `queued` when the route stopped counting what it
        # had SELECTED and started reporting what the action actually queued
        # (audit swe-api-models-6). Nothing is being graded here, so it is 0.
        self.assertEqual(reply["data"], {"queued": 2, "skipped": 0})
