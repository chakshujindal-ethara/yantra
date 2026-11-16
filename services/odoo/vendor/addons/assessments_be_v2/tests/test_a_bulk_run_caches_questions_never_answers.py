# -*- coding: utf-8 -*-
"""Question-group caches for bulk grading (W13, `ETP_PLANS_AND_STRATEGY.md` §3.10).

With the engineer switch `assessments_be_v2.scoring_cache` = `groups` (the
default; `off` turns it off), a bulk run on a shared paper cuts the cohort's
graded questions (by id) into groups of the batch size; each group's
instructions and question material live in one Vertex context cache, and a
call sends only the candidate's part. A group under the model's cache minimum
is left out and batched as with the cache off. Answers, picks, names and answer
ids never reach a cache. Anything wrong with a cache sends the call inline,
spending no attempt.

Vertex is never called: `_Vertex` stands in for the HTTP client and records
every request, so each test reads the exact bodies that would have been sent.
"""
import json
from concurrent.futures import Future
from contextlib import ExitStack
from datetime import timedelta
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from ..services import grading_cache
from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc

MODEL = "gemini-3.1-pro-preview"
FALLBACK = "gemini-2.5-pro"
HOST = "https://aiplatform.googleapis.com/v1"
MARK = "QZX7731MARK"
#: Enough question text that a group clears 3.1 Pro's 4,096-token minimum.
LONG = "Explain how the load travels through each member of the frame. " * 100
#: Every field a question's material may carry, plus the id that keys it.
MATERIAL_KEYS = {"question_id", "question_type", "task", "rubric",
                 "golden_answer", "axes", "official_reasoning", "boxes",
                 "decoys", "required_elements", "penalties",
                 "reference_prompt"}


class _Reply:

    def __init__(self, status, body):
        self.status_code = status
        self.text = json.dumps(body)
        self._body = body

    def json(self):
        return self._body


class _Vertex:
    """The HTTP client, standing in. ``call_statuses`` answers the next
    generateContent calls in turn, then 200; a bearer in ``refuse`` gets 401."""

    def __init__(self, create_status=200, call_statuses=(), patch_status=200,
                 refuse=()):
        self.requests = []
        self.create_status = create_status
        self.call_statuses = list(call_statuses)
        self.patch_status = patch_status
        self.refuse = set(refuse)

    def _refused(self, headers):
        return (headers or {}).get("Authorization") in self.refuse

    def post(self, url, json=None, headers=None):
        self.requests.append(("POST", url, json))
        if self._refused(headers):
            return _Reply(401, {"error": {"message": "invalid credentials"}})
        if url.endswith("/cachedContents"):
            if self.create_status != 200:
                return _Reply(self.create_status, {"error": "boom"})
            return _Reply(200, {
                "name": "projects/proj/locations/global/cachedContents/c%d"
                        % len(self.creates()),
                "usageMetadata": {"totalTokenCount": 5000}})
        status = self.call_statuses.pop(0) if self.call_statuses else 200
        if status != 200:
            return _Reply(status, {"error": {
                "message": "cachedContent not found or expired"}})
        text = json["contents"][-1]["parts"][0]["text"]
        items = _items(text)
        return _Reply(200, {"candidates": [{
            "finishReason": "STOP", "content": {"parts": [{"text": _dumps({
                "results": [self._result(it) for it in items]})}]}}],
            "usageMetadata": {"promptTokenCount": 100,
                              "candidatesTokenCount": 10}})

    @staticmethod
    def _result(item):
        """One judged item. A labelling answer is a {box: label} map, and its
        mark comes from `box_scores` - one entry per box - so a judge that
        omitted them would (rightly) have its reply retried as truncated."""
        result = {"id": item["id"], "score": 80,
                  "deductions": [{"points": -20, "reason": "r",
                                  "evidence": "e"}]}
        if isinstance(item.get("answer"), dict):
            result["box_scores"] = {k: 80 for k in item["answer"]}
        return result

    def patch(self, url, json=None, headers=None):
        self.requests.append(("PATCH", url, json))
        if self._refused(headers):
            return _Reply(401, {"error": {"message": "invalid credentials"}})
        return _Reply(self.patch_status, {})

    def creates(self):
        return [b for m, u, b in self.requests if u.endswith("/cachedContents")]

    def calls(self):
        return [(u, b) for m, u, b in self.requests
                if u.endswith(":generateContent")]

    def patches(self):
        return [(u, b) for m, u, b in self.requests if m == "PATCH"]


