# -*- coding: utf-8 -*-
"""A lane with several judge calls in flight stores exactly what a serial lane
stores.

WHY THIS EXISTS. One lane graded one candidate at a time and sat idle on each
~20s Vertex call, so a 652-candidate paper took hours at four lanes.
`scoring_parallel_calls` keeps several calls on the wire per lane. The risk is
the one that cost 27% of the 2026-09-03 drain - parallel writers colliding - so
the design keeps a single writer: only the calls leave the lane's cursor. These
tests pin that the marks do not depend on which path graded them, that the calls
really overlapped, and that a quota refusal no longer burns an attempt.
"""
import json
import threading
import time
from unittest.mock import patch
from uuid import uuid4

from odoo import tools
from odoo.tests.common import TransactionCase, tagged

from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc

ANSWERS_EACH = 3


@tagged("-at_install", "post_install")
class TestParallelGradingStoresWhatSerialGradingStores(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        self.score_of = {}
        self.lock = threading.Lock()
        self.in_flight = 0
        self.peak = 0

    def _cohort(self, size):
        """``size`` submitted candidates queued for grading, and the mark the
        fake judge gives each answer - the same marks for every cohort."""
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
        })
        evaluators = self.env["assessments.be.evaluator"]
        for c in range(size):
            applicant = self.env["hr.applicant"].create({
                "partner_name": "Cand %s" % uuid4().hex[:6],
                "email_from": "c_%s@example.com" % uuid4().hex[:8],
            })
            ev = self.env["assessments.be.evaluator"].create({
                "assessment_id": assessment.id,
                "applicant_id": applicant.id,
            })
            for q in range(ANSWERS_EACH):
                question = self.env["assessments.be.question"].create({
                    "name": "Q %s" % uuid4().hex[:4],
                    "question_type": "subjective_rubric",
                    "prompt": "Describe",
                    "generator_id": self.generator.id,
                    "assessment_ids": [(4, assessment.id)],
                })
                resp = self.env["assessments.be.response"].create({
                    "assessment_evaluator_id": ev.id,
                    "evaluator_id": applicant.id,
                    "question_id": question.id,
                    "assessment_id": assessment.id,
                    "state": "submitted",
                    "justification": "answer %d.%d" % (c, q),
                    "llm_state": "pending",
                })
                self.score_of[resp.id] = 40 + 10 * ((c + q) % 6)
            ev.write({"state": "submitted", "scoring_requested": True,
                      "llm_state": "pending"})
            evaluators |= ev
        return evaluators

    def _judge(self, env, system_prompt, user_text, **kwargs):
        """Vertex, standing in: slow enough that calls overlap if the lane
        lets them, and deterministic per answer."""
        with self.lock:
            self.in_flight += 1
            self.peak = max(self.peak, self.in_flight)
        try:
            time.sleep(0.05)
            items = json.loads(user_text[user_text.index('{"items"'):])["items"]
            return json.dumps({"results": [
                {"id": it["id"], "score": self.score_of[int(it["id"])]}
                for it in items]})
        finally:
            with self.lock:
                self.in_flight -= 1

    def _marks(self, evaluators):
        return [[r.llm_raw_100 for r in ev.response_ids.sorted("id")]
                for ev in evaluators.sorted("id")]

    def _no_commit(self):
        # The drain commits per candidate; a TransactionCase must not.
        return patch.object(self.env.cr, "commit", self.env.flush_all)

    def test_parallel_and_serial_lanes_store_the_same_marks(self):
        serial = self._cohort(4)
        parallel = self._cohort(4)
        Assessment = self.env["assessments.be"]

        with patch.object(vertex_svc, "_call_vertex", self._judge):
            serial._action_llm_score()
        self.assertEqual(self.peak, 1, "fixture guard: the serial lane is serial")

        self.peak = 0
        # Worker threads grade on this cursor here: the judge is faked, so
        # nothing in the call touches it, and a real side cursor could not see
        # this test's uncommitted rows.
        with patch.object(vertex_svc, "_call_vertex", self._judge), \
                patch.object(scoring_svc, "_grade_on_own_cursor",
                             lambda registry, uid, ctx, job:
                             scoring_svc._grade_outcome(self.env, job)), \
                self._no_commit():
            Assessment._drain_in_parallel(parallel, workers=4)

        self.assertGreater(self.peak, 1, "the calls never overlapped")
        self.assertEqual(self._marks(parallel), self._marks(serial))
        expected = [[float(self.score_of[r.id]) for r in ev.response_ids.sorted("id")]
                    for ev in parallel.sorted("id")]
        self.assertEqual(self._marks(parallel), expected)
        self.assertEqual(set(parallel.mapped("llm_state")),
                         set(serial.mapped("llm_state")))

    def test_a_quota_refusal_leaves_the_answer_pending_with_its_attempts(self):
        ev = self._cohort(1)
        refused = vertex_svc.VertexQuotaError("Vertex quota exhausted [429]")

        with patch.object(vertex_svc, "_call_vertex", side_effect=refused):
            ev._action_llm_score()

        for resp in ev.response_ids:
            self.assertEqual(resp.llm_state, "pending")
            self.assertFalse(resp.llm_attempts,
                             "a 429 is capacity, not a broken reply")

    def test_a_pinned_bearer_is_used_as_is(self):
        pinned = self.env(context=dict(self.env.context,
                                       etp_vertex_bearer="pinned-token"))
        self.assertEqual(vertex_svc._vertex_bearer(pinned), "pinned-token")

    def test_the_setting_defaults_to_four_and_stays_in_range(self):
        Assessment = self.env["assessments.be"]
        icp = self.env["ir.config_parameter"].sudo()
        key = "assessments_be_v2.scoring_parallel_calls"
        icp.set_param("assessments_be_v2.scoring_shards", "1")
        for raw, expected in (("", 4), ("x", 4), ("0", 4), ("-3", 1),
                              ("1", 1), ("6", 6), ("999", 8)):
            icp.set_param(key, raw)
            self.assertEqual(
                Assessment._scoring_parallel_calls_setting(), expected, raw)
        icp.search([("key", "=", key)]).unlink()
        self.assertEqual(Assessment._scoring_parallel_calls_setting(), 4,
                         "no row at all is the code default")
        self.assertEqual(
            self.env["res.config.settings"].create(
                {}).assessments_be_scoring_parallel_calls, 4,
            "the Settings form offers the same default")

    def test_each_call_counts_two_db_connections(self):
        """Odoo's default pool of 64 (prod runs 600): half for grading, less
        the ~2 each lane's own cron cursor holds, over 4 lanes at ~2
        connections per call, is 3 calls per lane - not the 8 that counting
        one connection per call allowed, nor the 4 that forgot the lanes' own
        cursors."""
        Assessment = self.env["assessments.be"]
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param("assessments_be_v2.scoring_parallel_calls", "8")
        icp.set_param("assessments_be_v2.scoring_shards", "4")
        for maxconn, expected in ((64, 3), (96, 5), (32, 1), (8, 1)):
            with patch.dict(tools.config._runtime_options,
                            {"db_maxconn": maxconn}):
                self.assertEqual(Assessment._scoring_parallel_calls(),
                                 expected, maxconn)
        with patch.dict(tools.config._runtime_options, {"db_maxconn": 64}):
            icp.set_param("assessments_be_v2.scoring_parallel_calls", "2")
            self.assertEqual(Assessment._scoring_parallel_calls(), 2,
                             "a setting under the pool's room is kept")

    def test_settings_report_the_stored_value_and_the_one_in_use(self):
        """The Flutter panel posts `parallel_calls` back on every Save, so
        reporting the pool-lowered value wrote it over the setting."""
        from ..controllers.api import admin as admin_api
        from ..controllers.api import common as api_common

        self.env.ref(
            "assessments_be_v2.group_assessment_manager"
        ).sudo().write({"user_ids": [(4, self.env.user.id)]})
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param("assessments_be_v2.scoring_parallel_calls", "6")
        icp.set_param("assessments_be_v2.scoring_shards", "4")
        stub = type("Req", (), {"env": self.env, "params": {}})()

        with patch.object(admin_api, "request", stub), \
                patch.object(api_common, "request", stub), \
                patch.dict(tools.config._runtime_options, {"db_maxconn": 64}):
            scoring = admin_api.EtpAssessmentApiAdmin().settings()[
                "data"]["scoring"]
            form = self.env["res.config.settings"].create({})

            self.assertEqual(scoring["parallel_calls"], 6)
            self.assertEqual(scoring["parallel_calls_effective"], 3)
            self.assertEqual(form.assessments_be_scoring_parallel_calls, 6)
            self.assertEqual(
                form.assessments_be_scoring_parallel_calls_effective, 3)
