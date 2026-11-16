# -*- coding: utf-8 -*-
"""R5 over the wire: each violation kind is held to its own limit and mode.

The model counts an "AI: " reason apart (`test_ai_violations_count_apart`).
Here, the routes: `/violation` ends or labels a sitting by the paper's AI pair
for an AI reason and by the regular pair for any other, stamping
`ai_violation` or `violation`; every payload that shows the regular policy and
count shows the AI ones beside it; the write API takes the AI pair (and the two
other 14 Oct settings) before and after launch; the results export carries the
AI count apart.
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
from ..controllers.api import write as write_api
from ..services import evidence, export
from ._paging_harness import call_route, status_of

ADMIN_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class TestAiViolationsFollowTheirOwnPolicy(TransactionCase):

    def setUp(self):
        super().setUp()
        purge = patch.object(evidence, "purge_evidence")
        purge.start()
        self.addCleanup(purge.stop)
        self.env.user.group_ids = [(4, self.env.ref(ADMIN_GROUP).id)]
        self.controller = candidate_api.EtpAssessmentApiCandidate()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "AI policy %s" % uuid4().hex[:6]})

    def _sitting(self, **policy):
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric", "prompt": "Explain",
            "difficulty": "easy", "generator_id": self.generator.id,
        })
        paper = self.env["assessments.be"].create(dict({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)], "question_limit": 1,
            "duration_minutes": 60, "state": "in_progress",
            "rule_webcam": True, "rule_ai_proctor": True,
        }, **policy))
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Policy Sitter",
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id,
            "question_order": json.dumps(question.ids),
            "access_token": uuid4().hex, "state": "in_progress",
            "started_at": fields.Datetime.now() - timedelta(minutes=5),
        })
        paper.sudo()._ensure_candidate_user(applicant)
        return evaluator, evaluator.sudo()._candidate_user()

    def _violate(self, evaluator, user, reason):
        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(self.env(user=user), {"reason": reason})
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            out = self.controller.exam_violation(evaluator.access_token)
        evaluator.invalidate_recordset()
        self.assertEqual(out.get("__status", 200), 200, out)
        return out["data"]

    # -- each kind ends the sitting by its own pair -------------------------

    def test_an_ai_limit_ends_the_paper_while_the_regular_mode_is_log_only(
            self):
        ev, user = self._sitting(
            violation_action="log_only", max_violations=1,
            ai_violation_action="auto_submit", ai_max_violations=2)

        first = self._violate(ev, user, "AI: No face in view")
        self.assertFalse(first["attempt_ended"])
        second = self._violate(ev, user, "AI: Phone in view")

        self.assertTrue(second["attempt_ended"], second)
        self.assertTrue(ev.is_locked)
        self.assertEqual(ev.auto_submit_reason, "ai_violation")
        self.assertEqual((ev.violation_count, ev.ai_violation_count), (0, 2))

    def test_a_regular_limit_ends_the_paper_while_the_ai_mode_is_log_only(
            self):
        ev, user = self._sitting(
            violation_action="auto_submit", max_violations=2,
            ai_violation_action="log_only", ai_max_violations=1)

        for reason in ("AI: No face in view", "AI: Phone in view",
                       "AI: More than one face in view"):
            self.assertFalse(self._violate(ev, user, reason)["attempt_ended"],
                             "an AI violation under Log only ended the paper")
        self.assertTrue(ev.ai_violation_limit_breached)
        self.assertFalse(self._violate(ev, user, "tab-switch")["attempt_ended"])
        ended = self._violate(ev, user, "copy-paste")

        self.assertTrue(ended["attempt_ended"], ended)
        self.assertEqual(ev.auto_submit_reason, "violation")
        self.assertEqual((ev.violation_count, ev.ai_violation_count), (2, 3))

    def test_an_ai_reason_on_a_paper_without_ai_is_a_regular_violation(
            self):
        """With AI proctoring off no AI rule is watching, so an "AI: " reason
        is a tampered or stale client - held to the regular cap, which it
        could otherwise dodge."""
        ev, user = self._sitting(
            rule_ai_proctor=False, violation_action="auto_submit",
            max_violations=2, ai_violation_action="log_only",
            ai_max_violations=5)

        self.assertFalse(self._violate(ev, user, "AI: No face in view")
                         ["attempt_ended"])
        ended = self._violate(ev, user, "AI: Phone in view")

        self.assertTrue(ended["attempt_ended"], ended)
        self.assertEqual(ev.auto_submit_reason, "violation")
        self.assertEqual((ev.violation_count, ev.ai_violation_count), (2, 0))
        self.assertFalse(ev.ai_violation_log)

    def test_the_reply_carries_both_kinds(self):
        ev, user = self._sitting(
            violation_action="log_only", max_violations=4,
            ai_violation_action="log_only", ai_max_violations=1)
        reply = self._violate(ev, user, "AI: No face in view")

        self.assertEqual(
            {k: reply[k] for k in (
                "violation_count", "max_violations", "violation_action",
                "violation_limit_breached", "ai_violation_count",
                "ai_max_violations", "ai_violation_action",
                "ai_violation_limit_breached")},
            {"violation_count": 0, "max_violations": 4,
             "violation_action": "log_only", "violation_limit_breached": False,
             "ai_violation_count": 1, "ai_max_violations": 1,
             "ai_violation_action": "log_only",
             "ai_violation_limit_breached": True})

    def test_an_empty_ai_mode_is_log_only(self):
        """A paper an old pod created after -u has no AI mode (the column is
        nullable for that rolling deploy): it logs, labels, never ends."""
        ev, user = self._sitting(ai_violation_action=False,
                                 ai_max_violations=1)
        self.assertFalse(ev.assessment_id.ai_violation_action)
        for reason in ("AI: No face in view", "AI: Phone in view"):
            reply = self._violate(ev, user, reason)
            self.assertFalse(reply["attempt_ended"], reply)
        self.assertEqual(reply["ai_violation_action"], "log_only")
        self.assertTrue(ev.ai_violation_limit_breached)
        self.assertFalse(ev.is_locked)
        self.assertEqual(
            S.proctoring_rules(ev.assessment_id, ev)["ai_violation_action"],
            "log_only")
        self.assertEqual(
            S.assessment_detail(ev.assessment_id)["ai_violation_action"],
            "log_only")
        self.assertEqual(S.exam_state_envelope("question", ev)[
            "assessment"]["ai_violation_action"], "log_only")

    # -- every payload shows the AI policy and count beside the regular ------

    def test_every_payload_carries_the_ai_policy_and_count(self):
        ev, user = self._sitting(ai_violation_action="auto_submit",
                                 ai_max_violations=3)
        self._violate(ev, user, "AI: No face in view")
        self._violate(ev, user, "tab-switch")
        tally = [{"reason": "AI: No face in view", "count": 1}]

        rules = S.proctoring_rules(ev.assessment_id, ev)
        self.assertEqual(
            (rules["ai_max_violations"], rules["ai_violation_action"],
             rules["ai_violation_count"], rules["violation_count"]),
            (3, "auto_submit", 1, 1))
        envelope = S.exam_state_envelope("question", ev)
        self.assertEqual(
            (envelope["assessment"]["ai_max_violations"],
             envelope["assessment"]["ai_violation_action"],
             envelope["attempt"]["ai_violation_count"],
             envelope["attempt"]["ai_violation_limit_breached"]),
            (3, "auto_submit", 1, False))
        proctoring = S.attempt(ev)["proctoring"]
        self.assertEqual(
            (proctoring["ai_violation_count"],
             proctoring["ai_violation_limit_breached"],
             proctoring["ai_violations"], proctoring["violations"]),
            (1, False, tally, [{"reason": "tab-switch", "count": 1}]))
        detail = S.assessment_detail(ev.assessment_id)
        self.assertEqual(
            (detail["ai_max_violations"], detail["ai_violation_action"]),
            (3, "auto_submit"))
        flags = S.evaluator_admin_row(ev)["flags"]
        self.assertEqual(
            (flags["ai_violation_count"], flags["ai_violation_limit_breached"],
             flags["ai_violations"], flags["violation_count"]),
            (1, False, tally, 1))

    def test_the_export_counts_ai_violations_apart(self):
        ev, user = self._sitting()
        self._violate(ev, user, "AI: No face in view")
        self._violate(ev, user, "AI: Phone in view")
        self._violate(ev, user, "tab-switch")
        row = export.results_rows(ev.assessment_id)[0]

        self.assertEqual(
            (row["violation_count"], row["violation_detail"],
             row["ai_violation_count"], row["ai_violation_detail"]),
            (1, "tab-switch x1", 2,
             "AI: No face in view x1; AI: Phone in view x1"))
        self.assertEqual(export.RESULTS_COLUMNS[-2:],
                         ["ai_violation_count", "ai_violation_detail"],
                         "appended, so a sheet keyed by position still reads")
        self.assertIn("| violations 1 | AI violations 2",
                      export._summary_row(ev)["dimension_detail"])

    # -- the write API ------------------------------------------------------

    def _write(self, route, path=None, **params):
        return call_route(write_api, write_api.EtpAssessmentApiWrite(), route,
                          self.env, path=path, **params)

    def test_the_new_settings_are_written_before_and_after_launch(self):
        ev, _user = self._sitting()
        paper = ev.assessment_id
        out = self._write("assessment_update", path={"assessment_id": paper.id},
                          ai_max_violations=3, ai_violation_action="auto_submit",
                          transcription_threshold=85.0)

        self.assertEqual(status_of(out), 200, out)
        self.assertEqual(
            (paper.ai_max_violations, paper.ai_violation_action,
             paper.transcription_threshold), (3, "auto_submit", 85.0))
        self.assertEqual(out["data"]["transcription_threshold"], 85.0)

        created = self._write("assessment_create", name="Fresh paper",
                              ai_max_violations=None, ai_violation_action="",
                              max_violations=2)
        self.assertEqual(status_of(created), 200, created)
        fresh = self.env["assessments.be"].browse(created["data"]["id"])
        self.assertEqual((fresh.ai_max_violations, fresh.ai_violation_action),
                         (5, "log_only"), "null keeps the field defaults")

        for bad in ({"ai_max_violations": -1},
                    {"ai_violation_action": "explode"}):
            out = self._write("assessment_update",
                              path={"assessment_id": paper.id}, **bad)
            self.assertEqual(status_of(out), 422, (bad, out))
        self.assertEqual((paper.ai_max_violations, paper.ai_violation_action),
                         (3, "auto_submit"))
        # The model's 0-100 check, answered as 422 (a real request rolls the
        # write back; this test cursor cannot, so nothing is read after it).
        out = self._write("assessment_update", path={"assessment_id": paper.id},
                          transcription_threshold=101)
        self.assertEqual(status_of(out), 422, out)