def _dumps(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _items(text):
    return json.loads(text[text.index('{"items"'):])["items"]


def _call_text(body):
    return body["contents"][-1]["parts"][0]["text"]


class _Cohort(TransactionCase):

    def setUp(self):
        super().setUp()
        icp = self.env["ir.config_parameter"].sudo()
        for key, value in (("scoring_batch_size", "20"),
                           ("llm_max_attempts", "3"),
                           ("scoring_model", MODEL),
                           ("fallback_model", ""),
                           ("scoring_cache", "groups"),
                           ("daily_llm_cap_usd", "0"),
                           ("per_evaluator_llm_cap_usd", "0"),
                           ("vertex_max_rpm", "0")):
            icp.set_param("assessments_be_v2.%s" % key, value)
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "W13 %s" % uuid4().hex[:6]})
        self.paper = self._new_paper()
        # Only rows this test makes: a copy where caching has run has others.
        self.before = {model: self.env[model].search(
            [], order="id desc", limit=1).id or 0 for model in (
                "assessments.be.scoring.cache", "assessments.be.llm.usage")}

    def _new_paper(self):
        return self.env["assessments.be"].create({
            "name": "W13 paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id})

    def _set(self, key, value):
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.%s" % key, value)

    def _unset_switch(self):
        self.env["ir.config_parameter"].sudo().search(
            [("key", "=", "assessments_be_v2.scoring_cache")]).unlink()

    def _written(self, n, task=LONG):
        return self.env["assessments.be.question"].browse([
            self.env["assessments.be.question"].create({
                "name": "Q%d %s" % (i, uuid4().hex[:4]),
                "question_type": "subjective_rubric",
                "prompt": "%s (%d)" % (task, i),
                "subjective_rubric_json": json.dumps({
                    "checklist": ["Names the load path %d" % i]}),
                "solution_json": json.dumps("Through the braces %d." % i),
                "generator_id": self.generator.id,
                "assessment_ids": [(4, self.paper.id)],
            }).id for i in range(n)])

    def _candidate(self, questions, order=None, answered=None, text=None,
                   name=None, email=None, requested=True):
        applicant = self.env["hr.applicant"].create({
            "partner_name": name or "Cand %s" % uuid4().hex[:6],
            "email_from": email or "c_%s@example.com" % uuid4().hex[:8]})
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id,
            "question_order": json.dumps(
                list(reversed(questions.ids)) if order is None else order)})
        for q in (questions if answered is None else answered):
            self.env["assessments.be.response"].create({
                "assessment_id": self.paper.id,
                "assessment_evaluator_id": ev.id,
                "evaluator_id": applicant.id,
                "question_id": q.id,
                "state": "submitted",
                "justification": text or ("The load goes through the braces "
                                          "into the footing, answer %d." % q.id),
                "llm_state": "pending",
            })
        ev.write({"state": "submitted", "scoring_requested": requested})
        return ev

    def _vertex(self, fake, bearer="tok", api_key=""):
        stack = ExitStack()
        stack.enter_context(patch.object(vertex_svc, "_httpx",
                                         return_value=fake))
        stack.enter_context(patch.object(vertex_svc, "_vertex_bearer",
                                         return_value=bearer))
        stack.enter_context(patch.object(
            vertex_svc, "_vertex_creds",
            return_value=("proj", "global", MODEL, api_key)))
        return stack

    def _grade(self, fake, *evaluators, **kw):
        with self._vertex(fake, **kw):
            for ev in evaluators:
                ev._action_llm_score()

    def _row(self):
        return self._new("assessments.be.scoring.cache", limit=1)

    def _new(self, model, domain=(), **kw):
        return self.env[model].search(
            [("id", ">", self.before[model])] + list(domain), **kw)

    def _assert_inline(self, body):
        self.assertNotIn("cachedContent", body)
        self.assertIn("systemInstruction", body)
        self.assertTrue(all("question_type" in it
                            for it in _items(_call_text(body))))

    def _assert_cached(self, body, name):
        self.assertEqual(body["cachedContent"], name)
        self.assertNotIn("systemInstruction", body)


