# -*- coding: utf-8 -*-
"""The eye-movement pilot (`rule_gaze_review`) is switched off for good.

On stage four sittings reported eye tracking running and not one review flag
was ever recorded, so the owner removed it (19 Oct). The field, the old
`review_flags` and the `running_gaze`/`gaze_failed` statuses stay for the rows
that hold them. What is pinned here: no exam is told to run eye tracking, even
on a paper still saved with the switch on, so an old cached app never loads the
eye model; `/review-flag` records nothing; the API cannot turn it back on; AI
proctoring still turns off on such a paper; the back-office form no longer
shows it; and the old flags still erase and still read on the admin side
(`flagged_only` untouched).
"""
import json
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ..controllers.api import candidate as candidate_api
from ..controllers.api import common as api_common
from ..controllers.api import serializers as S
from ..controllers.api import write as write_api
from ..services import evidence
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"
LOOK = "Looking away from the screen"


@tagged("-at_install", "post_install")
class TestEyeMovementIsOff(TransactionCase):

    def setUp(self):
        super().setUp()
        purge = patch.object(evidence, "purge_evidence")
        purge.start()
        self.addCleanup(purge.stop)
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Gaze %s" % uuid4().hex[:6]})
        # A paper saved while the pilot was live, switch still on.
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric", "prompt": "Explain",
            "difficulty": "easy", "generator_id": self.generator.id,
        })
        self.paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)], "question_limit": 1,
            "duration_minutes": 60, "state": "in_progress",
            "violation_action": "auto_submit", "max_violations": 1,
            "rule_webcam": True, "rule_ai_proctor": True,
            "rule_gaze_review": True,
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Gaze Sitter",
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        self.ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id,
            "question_order": json.dumps(question.ids),
            "access_token": uuid4().hex, "state": "in_progress",
            "started_at": fields.Datetime.now() - timedelta(minutes=5),
        })
        self.paper.sudo()._ensure_candidate_user(applicant)
        self.user = self.ev.sudo()._candidate_user()

    def _as_admin(self):
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]

    def _write(self, method, path=None, **body):
        return call_route(write_api, write_api.EtpAssessmentApiWrite(),
                          method, self.env, path=path, **body)

    def test_no_exam_is_told_to_run_eye_tracking(self):
        self.assertTrue(self.paper.rule_gaze_review)
        rules = S.exam_state_envelope("in_progress", self.ev)[
            "assessment"]["rules"]
        self.assertIs(rules["gaze_review"], False,
                      "an old app would load the eye model")
        self.assertIs(rules["ai_proctor"], True, "AI proctoring went too")
        self.assertIs(S.proctoring_rules(self.paper)["gaze_review"], False)

    def test_a_review_flag_is_refused_and_records_nothing(self):
        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(self.env(user=self.user), {"reason": LOOK})
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            out = candidate_api.EtpAssessmentApiCandidate().exam_review_flag(
                self.ev.access_token)
        self.ev.invalidate_recordset()
        self.assertEqual(status_of(out), 409, out)
        self.assertEqual(out["error"]["code"], "gaze_review_off")
        self.assertFalse(self.ev.review_flags)
        self.assertEqual(self.ev.violation_count, 0)
        self.assertEqual(self.ev.state, "in_progress")

    def test_the_api_cannot_turn_it_on(self):
        self._as_admin()
        made = self._write("assessment_create", name="New %s" % uuid4().hex[:4],
                           generator_id=self.generator.id, rule_webcam=True,
                           rule_ai_proctor=True, rule_gaze_review=True)
        self.assertEqual(status_of(made), 200, made)
        fresh = self.env["assessments.be"].browse(made["data"]["id"])
        self.assertTrue(fresh.rule_ai_proctor)
        self.assertFalse(fresh.rule_gaze_review)

        out = self._write("assessment_update", path={"assessment_id": fresh.id},
                          rule_gaze_review=True)
        self.assertEqual(status_of(out), 200, out)
        self.assertFalse(fresh.rule_gaze_review)

    def test_ai_proctoring_turns_off_on_a_paper_saved_with_it_on(self):
        self._as_admin()
        out = self._write("assessment_update",
                          path={"assessment_id": self.paper.id},
                          rule_ai_proctor=False)
        self.assertEqual(status_of(out), 200, out)
        self.assertFalse(self.paper.rule_ai_proctor)

        self.paper.write({"rule_ai_proctor": True})
        self.paper.write({"rule_webcam": False, "rule_ai_proctor": False})
        self.assertEqual((self.paper.rule_webcam, self.paper.rule_ai_proctor),
                         (False, False))

    def test_the_back_office_form_does_not_show_it(self):
        arch = self.env["assessments.be"].get_view(view_type="form")["arch"]
        self.assertIn('name="rule_ai_proctor"', arch)
        self.assertNotIn('name="rule_gaze_review"', arch)

    def _old_flags(self):
        at = fields.Datetime.to_string(
            fields.Datetime.now() - timedelta(minutes=1))
        self.ev.sudo().write({"review_flags": [
            {"reason": LOOK, "at": at}, {"reason": "Other", "at": at}]})

    def test_erase_clears_old_flags(self):
        self._old_flags()
        self.ev._anonymize_pii()
        # An empty Json list is stored as NULL, so it reads back False.
        self.assertFalse(self.ev.review_flags)
        self.assertEqual(S.evaluator_admin_row(self.ev)["review_flag_count"], 0)

    def test_old_flags_still_read_on_the_admin_side_only(self):
        self._old_flags()
        row = S.evaluator_admin_row(self.ev)
        self.assertEqual(row["review_flag_count"], 2)
        self.assertEqual(row["flags"]["review_flags"], 2)
        self.assertEqual(row["flags"]["violation_count"], 0)

        self._as_admin()
        admin = api_admin.EtpAssessmentApiAdmin()
        out = call_route(api_admin, admin, "attempt_detail", self.env,
                         path={"evaluator_id": self.ev.id})
        self.assertEqual(status_of(out), 200, out)
        self.assertEqual([f["reason"] for f in out["data"]["review_flags"]],
                         [LOOK, "Other"])

        # `flagged_only` still selects the three machine signals only.
        domain = call_route(api_admin, admin, "_attempt_filters", self.env,
                            flagged_only=True)
        self.assertFalse(self.env["assessments.be.evaluator"].search(
            domain + [("id", "=", self.ev.id)]),
            "a review flag put the attempt in the flagged_only queue")
