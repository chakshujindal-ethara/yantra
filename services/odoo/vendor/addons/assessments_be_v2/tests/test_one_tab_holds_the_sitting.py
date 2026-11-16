# -*- coding: utf-8 -*-
"""One exam session at a time: the newest tab wins.

The app sends a per-tab `session_key` in the JSON body of the exam routes.
`/state` (question gate) and `/begin` store it; `/answer`, `/review`,
`/submit` and `/violation` carrying a DIFFERENT key answer 409
`session_replaced` and store nothing. No key (an older app) is admitted as
before, and a finished or expired attempt answers as it always did.
"""
import json
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import candidate as candidate_api
from ..controllers.api import common as api_common

OLD, NEW = "tab-old", "tab-new"


@tagged("-at_install", "post_install")
class TestOneTabHoldsTheSitting(TransactionCase):

    def setUp(self):
        super().setUp()
        self.controller = candidate_api.EtpAssessmentApiCandidate()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Tabs %s" % uuid4().hex[:6]})
        self.question = self.env["assessments.be.question"].create({
            "name": "Q", "question_type": "subjective_rubric",
            "prompt": "Explain", "difficulty": "easy",
            "generator_id": generator.id,
        })
        paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, self.question.ids)], "question_limit": 1,
            "duration_minutes": 30, "state": "in_progress",
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Two Tabs",
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id,
            "question_order": json.dumps(self.question.ids),
            "access_token": uuid4().hex,
        })
        paper.sudo()._ensure_candidate_user(applicant)
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
            out = getattr(self.controller, route)(
                self.evaluator.access_token, **params)
        self.evaluator.invalidate_recordset()
        return out

    def _answer(self, text, **params):
        return self._call("exam_answer", question_id=self.question.id,
                          justification=text, nav="stay", **params)

    def test_the_newest_tab_wins_and_the_old_one_writes_nothing(self):
        self._call("exam_begin", session_key=OLD)
        self.assertEqual(self.evaluator.exam_session_key, OLD)
        state = self._call("exam_state", session_key=NEW)
        self.assertEqual(state["data"]["outcome"], "question", state)
        self.assertEqual(self.evaluator.exam_session_key, NEW)
        self.assertNotIn(NEW, json.dumps(state, default=str),
                         "the key must stay out of the payload")

        for route, params in (
                ("exam_answer", {"question_id": self.question.id,
                                 "justification": "Old tab", "nav": "stay"}),
                ("exam_review", {}), ("exam_violation", {"reason": "tab"}),
                ("exam_submit", {"force": True})):
            out = self._call(route, session_key=OLD, **params)
            error = out.get("error") or {}
            self.assertEqual(
                (out.get("__status", 200), error.get("code"),
                 error.get("message")),
                (409, "session_replaced",
                 "This exam is now open in another tab or device."),
                (route, out))
        self.assertFalse(self.evaluator.response_ids, "old tab stored")
        self.assertEqual(
            (self.evaluator.state, self.evaluator.violation_count),
            ("in_progress", 0))

        self.assertTrue(self._answer("New tab", session_key=NEW)["data"]["saved"])
        self.assertTrue(self._answer("Old app")["data"]["saved"],
                        "a request with no key must be allowed")
        self._call("exam_state", session_key=NEW)
        self.assertTrue(
            self._answer("After reload", session_key=NEW)["data"]["saved"])
        self.assertEqual(self.evaluator.response_ids.justification,
                         "After reload")

        done = self._call("exam_submit", session_key=NEW)
        self.assertTrue(done["data"]["submitted"], done)
        late = self._answer("Too late", session_key=OLD)
        self.assertEqual(late["error"]["code"], "attempt_locked", late)
        state = self._call("exam_state", session_key=OLD)
        self.assertEqual(state["data"]["outcome"], "complete")
        self.assertEqual(self.evaluator.exam_session_key, NEW)

    def test_an_expired_attempt_still_answers_time_up(self):
        self._call("exam_begin", session_key=NEW)
        self.evaluator.started_at = fields.Datetime.now() - timedelta(
            minutes=31)
        out = self._call("exam_violation", session_key=OLD, reason="tab")
        self.assertEqual((out["__status"], out["error"]["code"]),
                         (409, "time_expired"), out)
        self.assertTrue(self.evaluator.is_locked)