@tagged("-at_install", "post_install")
class TestABulkRunReadsItsQuestionsFromACache(_Cohort):

    def test_the_call_sends_only_the_candidates_part(self):
        questions = self._written(3)
        asha, ben = self._candidate(questions), self._candidate(questions)
        fake = _Vertex()
        self._grade(fake, asha, ben)

        [create] = fake.creates()
        self.assertEqual(create["model"], "projects/proj/locations/global/"
                         "publishers/google/models/%s" % MODEL)
        self.assertEqual(create["ttl"], "900s")
        self.assertEqual(create["systemInstruction"]["parts"][0]["text"],
                         scoring_svc._get_scoring_prompt())
        [content] = create["contents"]
        self.assertEqual(content["role"], "user")
        block = content["parts"][0]["text"]
        self.assertTrue(block.startswith("QUESTIONS\n"))
        self.assertEqual(
            [q["question_id"] for q in json.loads(block[10:])["questions"]],
            sorted(questions.ids))

        name = "projects/proj/locations/global/cachedContents/c1"
        self.assertEqual(len(fake.calls()), 2, "one call per candidate")
        for url, body in fake.calls():
            self.assertTrue(url.endswith("/models/%s:generateContent" % MODEL))
            self._assert_cached(body, name)
            text = _call_text(body)
            self.assertTrue(text.startswith("Grade exactly these items"))
            self.assertNotIn("load travels", text, "no question material")
            for item in _items(text):
                self.assertEqual(set(item), {"id", "question_id", "answer"})
        for ev in (asha, ben):
            self.assertEqual(set(ev.response_ids.mapped("llm_state")),
                             {"scored"})

    def test_unset_means_groups(self):
        self._unset_switch()
        questions = self._written(2)
        asha, _ben = self._candidate(questions), self._candidate(questions)
        fake = _Vertex()
        self._grade(fake, asha)
        self.assertEqual(len(fake.creates()), 1)
        self._assert_cached(fake.calls()[0][1], self._row().resource_name)

    def test_a_parallel_lane_shares_the_same_cache(self):
        questions = self._written(2)
        asha, ben = self._candidate(questions), self._candidate(questions)
        fake = _Vertex()

        # SYNCHRONOUS: a worker thread on this test's cursor raced the lane's
        # own queries (psycopg2 connections are not thread-safe).
        def on_this_cursor(env, pool):
            def dispatch(job):
                done = Future()
                done.set_result(scoring_svc._grade_outcome(self.env, job))
                return done
            return dispatch

        with self._vertex(fake), patch.object(
                scoring_svc, "parallel_dispatch", on_this_cursor), \
                patch.object(self.env.cr, "commit", self.env.flush_all):
            self.env["assessments.be"]._drain_in_parallel(asha | ben,
                                                          workers=1)
        self.assertEqual(len(fake.creates()), 1)
        self.assertEqual([b.get("cachedContent") for _u, b in fake.calls()],
                         ["projects/proj/locations/global/cachedContents/c1"]
                         * 2)
        self.assertEqual(
            set((asha | ben).response_ids.mapped("llm_state")), {"scored"})

    def test_groups_follow_question_ids_not_the_shuffle(self):
        self._set("scoring_batch_size", "2")
        questions = self._written(4)
        q1, q2, q3, q4 = questions.ids
        asha = self._candidate(questions, order=[q4, q1, q3, q2])
        ben = self._candidate(questions, order=[q2, q3, q4, q1])
        fake = _Vertex()
        self._grade(fake, asha, ben)

        groups = [sorted(it["question_id"] for it in _items(_call_text(b)))
                  for _u, b in fake.calls()]
        self.assertEqual(groups, [[q1, q2], [q3, q4]] * 2)
        self.assertEqual(len(fake.creates()), 2, "one cache per group, shared")
        self.assertEqual(
            [json.loads(c["contents"][0]["parts"][0]["text"][10:])
             ["questions"][0]["question_id"] for c in fake.creates()],
            [q1, q3])

    def test_a_retry_uses_a_live_cache_but_never_creates_one(self):
        questions = self._written(2)
        asha = self._candidate(questions)
        ben = self._candidate(questions)
        ben.response_ids[0].write({"llm_state": "failed", "llm_attempts": 1})
        fake = _Vertex()
        self._grade(fake, ben)
        self.assertEqual(len(fake.calls()), 2, "the retry is graded alone")
        self.assertEqual(len(fake.creates()), 1)
        retry = [b for _u, b in fake.calls()
                 if [it["id"] for it in _items(_call_text(b))]
                 == [ben.response_ids[0].id]]
        self._assert_cached(retry[0], self._row().resource_name)

        self._row().write({"expires_at": fields.Datetime.now()})
        asha.response_ids.write({"llm_state": "failed", "llm_attempts": 1})
        fake = _Vertex()
        self._grade(fake, asha)
        self.assertFalse(fake.creates())
        for _u, body in fake.calls():
            self._assert_inline(body)


