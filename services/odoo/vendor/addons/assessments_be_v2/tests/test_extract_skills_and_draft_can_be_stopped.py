"""Extract skills and Draft from SOP each have a kill switch (owner, 2026-09-29).

Extract skills runs in a cron: Stop settles a queued run at once, and a running
run's reply - already paid for - is not applied when it lands, so the skills,
rating scheme and knowledge profile stay as they were.

Draft from SOP runs inside its own web request: Stop refuses any further model
call for that draft and makes the request answer `cancelled`. The call already
on the wire finishes and is billed either way.
"""
import json
import time
from datetime import timedelta
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

import httpx

from odoo import fields
from odoo.tests.common import TransactionCase, tagged
from odoo.tools import config

from ..services import vertex
from . import test_the_template_routes_refuse_a_non_manager as _routes

TAG_REPLY = json.dumps({"tags": [{"key": "video_captioning",
                                  "display": "Video captioning"}]})


def _no_call(*_a, **_k):
    raise AssertionError("no model call may be made here")


@tagged("-at_install", "post_install")
class TestExtractSkillsCanBeStopped(TransactionCase):

    def setUp(self):
        super().setUp()
        self.gen = self.env["assessments.be.prompt"].create({
            "name": "Stop %s" % uuid4().hex[:6],
            "source_text": "Label egocentric video clips."})

    def _cron(self, reply):
        # Only this generator is waiting: the cron takes any two.
        self.env["assessments.be.prompt"].search([
            ("id", "!=", self.gen.id),
            ("tag_extract_state", "in", ("queued", "generating")),
        ]).write({"tag_extract_state": "idle"})
        calls = []

        def counted(env, prompt):
            calls.append(prompt.id)
            return reply(env, prompt)
        # The cron commits and rolls back per run; a test cursor forbids both.
        with patch.object(self.env.cr, "commit", self.env.flush_all), \
                patch.object(self.env.cr, "rollback", lambda: None), \
                patch.object(vertex, "_tag_reply", counted):
            self.env["assessments.be.prompt"]._cron_extract_tags()
        self.gen.invalidate_recordset()
        return calls

    def test_a_queued_run_stops_at_once(self):
        self.gen.tag_extract_state = "queued"

        self.assertTrue(self.gen.action_cancel_tag_extract())

        self.assertEqual(self.gen.tag_extract_state, "cancelled")
        self.assertFalse(self.gen.tag_extract_cancel_requested)
        self.assertEqual(self._cron(_no_call), [],
                         "nothing left for the cron to pay for")

    def test_a_running_run_is_flagged_for_the_cron(self):
        self.gen.tag_extract_state = "generating"

        self.assertTrue(self.gen.action_cancel_tag_extract())

        self.assertEqual(self.gen.tag_extract_state, "generating")
        self.assertTrue(self.gen.tag_extract_cancel_requested)

    def test_nothing_running_reports_nothing_to_stop(self):
        self.gen.tag_extract_state = "done"
        self.assertFalse(self.gen.action_cancel_tag_extract())
        self.assertFalse(self.gen.tag_extract_cancel_requested)

    def test_a_flagged_run_is_settled_before_any_call(self):
        self.gen.write({"tag_extract_state": "generating",
                        "tag_extract_cancel_requested": True})

        self.assertEqual(self._cron(_no_call), [])

        self.assertEqual(self.gen.tag_extract_state, "cancelled")
        self.assertFalse(self.gen.tag_extract_cancel_requested)

    def test_a_stop_during_the_call_does_not_apply_the_reply(self):
        self.gen.tag_extract_state = "queued"
        before = self.gen.tag_ids

        def stopped_mid_call(env, prompt):
            prompt.tag_extract_cancel_requested = True   # Stop, meanwhile
            return TAG_REPLY
        self._cron(stopped_mid_call)

        self.assertEqual(self.gen.tag_extract_state, "cancelled")
        self.assertEqual(self.gen.tag_ids, before, "the reply was not applied")
        self.assertFalse(self.gen.tag_extract_reply)
        self.assertFalse(self.gen.tag_extract_cancel_requested)

    def test_an_unstopped_run_still_applies_its_reply(self):
        self.gen.tag_extract_state = "queued"

        self._cron(lambda env, prompt: TAG_REPLY)

        self.assertEqual(self.gen.tag_extract_state, "done")
        self.assertTrue(self.gen.tag_ids)

    def test_a_new_press_clears_an_old_stop(self):
        self.gen.tag_extract_cancel_requested = True

        self.gen._queue_tag_extract()

        self.assertFalse(self.gen.tag_extract_cancel_requested)


