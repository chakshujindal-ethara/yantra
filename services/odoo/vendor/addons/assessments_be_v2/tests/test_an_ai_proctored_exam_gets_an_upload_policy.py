# -*- coding: utf-8 -*-
"""With AI proctoring on, `/begin` and `/state` hand the runner an upload policy
for THIS attempt's camera snapshots, and nothing else.

The app uploads a JPEG straight to S3 each time an AI rule fires (no face, a
phone in view, ...). The policy is the only thing scoping that upload, so the
tests pin: present only while the rule (and the webcam it needs) is on and the
attempt is open; the prefix is this attempt's own; and the exam call still
answers 200 without it when storage is not configured.

S3 is stubbed the way `test_a_browser_upload_is_scoped_to_its_prefix` does.
"""
import json
from datetime import timedelta
from unittest.mock import MagicMock, patch
from uuid import uuid4

import psycopg2

from odoo import fields
from odoo.exceptions import ValidationError
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import candidate as candidate_api
from ..controllers.api import common as api_common
from ..services import evidence, s3_service

_SECRET = "s" * 40


@tagged("-at_install", "post_install")
class TestAnAiProctoredExamGetsAnUploadPolicy(TransactionCase):

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()
        self.icp.set_param("assessments_be_v2.s3_bucket", "module-bucket")
        self.icp.set_param("assessments_be_v2.s3_region", "ap-south-1")
        self.icp.set_param("assessments_be_v2.s3_access_key_id", "AKIATESTKEY000000000")
        self.icp.set_param("assessments_be_v2.s3_secret_key", _SECRET)
        self.icp.set_param("assessments_be_v2.s3_folder", "etp_assessment")
        self.cli = MagicMock()
        self.cli.generate_presigned_post.return_value = {
            "url": "https://module-bucket.s3.ap-south-1.amazonaws.com/",
            "fields": {"key": "k", "policy": "p"}}
        for name, value in (("_connector", None), ("_client", self.cli)):
            stub = patch.object(s3_service, name, return_value=value)
            stub.start()
            self.addCleanup(stub.stop)

        self.controller = candidate_api.EtpAssessmentApiCandidate()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "AI %s" % uuid4().hex[:6]})
        self.questions = self.env["assessments.be.question"].create([{
            "name": "Q%s" % n, "question_type": "subjective_rubric",
            "prompt": "Explain", "difficulty": "easy",
            "generator_id": generator.id,
        } for n in (1, 2)])
        self.question = self.questions[0]
        self.paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, self.questions.ids)], "question_limit": 2,
            "duration_minutes": 30, "state": "in_progress",
            "rule_webcam": True, "rule_ai_proctor": True,
        })
        self.evaluator = self._attempt("Watched")
        self.other = self._attempt("Neighbour")
        self.user = self.evaluator.sudo()._candidate_user()

    def _attempt(self, name):
        applicant = self.env["hr.applicant"].create({
            "partner_name": name,
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id,
            "question_order": json.dumps(self.questions.ids),
            "access_token": uuid4().hex,
        })
        self.paper.sudo()._ensure_candidate_user(applicant)
        return evaluator

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
        self.assertEqual(out.get("__status", 200), 200, out)
        return out["data"]

    def _expires_in(self):
        return self.cli.generate_presigned_post.call_args.kwargs["ExpiresIn"]

    # -- the rule is on -------------------------------------------------

    def test_begin_and_state_carry_this_attempts_policy(self):
        state = self._call("exam_state")
        self.assertEqual(state["outcome"], "instructions", state)
        self.assertTrue(state["assessment"]["rules"]["ai_proctor"])
        # Not started: the paper's 30 min + 60 min.
        self.assertEqual(self._expires_in(), 90 * 60)

        begun = self._call("exam_begin")
        # Started: until the deadline (30 min away) + 30 min.
        self.assertAlmostEqual(self._expires_in(), 60 * 60, delta=5)
        question = self._call("exam_state")
        self.assertEqual(question["outcome"], "question", question)
        # `/answer` serves the next question through the same path, so the
        # policy is refreshed on every move (an untimed paper's would lapse).
        answered = self._call("exam_answer", question_id=self.question.id,
                              justification="Because.", nav="next")
        following = answered["next"]
        self.assertEqual(following["question"]["id"], self.questions[1].id,
                         following)

        prefix = "etp_assessment/proctoring/%s/%s/" % (
            self.env.cr.dbname, self.evaluator.id)
        for payload in (state, begun, question, following):
            policy = payload["evidence_upload"]
            self.assertEqual(set(policy), {"url", "fields", "prefix",
                                           "expires_at", "max_bytes",
                                           "content_type"})
            self.assertEqual(policy["prefix"], prefix)
            self.assertTrue(policy["prefix"].endswith(
                "/%s/" % self.evaluator.id))
            self.assertNotIn("/%s/" % self.other.id, policy["prefix"])
            self.assertEqual(policy["max_bytes"], 400000)
            self.assertEqual(policy["content_type"], "image/jpeg")
            text = json.dumps(payload)
            self.assertNotIn(_SECRET, text)
            self.assertNotIn(self.paper.seb_quit_password, text)
        kwargs = self.cli.generate_presigned_post.call_args.kwargs
        self.assertIn(["starts-with", "$key", prefix], kwargs["Conditions"])
        self.assertIn(["content-length-range", 0, 400000], kwargs["Conditions"])

    def test_a_managers_preview_gets_no_policy(self):
        out = self.controller._with_evidence_upload(
            {"outcome": "question"}, self.evaluator, preview=True)
        self.assertNotIn("evidence_upload", out)

    def test_a_late_policy_never_expires_inside_a_minute(self):
        self.evaluator.started_at = fields.Datetime.now() - timedelta(hours=2)
        evidence.upload_policy(self.evaluator)
        self.assertEqual(self._expires_in(), 60)

    # -- the rule is off, or cannot apply -------------------------------

    def test_rule_off_sends_no_policy(self):
        self.paper.rule_ai_proctor = False
        state = self._call("exam_state")
        begun = self._call("exam_begin")
        for payload in (state, begun):
            self.assertNotIn("evidence_upload", payload)
        self.assertFalse(state["assessment"]["rules"]["ai_proctor"])
        self.cli.generate_presigned_post.assert_not_called()

    def test_ai_proctoring_needs_the_webcam(self):
        with self.assertRaises(ValidationError), self.cr.savepoint():
            self.paper.write({"rule_webcam": False})
        with self.assertRaises(ValidationError), self.cr.savepoint():
            self.env["assessments.be"].create({
                "name": "No camera %s" % uuid4().hex[:6],
                "generator_id": self.paper.generator_id.id,
                "rule_webcam": False, "rule_ai_proctor": True,
            })

    def _closed_gets_no_policy(self, values):
        self._call("exam_begin")
        self.cli.generate_presigned_post.reset_mock()
        self.evaluator.write(values)
        state = self._call("exam_state")
        self.assertEqual(state["outcome"], "complete", state)
        self.assertNotIn("evidence_upload", state)
        self.assertIsNone(evidence.upload_policy(self.evaluator))
        self.cli.generate_presigned_post.assert_not_called()

    def test_a_locked_attempt_gets_no_policy(self):
        self._closed_gets_no_policy({"is_locked": True})

    def test_a_submitted_attempt_gets_no_policy(self):
        self._closed_gets_no_policy({"state": "submitted"})

    def test_no_storage_omits_the_key_and_the_exam_goes_on(self):
        for key in ("assessments_be_v2.s3_bucket",
                    "assessments_be_v2.s3_access_key_id",
                    "assessments_be_v2.s3_secret_key"):
            self.icp.set_param(key, "")
        with self.assertLogs(s3_service._logger, "WARNING"):
            state = self._call("exam_state")
        with self.assertLogs(s3_service._logger, "WARNING"):
            begun = self._call("exam_begin")
        self.assertEqual(state["outcome"], "instructions")
        self.assertEqual(begun["outcome"], "question")
        for payload in (state, begun):
            self.assertNotIn("evidence_upload", payload)

    def test_a_signing_failure_never_fails_the_exam(self):
        self.cli.generate_presigned_post.side_effect = RuntimeError("boom")
        with self.assertLogs(evidence._logger, "WARNING"):
            begun = self._call("exam_begin")
        self.assertEqual(begun["outcome"], "question")
        self.assertNotIn("evidence_upload", begun)

    def test_a_database_error_is_not_swallowed_as_a_signing_failure(self):
        """A broken transaction must reach Odoo's retry, as in `purge_evidence`,
        not be logged away so the exam carries on in an aborted cursor."""
        self.cli.generate_presigned_post.side_effect = psycopg2.OperationalError(
            "db gone")
        with self.assertRaises(psycopg2.Error):
            evidence.upload_policy(self.evaluator)