@tagged("-at_install", "post_install")
class TestWhenNoCacheIsUsed(_Cohort):

    def test_off_and_a_group_under_the_minimum_send_todays_request(self):
        for value, task in (("off", LONG), ("OFF", LONG), ("false", LONG),
                            (None, "Describe it")):
            with self.subTest(switch=value):
                if value is None:
                    self._unset_switch()
                else:
                    self._set("scoring_cache", value)
                self.paper = self._new_paper()
                questions = self._written(3, task=task)
                asha = self._candidate(questions)
                answers = asha.response_ids
                fake = _Vertex()
                self._grade(fake, asha)
                self.assertFalse(fake.creates())
                [(_url, body)] = fake.calls()
                self.assertEqual(body, {
                    "contents": [{"role": "user", "parts": [{"text": _dumps(
                        {"items": [scoring_svc._build_item(r)
                                   for r in answers]})}]}],
                    "generationConfig": {"maxOutputTokens": 16000,
                                         "temperature": 0.2,
                                         "responseMimeType":
                                             "application/json"},
                    "systemInstruction": {"parts": [
                        {"text": scoring_svc._get_scoring_prompt()}]},
                })

    def test_a_rescore_never_uses_or_creates_a_cache(self):
        questions = self._written(2)
        asha = self._candidate(questions)
        ben = self._candidate(questions, requested=False)
        fake = _Vertex()
        self._grade(fake, asha)
        self.assertEqual(len(fake.creates()), 1)

        ben.action_rescore_individually(questions.ids)
        fake = _Vertex()
        self._grade(fake, ben)
        self.assertFalse(fake.creates())
        [(_url, body)] = fake.calls()
        self._assert_inline(body)
        self.assertEqual(set(ben.response_ids.mapped("llm_state")), {"scored"})

    def test_a_per_person_paper_is_batched_and_sent_as_before(self):
        questions = self._written(4)
        asha = self._candidate(questions[:2], order=questions[:2].ids)
        self._candidate(questions[2:], order=questions[2:].ids)
        fake = _Vertex()
        self._grade(fake, asha)
        self.assertFalse(fake.creates())
        [(_url, body)] = fake.calls()
        self._assert_inline(body)
        self.assertEqual(len(_items(_call_text(body))), 2)

    def test_a_cache_is_created_only_when_two_answers_need_it(self):
        questions = self._written(2)
        alone = self._candidate(questions, answered=questions[:1])
        fake = _Vertex()
        self._grade(fake, alone)
        self.assertFalse(fake.creates(), "1 queued answer: uncached")
        self._assert_inline(fake.calls()[0][1])

        self.paper = self._new_paper()
        questions = self._written(2)
        asha = self._candidate(questions, answered=questions[:1])
        self._candidate(questions, answered=questions[:1])
        fake = _Vertex()
        self._grade(fake, asha)
        self.assertEqual(len(fake.creates()), 1, "2 queued answers: cached")
        self._assert_cached(fake.calls()[0][1], self._row().resource_name)

    def test_a_group_under_the_models_minimum_goes_inline(self):
        questions = self._written(2, task="Describe it")
        asha, _ben = self._candidate(questions), self._candidate(questions)
        fake = _Vertex()
        self._grade(fake, asha)
        self.assertFalse(fake.creates())
        self._assert_inline(fake.calls()[0][1])

    def test_groups_under_the_minimum_are_batched_as_with_the_cache_off(self):
        """More graded questions than the batch size, every group too small
        to cache: the calls are the ones the cache-off run makes, not one
        per question group."""
        self._set("scoring_batch_size", "2")
        calls = {}
        for switch in ("off", "groups"):
            self._set("scoring_cache", switch)
            self.paper = self._new_paper()
            questions = self._written(4, task="Describe it")
            asha = self._candidate(questions, answered=questions[0::2])
            fake = _Vertex()
            self._grade(fake, asha)
            self.assertFalse(fake.creates())
            calls[switch] = len(fake.calls())
        self.assertEqual(calls, {"off": 1, "groups": 1})

    def test_a_model_that_never_caches_goes_inline(self):
        self._set("scoring_model", "gemini-1.5-pro")
        questions = self._written(2)
        asha, _ben = self._candidate(questions), self._candidate(questions)
        fake = _Vertex()
        self._grade(fake, asha)
        self.assertFalse(fake.creates())

    def test_an_api_key_grades_inline(self):
        questions = self._written(2)
        asha, _ben = self._candidate(questions), self._candidate(questions)
        fake = _Vertex()
        self._grade(fake, asha, bearer="", api_key="AIzaFAKE")
        self.assertFalse(fake.creates())
        self._assert_inline(fake.calls()[0][1])