@tagged("-at_install", "post_install")
class TestDraftFromSopCanBeStopped(TransactionCase):
    """Borrows the template-route harness (the real decorators run), without
    inheriting - and so re-running - that file's own tests."""

    # Borrowed functions, never the class itself at module level: a TestCase
    # bound in this module's globals would be collected and run again here.
    _call = _routes.TestTheTemplateRoutesRefuseANonManager._call
    _code = staticmethod(_routes.TestTheTemplateRoutesRefuseANonManager._code)
    _manager_user = (
        _routes.TestTheTemplateRoutesRefuseANonManager._manager_user)

    def setUp(self):
        super().setUp()
        from ..controllers.api import task_templates as api
        self.controller = api.AssessmentsBeTaskTemplateApi()
        self.gen = self.env["assessments.be.prompt"].create({
            "name": "Draft %s" % uuid4().hex[:6],
            "source_text": "Compare two AI images against a prompt."})
        self.manager = self._manager_user()

    def test_a_stop_after_the_start_refuses_the_next_call(self):
        since = fields.Datetime.now()
        self.gen.template_draft_cancelled_at = since + timedelta(seconds=1)

        with self.assertRaises(vertex.VertexCancelledError):
            vertex._check_cancelled(self.env, {
                "prompt_id": self.gen.id, "template_draft_since": since})

    def test_an_older_stop_does_not_touch_a_new_draft(self):
        since = fields.Datetime.now()
        self.gen.template_draft_cancelled_at = since - timedelta(minutes=5)

        vertex._check_cancelled(self.env, {
            "prompt_id": self.gen.id, "template_draft_since": since})

    def test_the_stop_route_records_the_moment(self):
        reply = self._call("task_template_cancel_draft", self.manager,
                           generator_id=self.gen.id)

        self.assertTrue(reply.get("ok"), reply)
        self.assertTrue(self.gen.template_draft_cancelled_at)

    def test_a_draft_stopped_while_waiting_answers_cancelled(self):
        gen = self.gen

        def model_answers_after_a_stop(env, prompt_record, usage_ctx=None):
            # Stop pressed while this draft waited on the model.
            gen.template_draft_cancelled_at = (
                usage_ctx["template_draft_since"] + timedelta(seconds=2))
            return {"name": "Compare images", "structure": []}
        with patch.object(vertex, "draft_task_template_from_sop",
                          model_answers_after_a_stop):
            reply = self._call("task_template_draft", self.manager,
                               generator_id=gen.id)

        self.assertEqual(self._code(reply), "cancelled")
        self.assertNotIn("name", reply.get("data") or {})

    def test_an_unstopped_draft_is_returned(self):
        with patch.object(vertex, "draft_task_template_from_sop",
                          lambda env, g, usage_ctx=None: {
                              "name": "Compare images", "structure": []}):
            reply = self._call("task_template_draft", self.manager,
                               generator_id=self.gen.id)

        self.assertTrue(reply.get("ok"), reply)

    def test_a_refused_call_answers_cancelled(self):
        def refused(env, prompt_record, usage_ctx=None):
            raise vertex.VertexCancelledError("stopped")
        with patch.object(vertex, "draft_task_template_from_sop", refused):
            reply = self._call("task_template_draft", self.manager,
                               generator_id=self.gen.id)

        self.assertEqual(self._code(reply), "cancelled")

    def test_a_draft_out_of_time_answers_504_inside_the_worker_limit(self):
        seen = {}

        def too_slow(env, prompt_record, usage_ctx=None):
            seen.update(usage_ctx)
            raise vertex.VertexDeadlineError("too slow")
        with patch.object(vertex, "draft_task_template_from_sop", too_slow):
            reply = self._call("task_template_draft", self.manager,
                               generator_id=self.gen.id)

        self.assertEqual(self._code(reply), "timeout")
        self.assertEqual(reply["__status"], 504)
        # 10 s inside `limit_time_real`, so the answer beats the worker kill.
        self.assertAlmostEqual(seen["deadline"] - time.monotonic(),
                               config["limit_time_real"] - 10, delta=5)


