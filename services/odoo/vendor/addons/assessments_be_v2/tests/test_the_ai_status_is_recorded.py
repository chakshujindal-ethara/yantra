# -*- coding: utf-8 -*-
"""R9d: the exam page reports whether its AI proctoring (and eye tracking) ran.

`POST /api/v1/exam/<token>/ai-status {status}` stores one of the attempt's
`ai_status` values, so an admin can tell an AI that never started from a
candidate who broke no rule. Same guard as `/review-flag`: only the assigned
candidate, only an unsubmitted attempt (begun or not: the app starts the AI
before `/begin` commits), only on a paper with AI proctoring on. An unknown value is refused, and the same value again writes
nothing.
"""
import json
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import candidate as candidate_api
from ..controllers.api import common as api_common
from ..controllers.api import serializers as S


@tagged("-at_install", "post_install")
class TestTheAiStatusIsRecorded(TransactionCase):

    def setUp(self):
        super().setUp()
        self.controller = candidate_api.EtpAssessmentApiCandidate()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "AI status %s" % uuid4().hex[:6]})
        question = self.env["assessments.be.question"].create({
            "name": "Q", "question_type": "subjective_rubric",
            "prompt": "Explain", "difficulty": "easy",
            "generator_id": generator.id,
        })
        self.paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, question.ids)], "question_limit": 1,
            "duration_minutes": 60, "state": "in_progress",
            "rule_webcam": True, "rule_ai_proctor": True,
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Status Sitter",
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        self.ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id,
            "question_order": json.dumps(question.ids),
            "access_token": uuid4().hex, "state": "in_progress",
            "started_at": fields.Datetime.now() - timedelta(minutes=5),
        })
        self.paper.sudo()._ensure_candidate_user(applicant)
        self.user = self.ev.sudo()._candidate_user()

    def _post(self, status, **extra):
        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(self.env(user=self.user), dict(extra, status=status))
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            out = self.controller.exam_ai_status(self.ev.access_token)
        self.ev.invalidate_recordset()
        return out

    def test_a_status_is_stored_and_the_admin_sees_it(self):
        out = self._post("running_gaze")

        self.assertEqual(out.get("__status", 200), 200, out)
        self.assertEqual(self.ev.ai_status, "running_gaze")
        self.assertEqual(
            S.evaluator_admin_row(self.ev)["flags"]["ai_status"],
            "running_gaze")
        self.assertEqual(self._post("gaze_failed").get("__status", 200), 200)
        self.assertEqual(self.ev.ai_status, "gaze_failed")

    def test_a_status_sent_before_begin_is_stored(self):
        """The app starts the AI before `/begin` commits; that status was a
        409 not_started and lost."""
        self.ev.sudo().write({"started_at": False})
        out = self._post("running")

        self.assertEqual(out.get("__status", 200), 200, out)
        self.assertEqual(self.ev.ai_status, "running")

    def test_a_replaced_tab_is_still_refused(self):
        self.ev.sudo().write({"exam_session_key": "live-tab"})
        out = self._post("running", session_key="old-tab")

        self.assertEqual((out["__status"], out["error"]["code"]),
                         (409, "session_replaced"), out)
        self.assertFalse(self.ev.ai_status)

    def test_the_same_status_again_writes_nothing(self):
        self._post("running")
        Evaluator = type(self.ev)
        original = Evaluator.write
        with patch.object(Evaluator, "write", autospec=True,
                          side_effect=original) as write:
            out = self._post("running")
        self.assertEqual(out.get("__status", 200), 200, out)
        write.assert_not_called()

    def test_an_unknown_status_is_refused(self):
        self._post("running")
        out = self._post("dancing")

        self.assertEqual((out["__status"], out["error"]["code"]),
                         (422, "invalid"), out)
        self.assertEqual(self.ev.ai_status, "running")

    def test_a_submitted_attempt_is_refused(self):
        self.ev.sudo().write({"state": "submitted", "is_locked": True})
        out = self._post("failed")

        self.assertEqual((out["__status"], out["error"]["code"]),
                         (409, "attempt_locked"), out)
        self.assertFalse(self.ev.ai_status)

    def test_a_paper_without_ai_proctoring_is_refused(self):
        self.paper.rule_ai_proctor = False
        out = self._post("running")

        self.assertEqual(out["__status"], 409, out)
        self.assertFalse(self.ev.ai_status)

    def test_an_expired_attempt_is_refused(self):
        self.ev.sudo().write(
            {"started_at": fields.Datetime.now() - timedelta(minutes=90)})
        out = self._post("running")

        self.assertEqual((out["__status"], out["error"]["code"]),
                         (409, "time_expired"), out)
        self.assertFalse(self.ev.ai_status)
