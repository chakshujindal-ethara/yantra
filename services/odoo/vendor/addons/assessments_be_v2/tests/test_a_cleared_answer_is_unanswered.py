"""An emptied answer is sent and stored as cleared, and is unanswered.

THE CONTRACT. `/answer` takes `{question_id, cleared: true, updated_at?,
session_key?, nav?}` and a batch item `{question_id, cleared: true,
updated_at?}`. A stored answer loses its options, text and grade, is marked
`cleared` and goes back to draft, so it is neither graded nor counted; the
stale rule of a normal save applies. A clear with no row yet is stored as a
cleared row carrying its stamp, so an older first save from the same session
is `stale`. A later real answer refills the same row. At submit the row becomes the
question's placeholder in place (no duplicate, never graded), and `/review`
lists the question as not answered.
"""
import json
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAClearedAnswerIsUnanswered(TransactionCase):

    QUESTIONS = 3
    SESSION = "tab-one"

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.Response = self.env["assessments.be.response"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Clear fixture %s" % uuid4().hex[:6]})
        self.controller = self._controller()

    @staticmethod
    def _controller():
        import inspect

        from odoo import http

        from ..controllers.api import candidate as candidate_api
        for _name, obj in vars(candidate_api).items():
            if (inspect.isclass(obj) and issubclass(obj, http.Controller)
                    and obj.__module__ == candidate_api.__name__
                    and hasattr(obj, "exam_answers_batch")):
                return obj()
        raise AssertionError("the candidate controller was not found")

    # ── fixtures (as test_a_paper_can_be_saved_in_one_batch) ──────────

    def _question(self, n, qtype="mcq"):
        question = self.Question.create({
            "name": "Q%d %s" % (n, uuid4().hex[:4]),
            "question_type": qtype,
            "prompt": "Pick one",
            "difficulty": "easy",
            "sequence": n * 10,
            "generator_id": self.generator.id,
        })
        if qtype == "mcq":
            self.env["assessments.be.question.dimension"].create({
                "question_id": question.id,
                "name": "Answer",
                "option_line_ids": [
                    (0, 0, {"name": name, "sequence": j * 10,
                            "is_correct": j == 0})
                    for j, name in enumerate(("Alpha", "Bravo"))
                ],
            })
        return question

    def _sitting(self, last="mcq"):
        questions = self.Question.browse()
        for n in range(self.QUESTIONS):
            questions |= self._question(
                n, last if n == self.QUESTIONS - 1 else "mcq")
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, questions.ids)],
            "question_limit": self.QUESTIONS,
            "duration_minutes": 60,
            "state": "in_progress",
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Clear Sitter",
            "email_from": "%s@example.com" % uuid4().hex[:10],
        })
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": json.dumps(questions.ids),
            "access_token": uuid4().hex,
            "started_at": fields.Datetime.now(),
            "state": "in_progress",
        })
        assessment.sudo()._ensure_candidate_user(applicant)
        user = evaluator.sudo()._candidate_user()
        self.assertTrue(user, "no portal user: every call would be a 403")
        self.env.flush_all()
        return evaluator, questions, user

    def _call(self, route, evaluator, user, **params):
        from ..controllers.api import candidate as candidate_api
        from ..controllers.api import common as api_common

        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        self.env.cr._now = self.env.cr.now() + timedelta(seconds=1)
        params.setdefault("session_key", self.SESSION)
        fake = _Req(self.env(user=user), params)
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            reply = getattr(self.controller, route)(
                evaluator.access_token, **fake.params)
        self.env.flush_all()
        return reply

    def _answer(self, evaluator, user, question, stamp, **extra):
        option = question.question_dimension_ids[:1].option_line_ids.filtered(
            "is_correct")[:1]
        return self._call("exam_answer", evaluator, user,
                          question_id=question.id, nav="stay",
                          selected_option_ids=option.ids, updated_at=stamp,
                          **extra)

    def _clear(self, evaluator, user, question, stamp, **extra):
        return self._call("exam_answer", evaluator, user,
                          question_id=question.id, cleared=True, nav="stay",
                          updated_at=stamp, **extra)

    def _row(self, evaluator, question):
        return self.Response.search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "=", question.id)])

    def _assert_cleared(self, row):
        self.assertEqual(len(row), 1)
        self.assertTrue(row.cleared)
        self.assertEqual(row.state, "draft")
        self.assertFalse(row.line_ids)
        self.assertFalse(row.justification)
        self.assertFalse(row._is_answered())

    # ── /answer ───────────────────────────────────────────────────────

    def test_a_clear_through_answer_empties_the_row(self):
        from ..controllers.api import candidate as candidate_api

        evaluator, questions, user = self._sitting()
        q = questions[0]
        self._answer(evaluator, user, q, 1_800_000_000_000)
        self.assertEqual(evaluator.answered_count, 1)
        row = self._row(evaluator, q)

        with patch.object(candidate_api.audit, "emit") as emit:
            reply = self._clear(evaluator, user, q, 1_800_000_000_001)

        self.assertTrue(reply.get("ok"), reply)
        self.assertEqual(reply["data"]["saved"], True)
        self.assertEqual(reply["data"]["cleared"], True)
        self._assert_cleared(row)
        self.assertEqual(row.client_updated_at, 1_800_000_000_001,
                         "a clear records its stamp like a save")
        self.assertEqual(row.client_session_key, self.SESSION)
        self.assertEqual(evaluator.answered_count, 0)
        outcomes = [c.kwargs.get("outcome") for c in emit.call_args_list
                    if c.args and c.args[0] == "exam.answer"]
        self.assertEqual(outcomes, ["cleared"])

    def test_a_clear_before_any_save_is_stored_and_wins_in_its_session(self):
        """The clear overtook an OLDER first save of the same question. It is
        stored as a cleared row with its stamp, so that save, landing after
        it from the same session, is `stale`; from another session the last
        write wins."""
        evaluator, questions, user = self._sitting()
        q = questions[0]
        reply = self._clear(evaluator, user, q, 1_800_000_000_002)
        self.assertTrue(reply.get("ok"), reply)
        self.assertEqual(reply["data"]["cleared"], True)
        row = self._row(evaluator, q)
        self._assert_cleared(row)
        self.assertEqual(row.client_updated_at, 1_800_000_000_002)
        self.assertEqual(row.client_session_key, self.SESSION)

        older = self._answer(evaluator, user, q, 1_800_000_000_001)

        self.assertTrue(older.get("ok"), older)
        self._assert_cleared(row)
        self.assertEqual(row.client_updated_at, 1_800_000_000_002)
        self.assertEqual(evaluator.answered_count, 0)

        other_tab = self._answer(evaluator, user, q, 1_800_000_000_001,
                                 session_key="tab-two")

        self.assertTrue(other_tab.get("ok"), other_tab)
        self.assertEqual(self._row(evaluator, q), row, "the same row")
        self.assertFalse(row.cleared)
        self.assertEqual(row.state, "submitted")
        self.assertTrue(row.line_ids)
        self.assertEqual(row.client_session_key, "tab-two")
        self.assertEqual(evaluator.answered_count, 1)

    def test_a_clear_before_any_save_then_submit_is_one_blank_row(self):
        evaluator, questions, user = self._sitting()
        self._answer(evaluator, user, questions[0], 1_800_000_000_000)
        self._answer(evaluator, user, questions[2], 1_800_000_000_000)
        self._clear(evaluator, user, questions[1], 1_800_000_000_000)
        row = self._row(evaluator, questions[1])
        self._assert_cleared(row)

        review = self._call("exam_review", evaluator, user)["data"]
        self.assertEqual(review["unanswered"], [questions[1].id])

        reply = self._call("exam_submit", evaluator, user, force=True)

        self.assertTrue(reply.get("ok"), reply)
        self.assertEqual(self._row(evaluator, questions[1]), row,
                         "no duplicate placeholder")
        self.assertTrue(row.auto_submitted)
        self.assertEqual(row.llm_state, "not_needed")
        self.assertFalse(row._is_answered())
        self.assertEqual(evaluator.answered_count, 2)

    def test_a_real_answer_refills_the_same_row(self):
        evaluator, questions, user = self._sitting()
        q = questions[0]
        self._answer(evaluator, user, q, 1_800_000_000_000)
        row = self._row(evaluator, q)
        self._clear(evaluator, user, q, 1_800_000_000_001)

        reply = self._answer(evaluator, user, q, 1_800_000_000_002)

        self.assertTrue(reply.get("ok"), reply)
        self.assertNotIn("cleared", reply["data"])
        self.assertEqual(self._row(evaluator, q), row, "the same row")
        self.assertFalse(row.cleared)
        self.assertEqual(row.state, "submitted")
        self.assertTrue(row.line_ids)
        self.assertEqual(evaluator.answered_count, 1)

    # ── the batch, and the stale rule ─────────────────────────────────

    def test_a_batch_item_clears_and_an_older_clear_is_stale(self):
        evaluator, questions, user = self._sitting()
        first, second = questions[0], questions[1]
        self._answer(evaluator, user, first, 1_800_000_000_005)
        self._answer(evaluator, user, second, 1_800_000_000_005)

        reply = self._call("exam_answers_batch", evaluator, user, answers=[
            {"question_id": first.id, "cleared": True,
             "updated_at": 1_800_000_000_006},
            # Older than the stored save from this same session.
            {"question_id": second.id, "cleared": True,
             "updated_at": 1_800_000_000_004},
            {"question_id": questions[2].id, "cleared": True},
        ])

        self.assertTrue(reply.get("ok"), reply)
        self.assertEqual(reply["data"]["results"], [
            {"question_id": first.id, "accepted": True, "reason": "cleared"},
            {"question_id": second.id, "accepted": True, "reason": "stale"},
            {"question_id": questions[2].id, "accepted": True,
             "reason": "cleared"}])
        self._assert_cleared(self._row(evaluator, first))
        kept = self._row(evaluator, second)
        self.assertEqual(kept.state, "submitted", "a stale clear wrote")
        self.assertTrue(kept.line_ids)
        self.assertFalse(kept.cleared)
        self.assertEqual(kept.client_updated_at, 1_800_000_000_005)
        self._assert_cleared(self._row(evaluator, questions[2]))
        self.assertEqual(evaluator.answered_count, 1)

        # Same rule on /answer: a stale clear is acknowledged, not applied.
        stale = self._clear(evaluator, user, second, 1_800_000_000_003)
        self.assertTrue(stale.get("ok"), stale)
        self.assertNotIn("cleared", stale["data"])
        self.assertEqual(kept.state, "submitted")

    # ── review, submit, scoring ───────────────────────────────────────

    def test_review_lists_a_cleared_question_as_not_answered(self):
        evaluator, questions, user = self._sitting()
        for q in questions:
            self._answer(evaluator, user, q, 1_800_000_000_000)
        self._clear(evaluator, user, questions[1], 1_800_000_000_001)

        review = self._call("exam_review", evaluator, user)["data"]

        flags = {r["question_id"]: r["answered"] for r in review["rows"]}
        self.assertEqual(flags, {questions[0].id: True,
                                 questions[1].id: False,
                                 questions[2].id: True})
        self.assertEqual(review["answered_count"], 2)
        self.assertEqual(review["unanswered"], [questions[1].id])

        refused = self._call("exam_submit", evaluator, user)
        self.assertEqual((refused.get("error") or {}).get("code"),
                         "incomplete_attempt", refused)
        self.assertEqual(refused.get("unanswered"), [questions[1].id])

    def test_submit_turns_the_cleared_row_into_its_placeholder(self):
        evaluator, questions, user = self._sitting()
        for q in questions:
            self._answer(evaluator, user, q, 1_800_000_000_000)
        row = self._row(evaluator, questions[1])
        self._clear(evaluator, user, questions[1], 1_800_000_000_001)

        reply = self._call("exam_submit", evaluator, user, force=True)

        self.assertTrue(reply.get("ok"), reply)
        self.assertTrue(evaluator.is_locked)
        self.assertEqual(self._row(evaluator, questions[1]), row,
                         "no duplicate placeholder")
        self.assertEqual(row.state, "submitted")
        self.assertTrue(row.auto_submitted)
        self.assertTrue(row.cleared)
        self.assertFalse(row.needs_llm)
        self.assertEqual(row.llm_state, "not_needed")
        self.assertFalse(row._is_answered())
        self.assertEqual(evaluator.answered_count, 2)
        self.assertEqual(row.final_mark, 0)

    #: What a grader run leaves on an answer (`services/scoring.py`
    #: `_store_scored`); a clear must take every one of them away.
    GRADE = {"llm_state": "scored", "llm_raw_100": 90.0,
             "llm_feedback": "Clear and correct.", "llm_verdict": "Pass",
             "llm_reasoning": "Matches the reference.",
             "llm_deductions_json": "[]", "llm_credit_json": "[]",
             "label_box_scores_json": "{}", "llm_judge_model": "judge-x"}

    def test_a_graded_written_answer_cleared_then_submitted_has_no_grade(self):
        from ..services import scoring as scoring_svc

        evaluator, questions, user = self._sitting(last="subjective_rubric")
        evaluator.assessment_id.llm_auto_score = True
        written = questions[-1]
        for q in questions[:-1]:
            self._answer(evaluator, user, q, 1_800_000_000_000)
        saved = self._call("exam_answer", evaluator, user,
                           question_id=written.id, nav="stay",
                           justification="The cup stays upright.",
                           updated_at=1_800_000_000_000)
        self.assertTrue(saved.get("ok"), saved)
        row = self._row(evaluator, written)
        self.assertTrue(row.needs_llm)
        self.assertEqual(row.llm_state, "pending")
        # Graded mid-sitting: the mark and its prose must go with the text.
        row.sudo().write(self.GRADE)
        evaluator._compute_subjective_rollup()
        self.env.flush_all()
        self.assertEqual(row.final_mark, 1)
        self.assertEqual(evaluator.score_percent, 100.0,
                         "the fixture is not fully marked before the clear")

        self._clear(evaluator, user, written, 1_800_000_000_001)

        self._assert_cleared(row)
        self.assertFalse(row.needs_llm)
        self.assertEqual(row.final_mark, 0)
        self.assertEqual(row.llm_state, "not_needed")
        for field in set(self.GRADE) - {"llm_state"}:
            self.assertFalse(row[field], "%s survived the clear" % field)
        self.assertFalse(self.Response.search([
            ("id", "=", row.id), ("needs_llm", "=", True)]),
            "the scoring queue's domain still selects it")
        self.assertEqual(evaluator.subjective_pending, 0)
        self.assertEqual(evaluator.llm_total_score, 0)

        # A grade that was in flight lands after the clear: it is dropped.
        scoring_svc._store_scored(row, {"score": 95, "feedback": "Late."})
        self.assertEqual(row.llm_state, "not_needed")
        self.assertFalse(row.llm_raw_100)
        self.assertFalse(row.llm_feedback)

        reply = self._call("exam_submit", evaluator, user, force=True)

        self.assertTrue(reply.get("ok"), reply)
        self.assertTrue(row.auto_submitted)
        self.assertEqual(row.llm_state, "not_needed")
        self.assertFalse(row.llm_raw_100)
        self.assertEqual(evaluator.llm_state, "scored",
                         "nothing is left for the grader")
        self.assertEqual(evaluator.score_percent, round(200.0 / 3, 2))
        self.assertEqual(evaluator.raw_result, 2.0)
        self.assertEqual(evaluator.answered_count, 2)

    def test_a_late_grade_on_a_cleared_row_is_not_in_the_raw_at_submit(self):
        """Settlement zeroes `llm_raw_100` on a cleared row, so a grade written
        onto it after the clear (outside `_store_scored`) cannot inflate
        `raw_result`."""
        evaluator, questions, user = self._sitting(last="subjective_rubric")
        written = questions[-1]
        self._call("exam_answer", evaluator, user, question_id=written.id,
                   nav="stay", justification="The cup stays upright.",
                   updated_at=1_800_000_000_000)
        self._clear(evaluator, user, written, 1_800_000_000_001)
        row = self._row(evaluator, written)
        row.sudo().write({"llm_raw_100": 80.0})
        self.env.flush_all()

        self._call("exam_submit", evaluator, user, force=True)

        self.assertFalse(row.llm_raw_100)
        self.assertEqual(evaluator.raw_result, 0.0)

    # ── races and guards ──────────────────────────────────────────────

    def test_a_clear_racing_a_first_save_folds_in(self):
        """The clear's INSERT loses the unique index to a sibling's first
        save. Sibling not yet visible: `concurrent`, nothing stored. Sibling
        visible after the collision: the clear folds into it. Either way no
        duplicate and no error to the client."""
        from psycopg2 import IntegrityError

        evaluator, questions, user = self._sitting()
        Model = type(self.Response)
        clash = patch.object(Model, "create", side_effect=IntegrityError(
            "duplicate key value violates unique constraint"))

        with clash:
            reply = self._clear(evaluator, user, questions[0],
                                1_800_000_000_002)
        self.assertTrue(reply.get("ok"), reply)
        self.assertIs(reply["data"].get("concurrent"), True, reply)
        self.assertFalse(self._row(evaluator, questions[0]))

        q = questions[1]
        self._answer(evaluator, user, q, 1_800_000_000_001)
        sibling = self._row(evaluator, q)
        real_search = Model.search
        hidden = {"done": False}
        lookup = [("question_id", "=", q.id),
                  ("assessment_evaluator_id", "=", evaluator.id)]

        def search(model, domain, *args, **kwargs):
            # The sibling's row is invisible to the first look only, as an
            # uncommitted INSERT is under READ COMMITTED.
            if list(domain) == lookup and not hidden["done"]:
                hidden["done"] = True
                return model.browse()
            return real_search(model, domain, *args, **kwargs)

        with clash, patch.object(Model, "search", search):
            reply = self._clear(evaluator, user, q, 1_800_000_000_002)
        self.assertTrue(hidden["done"], "the race was not exercised")
        self.assertTrue(reply.get("ok"), reply)
        self.assertIs(reply["data"].get("cleared"), True, reply)
        self.assertEqual(self._row(evaluator, q), sibling, "no duplicate")
        self._assert_cleared(sibling)

    def test_a_clear_with_an_out_of_range_stamp_is_unstamped(self):
        evaluator, questions, user = self._sitting()
        q = questions[0]
        self._answer(evaluator, user, q, 1_800_000_000_005)
        row = self._row(evaluator, q)

        reply = self._clear(evaluator, user, q, 1e300)

        self.assertIs(reply["data"].get("cleared"), True, reply)
        self._assert_cleared(row)
        self.assertEqual(row.client_updated_at, 0.0,
                         "read as absent, so the stamp is replaced by none")
        # Unstamped on record: an older stamped save is no longer stale.
        self._answer(evaluator, user, q, 1_800_000_000_001)
        self.assertEqual(row.state, "submitted")
        self.assertFalse(row.cleared)

    def test_a_clear_from_a_replaced_session_is_refused(self):
        evaluator, questions, user = self._sitting()
        q = questions[0]
        self._answer(evaluator, user, q, 1_800_000_000_000)
        row = self._row(evaluator, q)
        evaluator.exam_session_key = "tab-new"
        self.env.flush_all()

        reply = self._clear(evaluator, user, q, 1_800_000_000_001,
                            session_key="tab-old")

        self.assertEqual(reply.get("__status"), 409, reply)
        self.assertEqual((reply.get("error") or {}).get("code"),
                         "session_replaced")
        self.assertEqual(row.state, "submitted")
        self.assertFalse(row.cleared)
        self.assertTrue(row.line_ids)
