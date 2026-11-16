# -*- coding: utf-8 -*-
"""A grading call that was cut off, or waited in the queue, still gets through.

  * A reply cut off at the grading floor (16,000 output tokens) is asked again
    with 32,000. Vertex's shared retry ceiling was also 16,000, so the retry
    never grew and the cut-off reply was paid for twice at the same size.
    Generation keeps its own ceiling.
  * A parallel lane pins the bearer WITH its expiry. A call that waited in the
    pool until under 2 minutes were left fetches a fresh one, and a 401 on a
    pinned bearer is sent once more with a fresh one - spending no attempt.

Vertex is never called: `_Vertex` stands in for the HTTP client and `_Clock`
for the time.
"""
import json
import time
from contextlib import ExitStack
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger

from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc

MODEL = "gemini-3.1-pro-preview"


class _Reply:

    def __init__(self, status, body):
        self.status_code = status
        self.text = json.dumps(body)
        self._body = body

    def json(self):
        return self._body


class _Vertex:
    """The HTTP client. ``replies`` answer the next calls as
    ``(finishReason, text)``, then every item scores 80; a bearer in
    ``refuse`` is answered 401."""

    def __init__(self, replies=(), refuse=()):
        self.replies = list(replies)
        self.refuse = set(refuse)
        self.requests = []

    def post(self, url, json=None, headers=None):
        bearer = (headers or {}).get("Authorization", "")
        self.requests.append((bearer, json))
        if bearer in self.refuse:
            return _Reply(401, {"error": {"message": "Request had invalid "
                                          "authentication credentials."}})
        if self.replies:
            finish, text = self.replies.pop(0)
        else:
            items = _items(json)
            finish, text = "STOP", _dumps({"results": [
                {"id": it["id"], "score": 80, "deductions": [
                    {"points": -20, "reason": "r", "evidence": "e"}]}
                for it in items]})
        return _Reply(200, {
            "candidates": [{"finishReason": finish,
                            "content": {"parts": [{"text": text}]}}],
            "usageMetadata": {"promptTokenCount": 100,
                              "candidatesTokenCount": 10}})

    def bearers(self):
        return [b for b, _body in self.requests]

    def output_room(self):
        return [body["generationConfig"]["maxOutputTokens"]
                for _b, body in self.requests]


class _Clock:
    """The `time` module, with `time()` set by the test."""

    def __init__(self, now=1900000000.0):
        self.now = now

    def time(self):
        return self.now

    def __getattr__(self, name):
        return getattr(time, name)


def _dumps(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _items(body):
    return json.loads(body["contents"][-1]["parts"][0]["text"])["items"]


class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        icp = self.env["ir.config_parameter"].sudo()
        for key, value in (("scoring_model", MODEL), ("fallback_model", ""),
                           ("llm_max_attempts", "3"),
                           ("daily_llm_cap_usd", "0"),
                           ("per_evaluator_llm_cap_usd", "0"),
                           ("vertex_max_rpm", "0")):
            icp.set_param("assessments_be_v2.%s" % key, value)

    def _answer(self):
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        q = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Where does the load go?",
            "subjective_rubric_json": json.dumps(
                {"checklist": ["Names the braces"]}),
            "solution_json": json.dumps("Through the braces."),
            "generator_id": generator.id})
        applicant = self.env["hr.applicant"].create(
            {"partner_name": "Cand %s" % uuid4().hex[:6]})
        paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id})
        ev = self.env["assessments.be.evaluator"].create(
            {"assessment_id": paper.id, "applicant_id": applicant.id})
        return self.env["assessments.be.response"].create({
            "assessment_id": paper.id, "assessment_evaluator_id": ev.id,
            "evaluator_id": applicant.id, "question_id": q.id,
            "justification": "Down the braces into the footing.",
            "state": "submitted", "llm_state": "pending"})

    def _vertex(self, fake, fresh=None):
        """Vertex faked; ``fresh`` patches what a fresh bearer resolves to,
        else every call is sent a fixed one."""
        stack = ExitStack()
        stack.enter_context(patch.object(vertex_svc, "_httpx",
                                         return_value=fake))
        stack.enter_context(patch.object(
            vertex_svc, "_vertex_creds",
            return_value=("proj", "global", MODEL, "")))
        if fresh is None:
            stack.enter_context(patch.object(
                vertex_svc, "_vertex_bearer", return_value="tok"))
        else:
            stack.enter_context(patch.object(
                vertex_svc, "_vertex_bearer_until", **fresh))
        return stack

    def _grade_pinned(self, resp, fake, context):
        """Grade ``resp`` as a pool worker does, on ``context``, and store
        the outcome on the lane's cursor."""
        _s, job = scoring_svc._prepare_submission(self.env, resp)
        results, error = scoring_svc._grade_outcome(self.env(context=context),
                                                    job)
        scoring_svc._settle_submission(self.env, job, results, error)
        resp.invalidate_recordset()
        return error


