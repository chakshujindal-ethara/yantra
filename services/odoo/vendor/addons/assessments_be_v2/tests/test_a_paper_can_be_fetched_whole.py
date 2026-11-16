# -*- coding: utf-8 -*-
"""A paper can be fetched whole: `POST /api/v1/exam/<token>/paper`.

WHY. Every question move of a sitting was one `/state?q=` or `/answer` that
built the next question, the largest remaining source of requests during an
exam. With `assessments_be_v2.paper_prefetch` on, `/state` and `/begin` say
`paper_prefetch: true` and the client fetches every question of the
candidate's paper once, then moves with no request.

What is held here, each with a case below:

* off (the default): no flag, and the route answers 404 `prefetch_off`;
* on: the flag on `/state` (before and during the sitting) and `/begin`;
* every question in the candidate's OWN (shuffled) order, each deep-equal to
  what `/state?q=N` serves for that index, the saved answer included, and no
  answer key anywhere; one `paper.fetch` audit line;
* refused like `/review`: not begun, submitted; and where `/state` serves no
  question: a closed paper, a clock that has run out;
* the SQL statements of `/paper` on a 10-question paper, cache off, cold and
  warm, beside ten `/state?q=N` moves.
"""
import json
import logging
import os
import random
import re
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import serializers as S
from ..services import audit
from ..services import question_cache as QC
from . import test_a_question_is_served_from_the_cache as cache_test
from . import test_a_sitting_stays_inside_its_write_budget as budget

_logger = logging.getLogger(__name__)

PARAM = "assessments_be_v2.paper_prefetch"
#: A key named like any of these anywhere in the paper is answer material.
#: (`answer` itself is the candidate's own saved answer, served today.)
FORBIDDEN_KEY = re.compile(
    r"correct|solution|reasoning|rubric|grading|golden|ideal", re.I)

_Budget = getattr(budget, "TestASittingStaysInsideItsWriteBudget")
_Cache = getattr(cache_test, "TestAQuestionIsServedFromTheCache")


def _plain(value):
    """JSON in, JSON out: what the client receives."""
    return json.loads(json.dumps(value))


