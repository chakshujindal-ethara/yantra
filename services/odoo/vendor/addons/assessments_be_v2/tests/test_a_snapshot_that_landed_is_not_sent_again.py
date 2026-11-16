# -*- coding: utf-8 -*-
"""The runner asks `/evidence/landed` before sending a snapshot again.

THE BUG. AI proctoring POSTs each camera snapshot straight to S3. A bucket
with no CORS rule for POST (stage's, and production's, which allows only GET
and HEAD) still STORES the file - a multipart POST is a "simple" request, so
it goes out - but withholds the reply, and the page sees a bare TypeError.
`web/proctor_ai.js` read that as a failure and sent the oldest snapshot again
every 60 s for the rest of the sitting, and kept every snapshot in the
browser's storage, while a snapshot that really failed waited behind it.

THE FIX asks THIS server, which reads S3 itself (`head_object`), as Form
Studio's `/forms/media/complete` already does. The route answers only for
the calling candidate's own attempt and only for a snapshot-shaped key under
that attempt's prefix: it must never become a "does key X exist" oracle.
"""
import json
from unittest.mock import MagicMock, patch
from uuid import uuid4

from botocore.exceptions import ClientError

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import candidate as candidate_api
from ..controllers.api import common as api_common
from ..services import s3_service


def _s3_error(code):
    return ClientError({"Error": {"Code": code, "Message": code}}, "HeadObject")


@tagged("-at_install", "post_install")
class TestASnapshotThatLandedIsNotSentAgain(TransactionCase):

    def setUp(self):
        super().setUp()
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param("assessments_be_v2.s3_bucket", "module-bucket")
        icp.set_param("assessments_be_v2.s3_region", "ap-south-1")
        icp.set_param("assessments_be_v2.s3_access_key_id", "AKIATESTKEY000000000")
        icp.set_param("assessments_be_v2.s3_secret_key", "s" * 40)
        icp.set_param("assessments_be_v2.s3_folder", "etp_assessment")
        self.cli = MagicMock()
        for name, value in (("_connector", None), ("_client", self.cli)):
            stub = patch.object(s3_service, name, return_value=value)
            stub.start()
            self.addCleanup(stub.stop)

        self.controller = candidate_api.EtpAssessmentApiCandidate()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "AI %s" % uuid4().hex[:6]})
        question = self.env["assessments.be.question"].create({
            "name": "Q1", "question_type": "subjective_rubric",
            "prompt": "Explain", "difficulty": "easy",
            "generator_id": generator.id,
        })
        self.paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, question.ids)], "question_limit": 1,
            "duration_minutes": 30, "state": "in_progress",
            "rule_webcam": True, "rule_ai_proctor": True,
        })
        self.evaluator = self._attempt("Watched", question)
        self.other = self._attempt("Neighbour", question)
        self.prefix = "etp_assessment/proctoring/%s/%s/" % (
            self.env.cr.dbname, self.evaluator.id)
        self.key = self.prefix + "1791897539232_phone.jpg"

    def _attempt(self, name, question):
        applicant = self.env["hr.applicant"].create({
            "partner_name": name,
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id,
            "question_order": json.dumps(question.ids),
            "access_token": uuid4().hex,
        })
        self.paper.sudo()._ensure_candidate_user(applicant)
        return evaluator

    def _ask(self, key, token=None, user=None):
        token = token or self.evaluator.access_token
        user = user or self.evaluator.sudo()._candidate_user()

        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(self.env(user=user), {"key": key})
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            out = self.controller.exam_evidence_landed(token, key=key)
        return out.get("__status", 200), out

    def test_a_snapshot_in_s3_has_landed(self):
        status, out = self._ask(self.key)
        self.assertEqual(status, 200, out)
        self.assertIs(out["data"]["landed"], True)
        self.cli.head_object.assert_called_once_with(
            Bucket="module-bucket", Key=self.key)

    def test_a_snapshot_in_flight_at_submit_is_still_confirmed(self):
        # Read-only: a submitted attempt may still ask, or the runner re-sends
        # the snapshot until its upload policy expires.
        self.evaluator.is_locked = True
        status, out = self._ask(self.key)
        self.assertEqual(status, 200, out)
        self.assertIs(out["data"]["landed"], True)

    def test_with_no_storage_configured_nothing_has_landed(self):
        with patch.object(s3_service, "storage_target",
                          return_value=(None, "")):
            status, out = self._ask(self.key)
        self.assertEqual(status, 200, out)
        self.assertIs(out["data"]["landed"], False)
        self.cli.head_object.assert_not_called()

    def test_a_snapshot_s3_does_not_have_has_not_landed(self):
        self.cli.head_object.side_effect = _s3_error("404")
        status, out = self._ask(self.key)
        self.assertEqual(status, 200, out)
        self.assertIs(out["data"]["landed"], False)

    def test_an_s3_fault_is_not_an_answer(self):
        self.cli.head_object.side_effect = _s3_error("InternalError")
        status, out = self._ask(self.key)
        self.assertEqual(status, 502, out)

    def test_only_this_attempts_own_snapshot_keys_are_checked(self):
        other_prefix = "etp_assessment/proctoring/%s/%s/" % (
            self.env.cr.dbname, self.other.id)
        for key in (
                other_prefix + "1791897539232_phone.jpg",  # a neighbour's
                self.prefix + "../%s/1_phone.jpg" % self.other.id,
                self.prefix + "sub/1791897539232_phone.jpg",
                self.prefix + "1791897539232_phone.png",
                self.prefix + "notes.txt",
                self.prefix,
                "form_studio/%s/a.mp4" % ("0" * 32),
                ""):
            status, out = self._ask(key)
            self.assertEqual(status, 400, (key, out))
        self.cli.head_object.assert_not_called()

    def test_only_the_assigned_candidate_may_ask(self):
        neighbour = self.other.sudo()._candidate_user()
        status, out = self._ask(self.key, user=neighbour)
        self.assertEqual(status, 403, out)
        self.cli.head_object.assert_not_called()

    def test_an_unknown_link_is_refused(self):
        status, out = self._ask(self.key, token=uuid4().hex)
        self.assertEqual(status, 404, out)
        self.cli.head_object.assert_not_called()