@tagged("-at_install", "post_install")
class TestACacheProblemNeverBlocksGrading(_Cohort):

    def test_a_cache_vertex_lost_sends_the_call_inline_with_no_attempt(self):
        questions = self._written(2)
        asha, ben = self._candidate(questions), self._candidate(questions)
        self._grade(_Vertex(), asha)
        name = self._row().resource_name

        fake = _Vertex(call_statuses=[404])
        self._grade(fake, ben)
        (_u1, first), (_u2, second) = fake.calls()
        self._assert_cached(first, name)
        self._assert_inline(second)
        self.assertEqual(set(ben.response_ids.mapped("llm_state")), {"scored"})
        self.assertEqual(ben.response_ids.mapped("llm_attempts"), [1, 1],
                         "the lost cache spent no attempt")
        self.assertLessEqual(self._row().expires_at, fields.Datetime.now())

    def test_an_expired_cache_is_not_used_and_is_created_again(self):
        questions = self._written(2)
        asha, ben = self._candidate(questions), self._candidate(questions)
        self._grade(_Vertex(), asha)
        self._row().write({"expires_at": fields.Datetime.now()
                           + timedelta(seconds=30)})
        fake = _Vertex()
        self._grade(fake, ben)
        self.assertEqual(len(fake.creates()), 1)
        self._assert_cached(fake.calls()[0][1], self._row().resource_name)
        self.assertGreater(self._row().expires_at, fields.Datetime.now()
                           + timedelta(minutes=14))

    def test_a_failed_create_is_not_retried_for_ten_minutes(self):
        questions = self._written(2)
        asha, ben, cleo = (self._candidate(questions) for _ in range(3))
        fake = _Vertex(create_status=500)
        self._grade(fake, asha)
        self.assertEqual(len(fake.creates()), 1)
        self._assert_inline(fake.calls()[0][1])
        self.assertEqual(asha.response_ids.mapped("llm_attempts"), [1, 1])
        until = self._row().failed_until
        self.assertAlmostEqual(
            (until - fields.Datetime.now()).total_seconds(), 600, delta=5)

        fake = _Vertex()
        self._grade(fake, ben)
        self.assertFalse(fake.creates(), "not retried within 10 minutes")
        self._assert_inline(fake.calls()[0][1])

        self._row().write({"failed_until": fields.Datetime.now()
                           - timedelta(seconds=1)})
        fake = _Vertex()
        self._grade(fake, cleo)
        self.assertEqual(len(fake.creates()), 1)
        self.assertFalse(self._row().failed_until)

    def _grade_pinned(self, fake, ev):
        """As a pool worker grades: on a pinned bearer, here a lapsed one."""
        with self._vertex(fake), patch.object(
                vertex_svc, "_vertex_bearer", side_effect=lambda env: (
                    env.context.get("etp_vertex_bearer") or "tok")):
            ev.with_context(etp_vertex_bearer="tok-old")._action_llm_score()

    def _refused(self):
        return self._new("assessments.be.llm.usage",
                         [("note", "like", "[http:401")])

    def test_a_create_refused_a_pinned_bearer_is_resent_and_booked(self):
        questions = self._written(2)
        asha, _ben = self._candidate(questions), self._candidate(questions)
        fake = _Vertex(refuse={"Bearer tok-old"})
        self._grade_pinned(fake, asha)
        self.assertEqual(len(fake.creates()), 2, "resent once")
        self.assertFalse(self._row().failed_until)
        self._assert_cached(fake.calls()[-1][1], self._row().resource_name)
        self.assertEqual(sorted(self._refused().mapped("operation")),
                         ["score_subjective", "scoring_cache_create"],
                         "both first 401s are on the ledger")
        self.assertEqual(set(asha.response_ids.mapped("llm_state")),
                         {"scored"})

    def test_an_extend_refused_a_pinned_bearer_is_resent_and_booked(self):
        questions = self._written(2)
        asha, ben = self._candidate(questions), self._candidate(questions)
        self._grade(_Vertex(), asha)
        self._row().write({"expires_at": fields.Datetime.now()
                           + timedelta(minutes=4)})
        fake = _Vertex(refuse={"Bearer tok-old"})
        self._grade_pinned(fake, ben)
        self.assertEqual(len(fake.patches()), 2, "resent once")
        self.assertAlmostEqual(
            (self._row().expires_at - fields.Datetime.now()).total_seconds(),
            900, delta=5)
        self.assertIn("scoring_cache_refresh",
                      self._refused().mapped("operation"))

    def test_the_lane_that_loses_the_lock_grades_inline(self):
        questions = self._written(2)
        asha, _ben = self._candidate(questions), self._candidate(questions)
        fake = _Vertex()
        with patch.object(grading_cache, "_try_lock", return_value=False):
            self._grade(fake, asha)
        self.assertFalse(fake.creates())
        self._assert_inline(fake.calls()[0][1])
        self.assertEqual(set(asha.response_ids.mapped("llm_state")),
                         {"scored"})

    def test_the_fallback_model_never_uses_the_cache(self):
        self._set("fallback_model", FALLBACK)
        questions = self._written(2)
        asha, _ben = self._candidate(questions), self._candidate(questions)
        fake = _Vertex(call_statuses=[429])
        self._grade(fake, asha)
        (url1, first), (url2, second) = fake.calls()
        self.assertIn("/models/%s:" % MODEL, url1)
        self.assertIn("cachedContent", first)
        self.assertIn("/models/%s:" % FALLBACK, url2)
        self._assert_inline(second)
        self.assertEqual(set(asha.response_ids.mapped("llm_judge_model")),
                         {FALLBACK})