@tagged("-at_install", "post_install")
class TestAPaperCanBeFetchedWhole(TransactionCase):

    #: The write-budget sitting at ten questions (nine mcq, one written), and
    #: its request helpers, reused rather than copied.
    QUESTIONS = 10
    _question = _Budget._question
    _sitting = _Budget._sitting
    _call = _Budget._call
    _answer = _Budget._answer
    _count_queries = _Cache._count_queries

    def setUp(self):
        super().setUp()
        cache_test._isolate(self)
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Applicant = self.env["hr.applicant"]
        self.controller = _Budget._controller()
        self.session_key = uuid4().hex
        self.stamps = {}

    def _prefetch(self, on):
        self.icp.set_param(PARAM, "1" if on else "")

    def _begun(self, order=None):
        """A begun sitting; `order` replaces the candidate's question order."""
        _assessment, evaluator, questions, user = self._sitting()
        if order is not None:
            evaluator.write({"question_order": json.dumps(order(questions))})
        begun = self._call("exam_begin", evaluator, user)
        self.assertTrue(begun.get("ok"), begun)
        return evaluator, questions, user

    def _paper(self, evaluator, user):
        return self._call("exam_paper", evaluator, user)

    @staticmethod
    def _code(reply):
        return reply.get("__status"), (reply.get("error") or {}).get("code")

    # -- off ------------------------------------------------------------

    def test_off_says_nothing_and_the_route_is_404(self):
        self._prefetch(False)
        _assessment, evaluator, _questions, user = self._sitting()
        for route in ("exam_state", "exam_begin", "exam_state"):
            reply = self._call(route, evaluator, user)
            self.assertTrue(reply.get("ok"), reply)
            self.assertNotIn("paper_prefetch", reply["data"], route)
        self.assertEqual(self._code(self._paper(evaluator, user)),
                         (404, "prefetch_off"))

    # -- on -------------------------------------------------------------

    def test_on_both_routes_carry_the_flag(self):
        self._prefetch(True)
        _assessment, evaluator, _questions, user = self._sitting()
        for route, outcome in (("exam_state", "instructions"),
                               ("exam_begin", "question"),
                               ("exam_state", "question")):
            reply = self._call(route, evaluator, user)
            self.assertTrue(reply.get("ok"), reply)
            self.assertEqual(reply["data"]["outcome"], outcome)
            self.assertIs(reply["data"].get("paper_prefetch"), True, route)
        # The Odoo form's own spelling of "on" counts too.
        self.icp.set_param(PARAM, "True")
        reply = self._call("exam_state", evaluator, user)
        self.assertIs(reply["data"].get("paper_prefetch"), True)

    def test_the_paper_is_every_question_as_state_serves_it(self):
        """Shuffled order, every question type, two saved answers: each
        entry deep-equal to `/state?q=N`, and no answer key anywhere."""
        self._prefetch(True)
        typed = cache_test._paper(self.env, self.generator)
        order = [q.id for q in typed.values()]
        random.Random(7).shuffle(order)
        evaluator, questions, user = self._begun(order=lambda _q: order)
        mcq = typed["mcq"]
        right = mcq.question_dimension_ids.option_line_ids.filtered(
            "is_correct")[:1]
        saved = self._call("exam_answer", evaluator, user, nav="stay",
                           question_id=mcq.id, selected_option_ids=right.ids,
                           updated_at=1_800_000_000_000)
        self.assertTrue(saved.get("ok"), saved)

        with patch.object(audit, "emit", wraps=audit.emit) as emitted:
            reply = self._paper(evaluator, user)
        self.assertTrue(reply.get("ok"), reply)
        data = _plain(reply["data"])
        paper = data["questions"]
        self.assertEqual([q["id"] for q in paper], order)
        self.assertEqual([(q["index"], q["total"]) for q in paper],
                         [(i + 1, len(order)) for i in range(len(order))])
        self.assertEqual(data["total"], len(order))
        self.assertEqual(data["answered_question_ids"], [mcq.id])
        mine = paper[order.index(mcq.id)]["answer"]
        self.assertTrue(mine["answered"])
        self.assertEqual(mine["selected_option_ids"], right.ids)

        for n, entry in enumerate(paper, start=1):
            state = self._call("exam_state", evaluator, user, q=n)
            self.assertTrue(state.get("ok"), state)
            self.assertEqual(entry, _plain(state["data"]["question"]),
                             "question %d differs from /state?q=%d" % (n, n))

        blob = json.dumps(data)
        bad = sorted({k for k in cache_test._walk_keys(data)
                      if FORBIDDEN_KEY.search(k)})
        self.assertFalse(bad, "answer material in the paper under %s" % bad)
        for secret in cache_test.SECRETS:
            self.assertNotIn(secret, blob)

        [line] = [c for c in emitted.call_args_list
                  if c.args[0] == "paper.fetch"]
        self.assertEqual(line.kwargs["count"], len(order))
        # No size: measuring it serialised the whole paper a second time.
        self.assertNotIn("bytes", line.kwargs)

    # -- refused --------------------------------------------------------

    def test_not_begun_is_refused(self):
        self._prefetch(True)
        _assessment, evaluator, _questions, user = self._sitting()
        self.assertEqual(self._code(self._paper(evaluator, user)),
                         (409, "not_started"))

    def test_a_submitted_attempt_is_refused(self):
        self._prefetch(True)
        evaluator, _questions, user = self._begun()
        submitted = self._call("exam_submit", evaluator, user, force=True)
        self.assertTrue(submitted.get("ok"), submitted)
        self.assertEqual(self._code(self._paper(evaluator, user)),
                         (409, "attempt_locked"))

    def test_a_closed_paper_or_a_spent_clock_serves_nothing(self):
        self._prefetch(True)
        evaluator, _questions, user = self._begun()
        evaluator.assessment_id.write({"state": "done"})
        self.assertEqual(self._code(self._paper(evaluator, user)),
                         (409, "assessment_closed"))
        evaluator.assessment_id.write({"state": "in_progress"})
        evaluator.write({"started_at": fields.Datetime.now()
                         - timedelta(hours=2)})
        self.env.flush_all()
        self.assertEqual(self._code(self._paper(evaluator, user)),
                         (409, "time_expired"))
        self.assertFalse(evaluator.is_locked, "a read settles nothing")

    def test_the_cache_serves_the_paper_in_one_round_trip(self):
        """Cache on: the same paper as off, from one pipelined read (plus
        one pipelined fill when cold); a dead Redis serves it from Postgres
        with one warning and one attempt, not one per question."""
        self._prefetch(True)
        evaluator, questions, user = self._begun()
        self.assertTrue(self._answer(evaluator, user, questions[0])["ok"])
        off = self._paper(evaluator, user)["data"]
        url = "redis://fake-%s:6379/0" % uuid4().hex[:6]
        fake = cache_test.FakeRedis()
        QC._clients[url] = fake
        self.addCleanup(QC._clients.pop, url, None)
        self.icp.set_param(QC.URL_PARAM, url)
        for label, trips in (("cold", 2), ("warm", 1)):
            with self.subTest(label):
                before = fake.executes
                self.assertEqual(self._paper(evaluator, user)["data"], off)
                self.assertEqual(fake.executes - before, trips)
                self.assertEqual(len(fake.content_keys()), 10)
        fake.down = True
        attempts = []
        check = fake._check
        fake._check = lambda: (attempts.append(1), check())[1]
        with self.assertLogs(cache_test.QC_LOGGER, "WARNING"):
            self.assertEqual(self._paper(evaluator, user)["data"], off)
        self.assertEqual(len(attempts), 1)

    # -- what it costs --------------------------------------------------

    def test_paper_query_count_for_ten_questions(self):
        """The SQL statements of one `/paper` on a 10-question paper with the
        ORM cache empty, as at the start of a request: question cache off,
        on and cold, on and warm; beside ten `/state?q=N` moves, cache off."""
        self._prefetch(True)
        evaluator, questions, user = self._begun()
        self.assertTrue(self._answer(evaluator, user, questions[0])["ok"])
        counts = {}

        def measure(label):
            self.env.invalidate_all()
            with self._count_queries() as queries:
                reply = self._paper(evaluator, user)
            self.assertTrue(reply.get("ok"), reply)
            self.assertEqual(len(reply["data"]["questions"]), 10)
            counts[label] = queries["n"]

        moves = 0
        for n in range(1, 11):
            self.env.invalidate_all()
            with self._count_queries() as queries:
                self.assertTrue(
                    self._call("exam_state", evaluator, user, q=n)["ok"])
            moves += queries["n"]
        measure("off")
        # On through REDIS_URL, not the setting: `set_param` empties the
        # registry caches and the next call would pay for their refill.
        url = "redis://fake-%s:6379/0" % uuid4().hex[:6]
        fake = cache_test.FakeRedis()
        QC._clients[url] = fake
        self.addCleanup(QC._clients.pop, url, None)
        os.environ["REDIS_URL"] = url
        measure("cold")
        S.warm_question_cache(questions)
        measure("warm")
        _logger.info(
            "paper prefetch /paper statements, 10 questions: off=%s cold=%s "
            "warm=%s; ten /state?q=N moves (cache off)=%s",
            counts["off"], counts["cold"], counts["warm"], moves)
        self.assertLess(counts["warm"], counts["cold"], counts)
        self.assertLess(counts["off"], moves,
                        "one /paper must cost less than ten moves")
