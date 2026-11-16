# -*- coding: utf-8 -*-
"""A draft paper's token is an unknown link until launch.

Owner, 2026-09-25: "candidate should never get a link or assessment if it is in
draft". The roster row, and its token, exists from assignment; `/state` on it
answered `closed` with the paper's name and `state: draft`. Now every exam route
and the exam media resolve it to nothing - `invalid` on `/state`, 404
`invalid_token` on the rest - and the same token works once launched.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers import exam_media
from ..controllers.api import candidate as candidate_api
from ..controllers.api import common as api_common


@tagged("-at_install", "post_install")
class TestADraftPaperIsAnUnknownLink(TransactionCase):

    def setUp(self):
        super().setUp()
        self.controller = candidate_api.EtpAssessmentApiCandidate()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Draft %s" % uuid4().hex[:6]})
        self.question = self.env["assessments.be.question"].create({
            "name": "Q", "question_type": "subjective_rubric",
            "prompt": "Explain", "difficulty": "easy",
            "generator_id": generator.id,
        })
        self.paper = self.env["assessments.be"].create({
            "name": "Unlaunched %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, self.question.ids)], "question_limit": 1,
            "duration_minutes": 30,
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Too Early",
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id,
            "question_order": json.dumps(self.question.ids),
            "access_token": uuid4().hex,
        })
        self.paper.sudo()._ensure_candidate_user(applicant)
        self.user = self.evaluator.sudo()._candidate_user()

    def _call(self, route, **params):
        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(self.env(user=self.user), params)
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            return getattr(self.controller, route)(
                self.evaluator.access_token, **params)

    def _media_evaluator(self):
        fake = type("R", (), {"env": self.env})()
        with patch.object(exam_media, "request", fake):
            return exam_media.AssessmentsBeExamMedia()._evaluator(
                self.evaluator.access_token)

    def test_a_draft_token_is_invalid_everywhere_until_launch(self):
        self.assertEqual(self.paper.state, "draft")
        state = self._call("exam_state")
        self.assertEqual(state["data"]["outcome"], "invalid", state)
        self.assertNotIn(self.paper.name, json.dumps(state, default=str))

        answer = {"question_id": self.question.id,
                  "justification": "Before launch", "nav": "stay"}
        for route, params in (("exam_begin", {}), ("exam_answer", answer),
                              ("exam_review", {}),
                              ("exam_violation", {"reason": "tab"}),
                              ("exam_submit", {"force": True}),
                              ("exam_answers", {})):
            out = self._call(route, **params)
            self.assertEqual((out.get("__status", 200), out.get("error")),
                             (404, {"code": "invalid_token",
                                    "message": "Unknown assessment link"}),
                             (route, out))
        self.assertFalse(self._media_evaluator(), "draft media served")
        self.evaluator.invalidate_recordset()
        self.assertFalse(self.evaluator.started_at)
        self.assertFalse(self.evaluator.response_ids)
        self.assertEqual(self.evaluator.violation_count, 0)

        self.paper.state = "in_progress"
        self.assertEqual(self._call("exam_state")["data"]["outcome"],
                         "instructions")
        self.assertEqual(self._media_evaluator(), self.evaluator)
        self.assertNotIn("error", self._call("exam_begin"))
        saved = self._call("exam_answer", **answer)
        self.assertTrue(saved["data"]["saved"], saved)