class _Cut:
    """A Vertex reply, cut off: the retry path's trigger."""
    status_code = 200
    text = ""

    def json(self):
        return {"candidates": [{"finishReason": "MAX_TOKENS", "content": {
            "parts": [{"text": '{"name": "Comp'}]}}], "usageMetadata": {}}


@tagged("-at_install", "post_install")
class TestADraftAnswersBeforeItsWorkerIsKilled(TransactionCase):
    """Stage, 13 Oct 2026: one draft took 55 s. Odoo kills a web worker at
    `limit_time_real` (default 120 s), so a MAX_TOKENS retry after a slow first
    try was paid for and then killed. A `deadline` in usage_ctx stops that."""

    def _send(self, deadline, post_takes=55.0, raises=None):
        """`deadline`: seconds from now, or None for no deadline."""
        clock = [1000.0]
        sent = []

        class _Client:
            def post(self, url, json=None, headers=None, **kw):
                sent.append(kw.get("timeout"))
                if raises:
                    raise raises
                clock[0] += post_takes
                return _Cut()

        ctx = {"deadline": clock[0] + deadline} if deadline else {}
        with patch.object(vertex, "time", SimpleNamespace(
                    monotonic=lambda: clock[0])), \
                patch.object(vertex, "_vertex_creds",
                             return_value=("p", "global", "m", "")), \
                patch.object(vertex, "_gemini_request",
                             return_value=("https://vertex.invalid", {})), \
                patch.object(vertex, "_httpx", return_value=_Client()), \
                patch.object(vertex, "_log_usage"), \
                patch.object(vertex, "_log_failed_call"), \
                patch.object(vertex, "_check_budget"), \
                patch.object(vertex, "_check_cancelled"), \
                patch.object(vertex, "_check_scoring_cancelled"):
            try:
                vertex._call_vertex_single(
                    self.env, "sys", "hi", max_tokens=12000,
                    response_json=True, usage_ctx=ctx)
            except (vertex.VertexDeadlineError, vertex.LLMRefusalError) as e:
                return sent, e
        return sent, None

    def test_a_retry_that_cannot_finish_in_time_is_never_sent(self):
        sent, err = self._send(deadline=100)

        # 55 s spent, 45 s left: the bigger retry would outrun the deadline.
        self.assertEqual([t.read for t in sent], [100.0],
                         "the retry was never sent")
        self.assertIsInstance(err, vertex.VertexDeadlineError)

    def test_the_call_in_flight_is_cut_at_the_deadline(self):
        sent, err = self._send(deadline=100, raises=httpx.ReadTimeout("slow"))

        self.assertEqual([t.read for t in sent], [100.0])
        self.assertIsInstance(err, vertex.VertexDeadlineError)

    def test_no_deadline_keeps_todays_retry_and_timeout(self):
        sent, err = self._send(deadline=None)

        self.assertEqual(sent, [None, None], "retried, client's own timeout")
        self.assertNotIsInstance(err, vertex.VertexDeadlineError)

    def test_the_deadline_caps_each_phase_and_never_raises_one(self):
        """`timeout=left` replaced the client's per-phase limits: with 500 s
        left a dead host held the connect for 500 s instead of 30."""
        for left, want in ((500, (30, 180, 180, 30)),
                           (100, (30, 100, 100, 30)),
                           (20 + 30, (30, 50, 50, 30))):
            with self.subTest(left=left):
                sent, _err = self._send(deadline=left,
                                        raises=httpx.ReadTimeout("slow"))
                self.assertEqual(
                    (sent[0].connect, sent[0].read, sent[0].write,
                     sent[0].pool), want)

    def test_the_client_keeps_its_own_per_phase_limits(self):
        with patch.object(vertex, "_HTTPX_CLIENT", None):
            client = vertex._httpx()
        self.addCleanup(client.close)
        self.assertEqual((client.timeout.connect, client.timeout.read,
                          client.timeout.write, client.timeout.pool),
                         (30, 180, 180, 30))

    def test_too_little_time_left_makes_no_call_at_all(self):
        """The 30 s floor on its own: no attempt has been timed yet, so the
        slowest-so-far rule cannot be what stops it."""
        sent, err = self._send(deadline=20)

        self.assertEqual(sent, [], "no call was started")
        self.assertIsInstance(err, vertex.VertexDeadlineError)
        self.assertIn("none was made", str(err))

    def test_a_cut_call_is_booked_with_its_time_and_its_try(self):
        """The ledger row of a cut call said 0 ms and try 0. Its cost stays
        unknown (Vertex may still bill it) - the row carries none."""
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Cut %s" % uuid4().hex[:6]})
        clock = [1000.0]

        class _Client:
            def post(self, url, json=None, headers=None, **kw):
                clock[0] += 99.0
                raise httpx.ReadTimeout("slow")

        with patch.object(vertex, "time", SimpleNamespace(
                    monotonic=lambda: clock[0])), \
                patch.object(vertex, "_vertex_creds",
                             return_value=("p", "global", "m", "")), \
                patch.object(vertex, "_gemini_request",
                             return_value=("https://vertex.invalid", {})), \
                patch.object(vertex, "_httpx", return_value=_Client()), \
                patch.object(vertex, "_check_budget"), \
                patch.object(vertex, "_check_cancelled"), \
                patch.object(vertex, "_check_scoring_cancelled"):
            # Not `assertRaises`: Odoo's rolls its block back, row included.
            try:
                vertex._call_vertex_single(
                    self.env, "sys", "hi", response_json=True,
                    usage_ctx={"operation": "draft_task_template",
                               "prompt_id": generator.id,
                               "deadline": clock[0] + 100})
            except vertex.VertexDeadlineError:
                pass
            else:
                self.fail("the call was not cut at its deadline")

        row = self.env["assessments.be.llm.usage"].search(
            [("prompt_id", "=", generator.id)])
        self.assertEqual(len(row), 1)
        self.assertEqual((row.latency_ms, row.attempt), (99000, 1))
        self.assertIn("deadline", row.note)
        self.assertEqual(row.cost_usd, 0.0)