@tagged("-at_install", "post_install")
class TestACachesLifeIsBookedAndBounded(_Cohort):

    def _ledger(self, operation):
        return self._new("assessments.be.llm.usage",
                         [("operation", "=", operation)])

    def test_create_and_refresh_are_on_the_ledger_with_no_candidate(self):
        questions = self._written(2)
        asha, ben = self._candidate(questions), self._candidate(questions)
        self._grade(_Vertex(), asha)
        [create] = self._ledger("scoring_cache_create")
        self.assertFalse(create.evaluator_id)
        self.assertEqual((create.model, create.tokens_in), (MODEL, 5000))
        # 5,000 tokens at $2/1M input, plus 15 minutes at $4.50/1M/hour.
        self.assertAlmostEqual(create.cost_usd, 0.01 + 0.005625, delta=1e-5)

        self._row().write({"expires_at": fields.Datetime.now()
                           + timedelta(seconds=200)})
        self._grade(_Vertex(), ben)
        [refresh] = self._ledger("scoring_cache_refresh")
        self.assertFalse(refresh.evaluator_id)
        self.assertEqual(refresh.tokens_in, 0)
        # 900 s from now minus the 200 s that were left.
        self.assertAlmostEqual(refresh.cost_usd, 5000 * 4.5 * 700 / 3600 / 1e6,
                               delta=5000 * 4.5 * 3 / 3600 / 1e6)

    def test_a_cache_is_extended_only_when_under_five_minutes_remain(self):
        questions = self._written(2)
        asha, ben, cleo = (self._candidate(questions) for _ in range(3))
        self._grade(_Vertex(), asha)
        name = self._row().resource_name

        fake = _Vertex()
        self._grade(fake, ben)
        self.assertFalse(fake.patches(), "15 minutes left: not extended")

        self._row().write({"expires_at": fields.Datetime.now()
                           + timedelta(minutes=4)})
        fake = _Vertex()
        self._grade(fake, cleo)
        self.assertEqual(fake.patches(), [
            ("%s/%s?updateMask=ttl" % (HOST, name), {"ttl": "900s"})])
        self._assert_cached(fake.calls()[0][1], name)
        self.assertAlmostEqual(
            (self._row().expires_at - fields.Datetime.now()).total_seconds(),
            900, delta=5)

    def test_an_edited_question_gets_a_new_key(self):
        questions = self._written(2)
        asha = self._candidate(questions)
        group = SimpleNamespace(question_ids=tuple(questions.ids), create=True)

        def key():
            _s, job = scoring_svc._prepare_submission(
                self.env, asha.response_ids, cache_group=group)
            return job.cache.key

        first = key()
        self.assertEqual(key(), first, "the same material, the same key")
        questions[0].prompt += " Mind the wind load."
        second = key()
        self.assertNotEqual(second, first)
        questions[1].subjective_rubric_json = json.dumps(
            {"checklist": ["Names the wind load"]})
        self.assertNotIn(key(), (first, second))


