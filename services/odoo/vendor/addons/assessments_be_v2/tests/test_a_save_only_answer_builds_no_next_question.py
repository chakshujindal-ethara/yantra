"""`nav="stay"` saves the answer and composes nothing else (SNo 147).

WHAT THE DEFAULT COSTS. Every `/answer` ends by building the NEXT question -
its prompt, its dimensions and options, and a signed URL per image and per clip.
Measured on the real endpoint, one call costs 24 queries and that build is the
largest single share of them.

THE DEBOUNCED AUTOSAVE NEVER LOOKS AT IT. It fires while the candidate is
typing, throws the response away by design (`_syncAnswer` exists to protect the
caret, not to navigate), and is the most frequent call the runner makes. So the
paper's next question was assembled, serialized and signed over and over for a
client that had already discarded the previous copy. The submit re-send loop is
the same: nothing follows those calls except the submit itself.

WHY A SENTINEL AND NOT "GUESS FROM THE ABSENCE OF nav". The route's default IS
`next`, and a client that omits the field still means next - an older bundle
must keep working. Only a caller that explicitly asks for nothing gets nothing.

WHAT THIS PINS: that it saves, that it composes no next question, that it is
measurably cheaper, and - the one that matters for correctness - that it still
reports an attempt somebody else has closed underneath it.
"""
import json
from contextlib import contextmanager
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestASaveOnlyAnswerBuildsNoNextQuestion(TransactionCase):

    QUESTIONS = 4

    def setUp(self):
        super().setUp()
        self.controller = self._controller()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Nav sentinel %s" % uuid4().hex[:6]})

    @staticmethod
    def _controller():
        import inspect

        from odoo import http

        from ..controllers.api import candidate as candidate_api
        for _name, obj in vars(candidate_api).items():
            if (inspect.isclass(obj) and issubclass(obj, http.Controller)
                    and obj.__module__ == candidate_api.__name__
                    and hasattr(obj, "exam_answer")):
                return obj()
        raise AssertionError("the candidate controller was not found")

    @contextmanager
    def _count(self):
        counted = {"n": 0}
        cr = self.env.cr
        original = cr.execute

        def spy(query, params=None, **kw):
            counted["n"] += 1
            if params is not None:
                return original(query, params, **kw)
            return original(query, **kw)

        cr.execute = spy
        try:
            yield counted
        finally:
            cr.execute = original

    def _question(self, n):
        q = self.env["assessments.be.question"].create({
            "name": "Nav Q%d %s" % (n, uuid4().hex[:4]),
            "question_type": "mcq", "prompt": "Pick one",
            "difficulty": "easy", "sequence": n * 10,
            "generator_id": self.generator.id,
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": q.id, "name": "Answer",
            "option_line_ids": [(0, 0, {"name": name, "sequence": j * 10,
                                        "is_correct": j == 0})
                                for j, name in enumerate(("Alpha", "Bravo"))],
        })
        # A PLATE ON EVERY QUESTION, because the plates are the point: the
        # next-question build signs a URL per image, and a text-only paper
        # would make the two navs cost almost the same and prove nothing.
        self.env["assessments.be.question.image"].create({
            "question_id": q.id, "slot": "single", "label": "Plate",
            "image_url": "https://cdn.example.com/p/%d.png" % n,
        })
        return q

    def _sitting(self):
        questions = self.env["assessments.be.question"].browse()
        for n in range(self.QUESTIONS):
            questions |= self._question(n)
        assessment = self.env["assessments.be"].create({
            "name": "Nav paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, questions.ids)],
            "question_limit": self.QUESTIONS,
            "duration_minutes": 60, "state": "in_progress",
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Nav Sitter",
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id, "applicant_id": applicant.id,
            "question_order": json.dumps(questions.ids),
            "access_token": uuid4().hex})
        assessment.sudo()._ensure_candidate_user(applicant)
        user = evaluator.sudo()._candidate_user()
        self.assertTrue(user, "no portal user: every write would be refused")
        return evaluator, questions, user

    def _call(self, route, evaluator, user, **params):
        from ..controllers.api import candidate as candidate_api
        from ..controllers.api import common as api_common

        env = self.env(user=user)

        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(env, params)
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            return getattr(self.controller, route)(
                evaluator.access_token, **params)

    @staticmethod
    def _data(out):
        """The payload body. `ok()` nests it under `data`; a first version of
        this file read the top level and reported a correct response as a
        missing one."""
        return (out or {}).get("data") or {}

    def _answer(self, evaluator, user, question, nav):
        option = question.question_dimension_ids[:1].option_line_ids.filtered(
            "is_correct")[:1]
        return self._call("exam_answer", evaluator, user,
                          question_id=question.id,
                          selected_option_ids=option.ids, nav=nav)

    # ── the contract ──────────────────────────────────────────────────

    def test_it_saves_and_returns_no_next_question(self):
        evaluator, questions, user = self._sitting()
        self._call("exam_begin", evaluator, user)

        out = self._answer(evaluator, user, questions[0], "stay")

        self.assertTrue(out.get("ok"), "the answer was refused: %r" % (out,))
        body = self._data(out)
        self.assertTrue(body.get("saved"), "the answer was not stored")
        self.assertIsNone(
            body.get("next"),
            "a save-only call still composed the next question, which is the "
            "whole cost it exists to avoid")

    def test_the_answer_really_reached_the_database(self):
        """A cheap call that saved nothing would pass every test above."""
        evaluator, questions, user = self._sitting()
        self._call("exam_begin", evaluator, user)
        self._answer(evaluator, user, questions[0], "stay")
        self.env.flush_all()

        stored = self.env["assessments.be.response"].search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "=", questions[0].id)])
        self.assertTrue(stored, "nav=stay saved nothing at all")
        self.assertTrue(stored.line_ids, "the chosen option was not stored")

    # ── the saving ────────────────────────────────────────────────────

    def test_it_is_measurably_cheaper_than_navigating(self):
        """THE POINT. Asserted as a comparison, not a fixed number.

        A query count pinned to a literal teaches the next person to edit the
        literal. What has to stay true is that not building a thing costs less
        than building it.
        """
        ev_a, qs_a, user_a = self._sitting()
        self._call("exam_begin", ev_a, user_a)
        with self._count() as navigated:
            self._answer(ev_a, user_a, qs_a[0], "next")
            self.env.flush_all()

        ev_b, qs_b, user_b = self._sitting()
        self._call("exam_begin", ev_b, user_b)
        with self._count() as stayed:
            self._answer(ev_b, user_b, qs_b[0], "stay")
            self.env.flush_all()

        self.assertLess(
            stayed["n"], navigated["n"],
            "nav=stay cost %d queries against nav=next's %d - the sentinel is "
            "not short-circuiting the next-question build"
            % (stayed["n"], navigated["n"]))

    # ── the case that must NOT be optimised away ──────────────────────

    def test_a_settled_attempt_is_still_reported(self):
        """The one thing a save-only call must still be told.

        An attempt can be closed under an open runner by the expiry cron or the
        violation cap. A client that keeps writing is not misbehaving - it has
        not been told - and being told once is what stops it walking on to a
        question that refuses every keystroke. The sentinel returns BEFORE the
        next-question build and AFTER the settlement check, deliberately.
        """
        evaluator, questions, user = self._sitting()
        self._call("exam_begin", evaluator, user)
        evaluator.sudo().write({"state": "submitted"})
        self.env.flush_all()

        out = self._answer(evaluator, user, questions[0], "stay")
        self.assertTrue(
            self._data(out).get("attempt_closed"),
            "a save-only call was not told the attempt had been settled, so "
            "the runner would keep writing into a locked sitting: %r" % (out,))