@tagged("-at_install", "post_install")
class TestTheDraftRoutesDeadlineReachesTheModelCall(TransactionCase):
    """The deadline is set by the route and read by `_call_vertex_single`;
    nothing between them is stubbed, only the network."""

    _call = _routes.TestTheTemplateRoutesRefuseANonManager._call
    _code = staticmethod(_routes.TestTheTemplateRoutesRefuseANonManager._code)
    _manager_user = (
        _routes.TestTheTemplateRoutesRefuseANonManager._manager_user)

    def setUp(self):
        super().setUp()
        from ..controllers.api import task_templates as api
        self.controller = api.AssessmentsBeTaskTemplateApi()
        icp = self.env["ir.config_parameter"].sudo()
        for key, value in (("vertex_api_key", "test-key"),
                           ("vertex_access_token", ""),
                           ("vertex_service_account_json", ""),
                           ("daily_llm_cap_usd", "0"),
                           ("per_evaluator_llm_cap_usd", "0"),
                           ("vertex_max_rpm", "0")):
            icp.set_param("assessments_be_v2.%s" % key, value)
        self.gen = self.env["assessments.be.prompt"].create({
            "name": "Route deadline %s" % uuid4().hex[:6],
            "source_text": "Compare two AI images against a prompt."})

    def test_the_route_deadline_caps_the_call_it_makes(self):
        sent = []

        class _Client:
            def post(self, url, json=None, headers=None, **kw):
                sent.append(kw.get("timeout"))
                raise httpx.ReadTimeout("slow")

        with patch.object(vertex, "_httpx", return_value=_Client()):
            reply = self._call("task_template_draft", self._manager_user(),
                               generator_id=self.gen.id)

        self.assertEqual((reply["__status"], self._code(reply)),
                         (504, "timeout"), reply)
        self.assertEqual(len(sent), 1)
        left = config["limit_time_real"] - 10
        self.assertEqual(sent[0].connect, 30)
        self.assertAlmostEqual(sent[0].read, min(left, 180), delta=5)
