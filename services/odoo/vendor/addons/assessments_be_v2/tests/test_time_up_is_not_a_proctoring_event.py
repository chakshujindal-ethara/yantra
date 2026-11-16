# -*- coding: utf-8 -*-
"""What reaches the exam routes after the deadline.

MT3-01. Time-up puts the runner behind its overlay, and leaving fullscreen or
the tab then beaconed `/violation`, which counted it and settled the paper as
auto_submit_reason='violation' with "[Auto-submitted: proctoring violation]"
blanks: a candidate who only ran out of time, recorded as a proctoring
auto-submit. Past the deadline the violation route now settles the expiry and
answers exactly as `/answer` does (409 `time_expired`), counting nothing.

MT3-02. `/answer` saved whatever arrived after the deadline, however late, so
text typed behind the overlay was stored. The in-flight answer is now kept only
within `ANSWER_GRACE_SECONDS`; later than that it is refused, not stored.

Because the runner counts down on the DEVICE clock, a device running slow
would now lose its last answer. Every candidate payload that carries the
`deadline` also carries the server's `server_now`, so the client can offset.
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
class TestTimeUpIsNotAProctoringEvent(TransactionCase):

    def setUp(self):
        super().setUp()
        self.controller = candidate_api.EtpAssessmentApiCandidate()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Time-up %s" % uuid4().hex[:6]})

    def _sitting(self, late_seconds):
        """An attempt whose 60-minute deadline passed `late_seconds` ago
        (negative: still to come)."""
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric", "prompt": "Explain",
            "difficulty": "easy", "generator_id": self.generator.id,
        })
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)], "question_limit": 1,
            "duration_minutes": 60, "state": "in_progress",
            "violation_action": "auto_submit", "max_violations": 0,
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Late Sitter",
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id, "applicant_id": applicant.id,
            "question_order": json.dumps(question.ids),
            "access_token": uuid4().hex, "state": "in_progress",
            "started_at": fields.Datetime.now()
            - timedelta(minutes=60, seconds=late_seconds),
        })
        assessment.sudo()._ensure_candidate_user(applicant)
        user = evaluator.sudo()._candidate_user()
        self.assertEqual(evaluator.is_time_expired(), late_seconds > 0)
        return evaluator, question, user

    def _call(self, route, evaluator, user, **params):
        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(self.env(user=user), params)
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            return getattr(self.controller, route)(
                evaluator.access_token, **params)

    def _answer(self, evaluator, question, user, text):
        return self._call("exam_answer", evaluator, user,
                          question_id=question.id, justification=text,
                          nav="stay")

    def test_a_violation_after_the_deadline_is_an_expiry(self):
        evaluator, question, user = self._sitting(late_seconds=60)
        out = self._call("exam_violation", evaluator, user,
                         reason="fullscreen_exit")
        evaluator.invalidate_recordset()

        self.assertEqual(out["__status"], 409, out)
        self.assertEqual(out["error"]["code"], "time_expired")
        self.assertEqual(evaluator.auto_submit_reason, "expired")
        self.assertEqual(evaluator.violation_count, 0,
                         "running out of time was counted as a violation")
        self.assertTrue(evaluator.is_locked)

        other, other_q, other_user = self._sitting(late_seconds=5)
        answered = self._answer(other, other_q, other_user, "In time")
        self.assertEqual(sorted(out), sorted(answered),
                         "the two routes must answer time-up the same way")

    def test_a_violation_inside_the_grace_leaves_the_last_answer_room(self):
        # The runner's clock trails the server's, so a tab switch can land
        # just past the deadline while an autosave is pending. Settling here
        # would lock the paper and `/answer` would refuse that last text.
        evaluator, question, user = self._sitting(late_seconds=3)
        out = self._call("exam_violation", evaluator, user,
                         reason="fullscreen_exit")
        evaluator.invalidate_recordset()
        self.assertEqual((out["__status"], out["error"]["code"]),
                         (409, "time_expired"), out)
        self.assertEqual(evaluator.violation_count, 0)
        self.assertFalse(evaluator.is_locked, "settled inside the grace")

        typed = "Typed just before the deadline"
        out = self._answer(evaluator, question, user, typed)
        self.assertTrue(out["answer_saved"], out)
        self.assertEqual(evaluator.response_ids.justification, typed)
        self.assertEqual(evaluator.auto_submit_reason, "expired")

    def test_an_answer_is_kept_only_within_the_grace(self):
        typed = "Typed as the clock ran out"
        evaluator, question, user = self._sitting(late_seconds=3)
        out = self._answer(evaluator, question, user, typed)
        self.assertEqual((out["__status"], out["error"]["code"]),
                         (409, "time_expired"), out)
        self.assertTrue(out["answer_saved"])
        self.assertEqual(evaluator.response_ids.justification, typed)

        typed = "Typed behind the time-up overlay"
        evaluator, question, user = self._sitting(late_seconds=60)
        out = self._answer(evaluator, question, user, typed)
        self.assertEqual((out["__status"], out["error"]["code"]),
                         (409, "time_expired"), out)
        self.assertFalse(out["answer_saved"])
        self.assertNotIn(typed, evaluator.response_ids.mapped("justification"))
        self.assertEqual(evaluator.auto_submit_reason, "expired")

    def test_every_deadline_travels_with_the_server_clock(self):
        evaluator, _question, user = self._sitting(late_seconds=-600)
        stamps = {
            "state": self._call("exam_state", evaluator, user)["data"]
            ["attempt"],
            "review": self._call("exam_review", evaluator, user)["data"],
            "my_assessments": S.attempt(evaluator),
        }
        for where, block in stamps.items():
            self.assertTrue(block.get("deadline"), where)
            now = block.get("server_now") or ""
            self.assertRegex(now, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$",
                             "%s: not the deadline's format" % where)
            skew = abs((fields.Datetime.from_string(now.rstrip("Z").replace(
                "T", " ")) - fields.Datetime.now()).total_seconds())
            self.assertLess(skew, 5, where)

    def test_the_violation_reply_carries_the_breach_label(self):
        """Log only, limit 1: the first violation breaches it, and the reply
        says so while the paper goes on (A-074)."""
        evaluator, _question, user = self._sitting(late_seconds=-600)
        evaluator.assessment_id.write(
            {"violation_action": "log_only", "max_violations": 1})
        out = self._call("exam_violation", evaluator, user,
                         reason="tab_switch")
        self.assertTrue(out.get("ok"), out)
        self.assertTrue(out["data"]["violation_limit_breached"])
        self.assertFalse(out["data"]["attempt_ended"])


@tagged("-at_install", "post_install")
class TestAReportSentAgainCountsOnce(TransactionCase):
    """BR-D15 review, P2-2: the client keeps a report it got no reply to and
    sends it again, with its own stamp (`at`). The POST may have landed and
    only the reply been lost, so the server must count the SAME stamp once -
    and only an EXACT repeat: a huge stamp must not silence a later report.
    No stamp (an older client) is today's behaviour."""

    _sitting = TestTimeUpIsNotAProctoringEvent._sitting
    _call = TestTimeUpIsNotAProctoringEvent._call

    def setUp(self):
        super().setUp()
        self.controller = candidate_api.EtpAssessmentApiCandidate()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Resend %s" % uuid4().hex[:6]})

    def _later(self, evaluator):
        """The resend comes seconds later, past the 1.2s same-reason burst
        fold - which would otherwise pass these tests on its own."""
        evaluator.sudo().write({"violation_datetime": fields.Datetime.now()
                                - timedelta(seconds=5)})

    def _report(self, evaluator, user, reason, at=None):
        params = {"reason": reason}
        if at is not None:
            params["at"] = at
        out = self._call("exam_violation", evaluator, user, **params)
        self.assertTrue(out.get("ok"), out)
        return out["data"]

    def test_the_same_stamp_counts_once_and_only_an_exact_repeat(self):
        evaluator, _question, user = self._sitting(late_seconds=-600)
        evaluator.assessment_id.write(
            {"violation_action": "log_only", "max_violations": 10})

        first = self._report(evaluator, user, "tab_switch", at=1791442470169)
        self.assertTrue(first["recorded"])
        self.assertEqual(first["violation_count"], 1)
        self._later(evaluator)
        again = self._report(evaluator, user, "tab_switch", at=1791442470169)
        self.assertFalse(again["recorded"], "the reply was lost, not the act")
        self.assertEqual(again["violation_count"], 1)

        # A huge stamp, then a smaller one: both count.
        self.assertEqual(self._report(
            evaluator, user, "phone", at=99999999999999)["violation_count"], 2)
        self.assertEqual(self._report(
            evaluator, user, "second_person", at=1791442470170
        )["violation_count"], 3)

        # No stamp: as before, every distinct report counts.
        self.assertEqual(
            self._report(evaluator, user, "copy")["violation_count"], 4)
        self.assertEqual(
            self._report(evaluator, user, "paste")["violation_count"], 5)
        evaluator.invalidate_recordset(["violation_log"])
        self.assertEqual(
            [e.get("client_at") for e in evaluator.violation_log],
            [1791442470169, 99999999999999, 1791442470170, None, None])

    def test_a_resent_report_does_not_end_a_sitting_twice_over(self):
        """At a cap of 2, the first report and its resend are ONE: the
        sitting goes on."""
        evaluator, _question, user = self._sitting(late_seconds=-600)
        evaluator.assessment_id.write(
            {"violation_action": "auto_submit", "max_violations": 2})
        self._report(evaluator, user, "tab_switch", at=1791442470169)
        self._later(evaluator)
        again = self._report(evaluator, user, "tab_switch", at=1791442470169)
        self.assertFalse(again["attempt_ended"])
        self.assertFalse(evaluator.is_locked)
