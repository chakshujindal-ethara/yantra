# -*- coding: utf-8 -*-
"""The clock starts at `/begin`; nothing is answered before it.

Product test, 2026-09-25: a candidate who never pressed Start could POST
`/answer` with `nav: "next"` (getting each next question in full), answer the
paper and POST `/submit` - 200, submitted, `started_at` and the deadline both
NULL, so no timer ever ran. `/answer`, `/review`, `/submit` and `/violation` now
refuse an attempt that was never begun with 409 `not_started`, storing
nothing. The app calls them only after `/begin` (its instructions gate), and a
resume already has `started_at`, so no real flow is refused.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import candidate as candidate_api
from ..controllers.api import common as api_common


@tagged("-at_install", "post_install")
class TestAnExamMustBeBegunBeforeItIsAnswered(TransactionCase):

    def setUp(self):
        super().setUp()
        self.controller = candidate_api.EtpAssessmentApiCandidate()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Begin %s" % uuid4().hex[:6]})
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
            "partner_name": "Early Bird",
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
            return getattr(self.controller, route)(
                self.evaluator.access_token, **params)

    def test_nothing_before_begin_everything_after(self):
        answer = {"question_id": self.question.id,
                  "justification": "Before the clock", "nav": "next"}
        for route, params in (("exam_answer", answer), ("exam_review", {}),
                              ("exam_violation", {"reason": "tab"}),
                              ("exam_submit", {"force": True})):
            out = self._call(route, **params)
            self.assertEqual((out.get("__status"), out["error"]["code"]),
                             (409, "not_started"), (route, out))
            self.assertNotIn("next", out, route)
        self.evaluator.invalidate_recordset()
        self.assertFalse(self.evaluator.response_ids, "an answer was stored")
        self.assertEqual(
            (self.evaluator.state, self.evaluator.violation_count),
            ("pending", 0))

        begun = self._call("exam_begin")
        self.assertNotIn("error", begun, begun)
        self.assertTrue(self.evaluator.started_at)
        saved = self._call("exam_answer", **dict(answer, nav="stay"))
        self.assertTrue(saved["data"]["saved"], saved)
        done = self._call("exam_submit")
        self.assertTrue(done["data"]["submitted"], done)
        self.assertEqual(self.evaluator.state, "submitted")

    def test_the_review_counts_a_grids_unanswered_rows(self):
        """A reloaded runner learns which grid is only partly answered:
        `rows[].rows_unanswered` on `/review` (and the `review` block of
        `/answer`)."""
        grid = self.env["assessments.be.question"].create({
            "name": "Grid", "question_type": "mcq", "prompt": "Rate each",
            "difficulty": "easy",
            "generator_id": self.question.generator_id.id,
        })
        rows = [self.env["assessments.be.question.dimension"].create({
            "question_id": grid.id, "name": "Row %d" % n,
            "option_line_ids": [(0, 0, {"name": o, "sequence": j,
                                        "is_correct": j == 0})
                                for j, o in enumerate(("Yes", "No"))],
        }) for n in (1, 2, 3)]
        self.evaluator.question_order = json.dumps(
            [self.question.id, grid.id])
        self.evaluator.assessment_id.question_ids = [(4, grid.id)]
        self._call("exam_begin")

        def unanswered():
            review = self._call("exam_review")["data"]["rows"]
            return {r["question_id"]: r["rows_unanswered"] for r in review}

        self.assertEqual(unanswered(), {self.question.id: 0, grid.id: 3})
        self._call("exam_answer", question_id=grid.id, nav="stay",
                   selected_option_ids=rows[0].option_line_ids[:1].ids)
        self.assertEqual(unanswered()[grid.id], 2)
        self._call("exam_answer", question_id=grid.id, nav="stay",
                   selected_option_ids=[r.option_line_ids[0].id
                                        for r in rows])
        self.assertEqual(unanswered()[grid.id], 0)