@tagged("-at_install", "post_install")
class TestACutOffReplyGetsMoreRoom(_Base):

    def test_a_grading_retry_doubles_past_the_floor(self):
        resp = self._answer()
        fake = _Vertex(replies=[
            ("MAX_TOKENS", '{"results":[{"id":%d,"sco' % resp.id)])
        with self._vertex(fake):
            scoring_svc._score_submission(self.env, resp)
        self.assertEqual(fake.output_room(), [16000, 32000])
        self.assertEqual(resp.llm_state, "scored")

    def test_generation_keeps_its_own_ceiling(self):
        fake = _Vertex(replies=[("MAX_TOKENS", '{"a":['),
                                ("STOP", '{"a":[]}'),
                                ("MAX_TOKENS", '{"a":[')])
        with self._vertex(fake):
            vertex_svc._call_vertex(self.env, "sys", "Write.", model=MODEL,
                                    max_tokens=8000, response_json=True)
            vertex_svc._call_vertex(self.env, "sys", "Write.", model=MODEL,
                                    max_tokens=16000, response_json=True)
        self.assertEqual(fake.output_room(), [8000, 16000, 16000])


@tagged("-at_install", "post_install")
class TestAQueuedCallHasALiveBearer(_Base):

    def test_the_lane_pins_the_bearer_with_its_expiry(self):
        clock = _Clock()
        submitted = []
        pool = SimpleNamespace(submit=lambda fn, *args: submitted.append(args))
        with patch.object(vertex_svc, "time", clock), patch.object(
                vertex_svc, "_vertex_bearer_until",
                return_value=("tok-old", clock.now + 300)):
            scoring_svc.parallel_dispatch(self.env, pool)(SimpleNamespace())
        context = submitted[0][2]
        self.assertEqual(context["etp_vertex_bearer"], "tok-old")
        self.assertEqual(context["etp_vertex_bearer_expires"], clock.now + 300)

    def test_a_pin_is_used_until_two_minutes_are_left(self):
        clock = _Clock()
        env = self.env(context=dict(
            self.env.context, etp_vertex_bearer="tok-old",
            etp_vertex_bearer_expires=clock.now + 300))
        with patch.object(vertex_svc, "time", clock), patch.object(
                vertex_svc, "_vertex_bearer_until",
                return_value=("tok-new", clock.now + 3900)):
            clock.now += 170
            self.assertEqual(vertex_svc._vertex_bearer(env), "tok-old")
            clock.now += 20
            self.assertEqual(vertex_svc._vertex_bearer(env), "tok-new")

    def test_a_call_that_waited_past_its_bearer_sends_a_fresh_one(self):
        """4 candidates x 15 retries are 60 one-answer calls, ~11 minutes
        through 4 workers; the pinned bearer was sure of 5."""
        resp = self._answer()
        clock = _Clock()
        submitted = []
        pool = SimpleNamespace(submit=lambda fn, *args: submitted.append(args))
        fake = _Vertex(refuse={"Bearer tok-old"})
        with patch.object(vertex_svc, "time", clock), self._vertex(
                fake, fresh={"side_effect": [
                    ("tok-old", clock.now + 300),
                    ("tok-new", clock.now + 3900)]}):
            scoring_svc.parallel_dispatch(self.env, pool)(SimpleNamespace())
            clock.now += 11 * 60
            error = self._grade_pinned(resp, fake, submitted[0][2])
        self.assertIsNone(error)
        self.assertEqual(fake.bearers(), ["Bearer tok-new"],
                         "the lapsed bearer is never sent")
        self.assertEqual(resp.llm_state, "scored")

    def test_a_401_on_a_pinned_bearer_is_resent_and_spends_no_attempt(self):
        resp = self._answer()
        fake = _Vertex(refuse={"Bearer tok-revoked"})
        pinned = dict(self.env.context, etp_vertex_bearer="tok-revoked")
        with self._vertex(fake, fresh={"return_value": ("tok-new", 0)}):
            error = self._grade_pinned(resp, fake, pinned)
        self.assertIsNone(error)
        self.assertEqual(fake.bearers(),
                         ["Bearer tok-revoked", "Bearer tok-new"])
        self.assertEqual(resp.llm_state, "scored")
        self.assertEqual(resp.llm_attempts, 1, "only the call that scored it")

    @mute_logger("odoo.addons.assessments_be_v2.services.scoring")
    def test_a_fresh_bearer_refused_too_is_a_real_failure(self):
        resp = self._answer()
        fake = _Vertex(refuse={"Bearer tok-revoked", "Bearer tok-new"})
        pinned = dict(self.env.context, etp_vertex_bearer="tok-revoked")
        with self._vertex(fake, fresh={"return_value": ("tok-new", 0)}):
            error = self._grade_pinned(resp, fake, pinned)
        self.assertIsNotNone(error)
        self.assertEqual(len(fake.requests), 2, "resent once, not in a loop")
        self.assertEqual((resp.llm_state, resp.llm_attempts), ("failed", 1))
