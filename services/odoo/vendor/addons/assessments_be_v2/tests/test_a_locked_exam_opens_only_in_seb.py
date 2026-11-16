# -*- coding: utf-8 -*-
"""Locked mode: with "Require Safe Exam Browser" on, the paper opens only there.

Manager's ask, 2026-09-30 (ETP_PLANS_AND_STRATEGY.md Part 11): on campus
drives nothing else on the computer may work while the paper is open. A web
page cannot do that, Safe Exam Browser (SEB) can. The server is the gate: any
browser that cannot show SEB's hash of this attempt's Config Key gets the
`seb_required` outcome and no questions, and every write answers 403.
"""
import hashlib
import json
import plistlib
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import ValidationError
from odoo.http import Response
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import candidate as candidate_api
from ..controllers.api import common as api_common
from ..controllers.api import serializers as S
from ..services import seb


@tagged("-at_install", "post_install")
class TestALockedExamOpensOnlyInSeb(TransactionCase):

    def setUp(self):
        super().setUp()
        self.controller = candidate_api.EtpAssessmentApiCandidate()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "SEB %s" % uuid4().hex[:6]})
        self.question = self.env["assessments.be.question"].create({
            "name": "Q", "question_type": "subjective_rubric",
            "prompt": "Explain", "difficulty": "easy",
            "generator_id": generator.id,
        })
        self.paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, self.question.ids)], "question_limit": 1,
            "duration_minutes": 30, "state": "in_progress",
            "rule_require_seb": True,
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Locked In",
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id,
            "question_order": json.dumps(self.question.ids),
            "access_token": uuid4().hex,
        })
        self.paper.sudo()._ensure_candidate_user(applicant)
        self.user = self.evaluator.sudo()._candidate_user()

    def _proof(self):
        """What SEB's `SafeExamBrowser.security.configKey` holds on the page
        it opened: SHA-256(start page + Config Key)."""
        url = self.evaluator.candidate_link
        key = seb.config_key(seb.settings(self.evaluator))
        return {"seb_url": url,
                "seb_key": hashlib.sha256((url + key).encode()).hexdigest()}

    def _call(self, route, user=None, **params):
        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

            # The .seb route is `type="http"`: Odoo's wrapper accepts only a
            # real Response from it.
            def make_response(self, data, headers=None, status=200):
                return Response(data, headers=headers, status=status)

            def not_found(self):
                return Response(status=404)

        fake = _Req(self.env(user=user or self.user), params)
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            return getattr(self.controller, route)(
                self.evaluator.access_token, **params)

    def test_seb_json_follows_the_published_rules(self):
        """originatorVersion and empty dicts dropped, keys case-insensitively
        sorted at every depth, data as Base64, backslashes left single. The
        backslash rule is the one Moodle's Mac vector fails without."""
        sample = {"originatorVersion": "SEB_x", "zeta": 1, "Alpha": True,
                  "beta": {"Y": b"\x01\x02", "x": "ws:\\h"}, "empty": {},
                  "list": [{"b": 2, "A": 1}]}
        self.assertEqual(
            seb.seb_json(sample),
            '{"Alpha":true,"beta":{"x":"ws:\\h","Y":"AQI="},'
            '"list":[{"A":1,"b":2}],"zeta":1}')

    def test_outside_seb_there_is_only_the_gate(self):
        public = self.env.ref("base.public_user")
        for who in (public, self.user):
            out = self._call("exam_state", user=who)
            data = out["data"]
            self.assertEqual(data["outcome"], "seb_required", (who, out))
            self.assertNotIn("assessment", data)
            self.assertNotIn("question", data)
            self.assertTrue(data["seb"]["launch_url"].startswith("seb"))
            self.assertTrue(data["seb"]["launch_url"].endswith(
                "/api/v1/exam/%s/seb-config" % self.evaluator.access_token))
            self.assertEqual(data["seb"]["download_url"], seb.DOWNLOAD_URL)

        begun = self._call("exam_begin")
        self.assertEqual((begun["__status"], begun["error"]["code"]),
                         (403, "seb_required"))
        self.assertFalse(self.evaluator.started_at)

    def test_a_wrong_proof_is_the_same_as_none(self):
        proof = self._proof()
        other_page = dict(proof, seb_url=proof["seb_url"].replace(
            self.evaluator.access_token, uuid4().hex))
        for bad in (dict(proof, seb_key="0" * 64), other_page,
                    {"seb_url": proof["seb_url"]}):
            out = self._call("exam_state", **bad)
            self.assertEqual(out["data"]["outcome"], "seb_required", bad)

    def test_inside_seb_the_paper_runs_and_ends_as_before(self):
        proof = self._proof()
        state = self._call("exam_state", **proof)["data"]
        self.assertEqual(state["outcome"], "instructions", state)
        self.assertTrue(state["assessment"]["rules"]["seb"])
        self.assertEqual(state["seb"]["quit_url"],
                         self.evaluator.candidate_link + "/quit")

        begun = self._call("exam_begin", **proof)
        self.assertNotIn("error", begun, begun)
        saved = self._call("exam_answer", question_id=self.question.id,
                           justification="Inside SEB", nav="stay", **proof)
        self.assertTrue(saved["data"]["saved"], saved)
        done = self._call("exam_submit", **proof)
        self.assertTrue(done["data"]["submitted"], done)

        # The result screen is not locked: it opens in any browser.
        after = self._call("exam_state")["data"]
        self.assertEqual(after["outcome"], "complete", after)

    def test_rule_off_changes_nothing(self):
        self.paper.rule_require_seb = False
        state = self._call("exam_state")["data"]
        self.assertEqual(state["outcome"], "instructions", state)
        self.assertNotIn("seb", state)
        self.assertFalse(state["assessment"]["rules"]["seb"])
        self.assertEqual(self._call("exam_seb_config").status_code, 404)

    def test_the_seb_file_is_what_the_gate_checks(self):
        """SEB computes its Config Key from the file it downloaded; the gate
        from `seb.settings`. They must be one Config Key."""
        out = self._call("exam_seb_config",
                         user=self.env.ref("base.public_user"))
        self.assertEqual(out.headers["Content-Type"], "application/seb")
        served = plistlib.loads(out.data)
        self.assertEqual(served["startURL"], self.evaluator.candidate_link)
        self.assertEqual(
            served["hashedQuitPassword"],
            hashlib.sha256(self.paper.seb_quit_password.encode()).hexdigest())
        self.assertEqual(seb.config_key(served),
                         seb.config_key(seb.settings(self.evaluator)))

    def test_the_quit_password_is_for_invigilators_only(self):
        password = self.paper.seb_quit_password
        self.assertRegex(
            password, r"^[0-9a-hjkmnp-tv-z]{4}(-[0-9a-hjkmnp-tv-z]{4}){3}$")
        admin = self.env.ref("base.user_admin")
        self.assertEqual(S.assessment_detail(
            self.paper.with_user(admin))["seb_quit_password"], password)
        proof = self._proof()
        seen = [self._call("exam_state", **proof),
                self._call("exam_begin", **proof),
                self._call("exam_seb_config").data.decode()]
        self.assertNotIn(password, json.dumps(seen[:2]) + seen[2])

    def test_locked_mode_needs_a_quit_password(self):
        copy = self.paper.copy()
        self.assertTrue(copy.seb_quit_password)
        self.assertNotEqual(copy.seb_quit_password, self.paper.seb_quit_password)
        with self.assertRaises(ValidationError), self.cr.savepoint():
            self.paper.write({"seb_quit_password": ""})