@tagged("-at_install", "post_install")
class TestNothingACandidateWroteReachesACache(_Cohort):

    def _comparison(self):
        q = self.env["assessments.be.question"].create({
            "name": "AB %s" % uuid4().hex[:4], "question_type": "image_ab",
            "prompt": "Which response follows the brief?",
            "official_reasoning": "A keeps the logo; B warps it.",
            "generator_id": self.generator.id,
            "assessment_ids": [(4, self.paper.id)]})
        self.env["assessments.be.question.dimension"].create({
            "question_id": q.id, "name": "Overall Choice (OC)",
            "option_line_ids": [
                (0, 0, {"name": "Response A", "is_correct": True}),
                (0, 0, {"name": "Response B %s" % MARK, "is_correct": False}),
            ]})
        return q

    def _labelling(self):
        q = self.env["assessments.be.question"].create({
            "name": "Label %s" % uuid4().hex[:4],
            "question_type": "image_label", "prompt": "Label each box.",
            "subjective_rubric_json": json.dumps({"decoys": ["the red mug"]}),
            "generator_id": self.generator.id,
            "assessment_ids": [(4, self.paper.id)]})
        self.env["assessments.be.question.image"].create({
            "question_id": q.id, "label": "Plate", "slot": "single",
            "behavioural_key_json": json.dumps([
                {"number": 1, "element": "Search",
                 "functionality": "opens the search box"}])})
        return q

    def _prompt_writing(self):
        return self.env["assessments.be.question"].create({
            "name": "Prompt %s" % uuid4().hex[:4],
            "question_type": "image_prompt",
            "prompt": "Write the prompt for the reference image.",
            "subjective_rubric_json": json.dumps({
                "ideal_prompt": "A red bicycle against a brick wall",
                "mandatory_elements": ["red bicycle", "brick wall"],
                "penalty_rules": ["No text in the image"]}),
            "generator_id": self.generator.id,
            "assessment_ids": [(4, self.paper.id)]})

    def test_a_marker_in_every_candidate_field_reaches_no_cache(self):
        written = self._written(2)
        ab, label, prompt = (self._comparison(), self._labelling(),
                             self._prompt_writing())
        questions = written | ab | label | prompt
        asha = self._candidate(questions, answered=written,
                               name="Asha %s" % MARK,
                               email="%s@example.com" % MARK.lower(),
                               text="The braces carry it down; %s." % MARK)
        answer = {"assessment_id": self.paper.id,
                  "assessment_evaluator_id": asha.id,
                  "evaluator_id": asha.applicant_id.id,
                  "state": "submitted", "llm_state": "pending"}
        Response = self.env["assessments.be.response"]
        dim = ab.question_dimension_ids
        Response.create(dict(answer, question_id=ab.id, justification=(
            "B keeps the brief better %s." % MARK), line_ids=[(0, 0, {
                "question_dimension_id": dim.id,
                "selected_option_id": dim.option_line_ids.filtered(
                    lambda o: MARK in o.name).id})]))
        Response.create(dict(answer, question_id=label.id, justification=(
            json.dumps({"1": "search field %s" % MARK}))))
        Response.create(dict(answer, question_id=prompt.id, justification=(
            "A red bicycle by a brick wall, %s" % MARK)))
        fake = _Vertex()
        self._grade(fake, asha)

        [create] = fake.creates()
        self.assertNotIn(MARK, json.dumps(create, ensure_ascii=False))
        self.assertNotIn(MARK.lower(), json.dumps(create).lower())
        block = json.loads(create["contents"][0]["parts"][0]["text"][10:])
        self.assertEqual(sorted(q["question_id"] for q in block["questions"]),
                         sorted(questions.ids))
        for question in block["questions"]:
            self.assertLessEqual(set(question), MATERIAL_KEYS)
        [(_url, call)] = fake.calls()
        self.assertEqual(len(_items(_call_text(call))), 5)
        self.assertIn(MARK, json.dumps(call, ensure_ascii=False),
                      "the marker was planted where the call carries it")
        self.assertEqual(set(asha.response_ids.mapped("llm_state")),
                         {"scored"})
