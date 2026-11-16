"""A paper can be saved in one batch: `POST /api/v1/exam/<token>/answers/batch`.

WHY THE ROUTE EXISTS. The runner posted every answer on its own `/answer`, and
the debounced autosave posted it again while the candidate typed - one request,
one transaction and a recompute of the attempt's stored totals per keystroke
pause. The batch carries every changed answer in one call: each item goes
through the same rules `/answer` applies (`_record_response_values`), the
attempt row is written ONCE for the whole batch, and a retried batch changes
nothing. `submit: true` then hands the paper in exactly as `/submit` does.

The writes are counted with the same cursor spy as
`test_a_sitting_stays_inside_its_write_budget.py`.
"""
import json
from contextlib import contextmanager
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAPaperCanBeSavedInOneBatch(TransactionCase):

    QUESTIONS = 6

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.Response = self.env["assessments.be.response"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Batch fixture %s" % uuid4().hex[:6]})
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
        raise AssertionError("the candidate controller has no batch route")

    # ── measurement (the write-budget test's spy) ─────────────────────

    @contextmanager
    def _count_writes(self):
        counted = {"n": 0, "statements": []}
        cr = self.env.cr
        original = cr.execute

        def spy(query, params=None, **kw):
            text = " ".join(str(query).split())
            head = text.lstrip()
            if head.upper().startswith("SQL("):
                head = head[4:].lstrip().lstrip("'\"").lstrip()
            if head.upper().startswith(("INSERT", "UPDATE", "DELETE")):
                counted["n"] += 1
                counted["statements"].append(head[:110])
            if params is not None:
                return original(query, params, **kw)
            return original(query, **kw)

        cr.execute = spy
        try:
            yield counted
        finally:
            cr.execute = original

    @staticmethod
    def _on(counted, verb_table):
        """Statements starting with e.g. `UPDATE "assessments_be_evaluator"`.
        The rendered SQL carries its newlines as a literal backslash-n."""
        return [s for s in counted["statements"]
                if s.replace('"', "").replace("\\n", " ").startswith(
                    verb_table)]

    # ── fixtures ──────────────────────────────────────────────────────

    def _question(self, n, qtype="mcq"):
        question = self.Question.create({
            "name": "Q%d %s" % (n, uuid4().hex[:4]),
            "question_type": qtype,
            "prompt": "Pick one",
            "difficulty": "easy",
            "sequence": n * 10,
            "generator_id": self.generator.id,
        })
        if qtype in ("mcq", "image_ab"):
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
        """A launched, begun attempt of mcqs; the last question is `last`."""
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
            "partner_name": "Batch Sitter",
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

    @staticmethod
    def _item(question, **extra):
        option = question.question_dimension_ids[:1].option_line_ids.filtered(
            "is_correct")[:1]
        return dict({"question_id": question.id,
                     "selected_option_ids": option.ids}, **extra)

    def _batch(self, evaluator, user, answers, **params):
        """`/answers/batch` through the real controller, AS `user`, ending
        with the flush a real request's commit does."""
        return self._call("exam_answers_batch", evaluator, user,
                          answers=answers, **params)

    def _call(self, route, evaluator, user, **params):
        """Any candidate route, as `_batch` describes."""
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

        # Its own transaction clock, as a real request has: an unchanged value
        # re-assigned would otherwise re-stamp the same `write_date` and be
        # dropped by the ORM, hiding the no-op UPDATE production pays for.
        self.env.cr._now = self.env.cr.now() + timedelta(seconds=1)
        fake = _Req(self.env(user=user), params)
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            reply = getattr(self.controller, route)(
                evaluator.access_token, **fake.params)
        self.env.flush_all()
        return reply

    @staticmethod
    def _code(reply):
        return (reply.get("error") or {}).get("code")

    def _row(self, evaluator, question):
        return self.Response.search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "=", question.id)])

    # ── the contract ──────────────────────────────────────────────────

    def test_six_answers_write_once_each_and_the_attempt_once(self):
        evaluator, questions, user = self._sitting()
        answers = [self._item(q) for q in questions]

        with self._count_writes() as counted:
            reply = self._batch(evaluator, user, answers)

        self.assertTrue(reply.get("ok"), reply)
        results = reply["data"]["results"]
        self.assertEqual([r["question_id"] for r in results], questions.ids)
        self.assertTrue(all(r["accepted"] for r in results), results)
        trace = "\n".join("  " + s for s in counted["statements"])
        self.assertEqual(
            len(self._on(counted, "INSERT INTO assessments_be_response ")),
            self.QUESTIONS, trace)
        self.assertEqual(
            len(self._on(counted, "UPDATE assessments_be_evaluator ")), 1,
            "the attempt's stored totals must recompute ONCE for the batch, "
            "not once per answer:\n" + trace)
        # ONE flush for the batch: the six answers' marks and state go out as
        # one UPDATE, so a per-item flush (six) fails here even when the
        # attempt row happens to be written once.
        self.assertEqual(
            len(self._on(counted, "UPDATE assessments_be_response ")), 1,
            trace)
        self.assertEqual(
            counted["n"], 14,
            "6 answer INSERTs + 6 line INSERTs + 1 UPDATE of the answers + 1 "
            "of the attempt:\n" + trace)
        self.assertEqual(evaluator.answered_count, self.QUESTIONS)

        with self._count_writes() as again:
            retry = self._batch(evaluator, user, answers)

        self.assertTrue(all(r["accepted"] for r in retry["data"]["results"]))
        self.assertEqual(
            again["n"], 0,
            "a retried batch must change nothing; it wrote:\n%s"
            % "\n".join("  " + s for s in again["statements"]))

    def test_an_item_outside_the_paper_is_refused_and_the_rest_save(self):
        evaluator, questions, user = self._sitting()
        stranger = self._question(99)

        reply = self._batch(evaluator, user, [
            self._item(questions[0]), self._item(stranger),
            self._item(questions[1]), {"question_id": "abc"}])

        self.assertTrue(reply.get("ok"), reply)
        self.assertEqual(
            [(r["accepted"], r["reason"]) for r in reply["data"]["results"]],
            [(True, "saved"), (False, "not_in_paper"), (True, "saved"),
             (False, "missing_question")])
        self.assertEqual(self._row(evaluator, questions[0]).state,
                         "submitted")
        self.assertEqual(self._row(evaluator, questions[1]).state,
                         "submitted")
        self.assertFalse(self._row(evaluator, stranger))

    def test_a_written_answer_without_prose_is_refused_and_an_mcq_saves(self):
        evaluator, questions, user = self._sitting(last="subjective_rubric")
        written = questions[-1]

        reply = self._batch(evaluator, user, [
            {"question_id": written.id, "justification": "   "},
            self._item(questions[0])])

        self.assertTrue(reply.get("ok"), reply)
        self.assertEqual(
            [(r["accepted"], r["reason"]) for r in reply["data"]["results"]],
            [(False, "incomplete_answer"), (True, "saved")])
        self.assertFalse(self._row(evaluator, written))
        self.assertEqual(self._row(evaluator, questions[0]).state,
                         "submitted")

    def test_submit_with_a_missing_answer_is_refused_unless_forced(self):
        evaluator, questions, user = self._sitting()
        answers = [self._item(q) for q in questions[:-1]]

        refused = self._batch(evaluator, user, answers, submit=True)

        self.assertEqual(refused.get("__status"), 409, refused)
        self.assertEqual(self._code(refused), "incomplete_attempt")
        self.assertEqual(refused.get("unanswered"), [questions[-1].id])
        self.assertEqual(len(refused.get("results") or []), 5)
        self.assertFalse(evaluator.is_locked)
        self.assertEqual(evaluator.answered_count, 5,
                         "the answers still save when the submit is refused")

        forced = self._batch(evaluator, user, answers, submit=True,
                             force=True)

        self.assertTrue(forced.get("ok"), forced)
        self.assertTrue(forced["data"]["submitted"])
        self.assertFalse(forced["data"]["already"])
        self.assertEqual(len(forced["data"]["results"]), 5)
        self.assertTrue(evaluator.is_locked)
        self.assertEqual(evaluator.state, "submitted")

    def test_a_batch_after_the_deadline_is_time_expired(self):
        evaluator, questions, user = self._sitting()
        evaluator.started_at = fields.Datetime.now() - timedelta(minutes=65)
        self.env.flush_all()

        reply = self._batch(evaluator, user, [self._item(questions[0])])

        self.assertEqual(reply.get("__status"), 409, reply)
        self.assertEqual(self._code(reply), "time_expired")
        self.assertFalse(reply.get("answer_saved"),
                         "five minutes late is past the grace")
        self.assertTrue(evaluator.is_locked, "the attempt was not settled")

    def _late(self, seconds):
        """A begun sitting whose 60-minute deadline passed `seconds` ago."""
        evaluator, questions, user = self._sitting()
        evaluator.started_at = (fields.Datetime.now()
                                - timedelta(minutes=60, seconds=seconds))
        self.env.flush_all()
        return evaluator, questions, user

    def test_an_empty_batch_after_the_deadline_lost_nothing(self):
        """The final `submit: true` of a timed-out candidate with nothing
        pending. `any([])` said `answer_saved: false`, which the client shows
        as "your last change arrived after the deadline" - to over a third of
        production submissions, which end on the clock."""
        evaluator, _questions, user = self._late(300)

        reply = self._batch(evaluator, user, [], submit=True)

        self.assertEqual(reply.get("__status"), 409, reply)
        self.assertEqual(self._code(reply), "time_expired")
        self.assertIs(reply.get("answer_saved"), True,
                      "nothing sent means nothing lost")
        self.assertTrue(evaluator.is_locked)

    def test_a_batch_inside_the_grace_saves_and_after_it_does_not(self):
        evaluator, questions, user = self._late(5)
        inside = self._batch(evaluator, user, [self._item(questions[0])])
        self.assertEqual(self._code(inside), "time_expired", inside)
        self.assertIs(inside.get("answer_saved"), True)
        self.assertEqual(self._row(evaluator, questions[0]).state,
                         "submitted", "an answer in flight at time-up is kept")
        self.assertTrue(evaluator.is_locked)

        evaluator, questions, user = self._late(5)
        refused = self._batch(evaluator, user,
                              [self._item(self._question(99))])
        self.assertEqual(self._code(refused), "time_expired", refused)
        self.assertIs(refused.get("answer_saved"), False,
                      "its only item was refused, so something was lost")

        evaluator, questions, user = self._late(15)
        after = self._batch(evaluator, user, [self._item(questions[0])])
        self.assertEqual(self._code(after), "time_expired", after)
        self.assertIs(after.get("answer_saved"), False)
        late_row = self._row(evaluator, questions[0])
        self.assertTrue(late_row.auto_submitted and not late_row.line_ids,
                        "15 s late is past the 10 s grace: only the "
                        "settlement's blank placeholder may be there")

    def test_inside_the_grace_only_the_current_tab_is_stored(self):
        """The grace skips `_write_guard`'s session check. After "Continue
        Here" the tab holds a NEW key; a request it sent under the OLD key
        before the reclaim must not overwrite the newer save. No key (an
        older client) or the current key still stores; the sitting is
        settled in every case."""
        for route in ("answer", "batch"):
            for key, stored in (("tab-new", True), (None, True),
                                ("tab-old", False)):
                with self.subTest(route=route, key=key):
                    evaluator, questions, user = self._sitting()
                    evaluator.exam_session_key = "tab-new"
                    q = questions[0]
                    right, wrong = self._options(q)
                    # The newer save, under the new key, before time-up.
                    self._batch(evaluator, user, [self._pick(q, right)],
                                session_key="tab-new")
                    evaluator.started_at = (
                        fields.Datetime.now()
                        - timedelta(minutes=60, seconds=5))
                    self.env.flush_all()
                    sent = {"session_key": key} if key else {}

                    if route == "answer":
                        reply = self._call("exam_answer", evaluator, user,
                                           nav="stay", **sent,
                                           **self._pick(q, wrong))
                    else:
                        reply = self._batch(evaluator, user,
                                            [self._pick(q, wrong)], **sent)

                    self.assertEqual(self._code(reply), "time_expired",
                                     reply)
                    self.assertIs(reply.get("answer_saved"), stored, reply)
                    self.assertEqual(self._picked(evaluator, q),
                                     wrong if stored else right)
                    self.assertTrue(evaluator.is_locked, "not settled")
                    if route == "batch" and not stored:
                        self.assertEqual(reply.get("results"), [
                            {"question_id": q.id, "accepted": False,
                             "reason": "session_replaced"}])

    def test_a_closed_paper_submits_through_the_batch_as_through_submit(self):
        """An admin marked the paper Done. `/submit` still hands it in, and an
        untimed paper never settles on its own, so the batch must too."""
        def closed():
            evaluator, questions, user = self._sitting()
            evaluator.assessment_id.state = "done"
            self.env.flush_all()
            return evaluator, questions, user

        def same(reply):
            """The reply without `results` and the per-attempt `result`."""
            out = {k: v for k, v in reply.items() if k != "results"}
            if isinstance(out.get("data"), dict):
                out["data"] = {k: v for k, v in out["data"].items()
                               if k not in ("results", "result")}
            return out

        evaluator, questions, user = closed()
        refused = self._batch(evaluator, user, [self._item(questions[0])])
        self.assertEqual(self._code(refused), "assessment_closed",
                         "without `submit` a closed paper stores nothing")

        submit = self._call("exam_submit", evaluator, user)
        batch = self._batch(evaluator, user, [self._item(questions[0])],
                            submit=True)
        self.assertEqual(self._code(submit), "incomplete_attempt", submit)
        self.assertEqual(same(batch), same(submit))
        self.assertEqual(batch.get("results"), [], "the items are skipped")
        self.assertFalse(self._row(evaluator, questions[0]))

        forced = self._batch(evaluator, user, [], submit=True, force=True)
        other, _questions, other_user = closed()
        forced_submit = self._call("exam_submit", other, other_user,
                                   force=True)
        self.assertTrue(forced.get("ok"), forced)
        self.assertEqual(same(forced), same(forced_submit))
        self.assertEqual(set(forced["data"]["result"]),
                         set(forced_submit["data"]["result"]))
        self.assertTrue(evaluator.is_locked)
        self.assertTrue(other.is_locked)

    def test_a_batch_from_a_replaced_session_is_refused(self):
        evaluator, questions, user = self._sitting()
        evaluator.exam_session_key = "tab-new"
        self.env.flush_all()

        reply = self._batch(evaluator, user, [self._item(questions[0])],
                            session_key="tab-old")

        self.assertEqual(reply.get("__status"), 409, reply)
        self.assertEqual(self._code(reply), "session_replaced")
        self.assertFalse(self._row(evaluator, questions[0]),
                         "a replaced tab must not overwrite the live one")

    def test_a_batch_on_a_locked_attempt_is_attempt_locked(self):
        evaluator, questions, user = self._sitting()
        evaluator.is_locked = True
        self.env.flush_all()

        reply = self._batch(evaluator, user, [self._item(questions[0])])

        self.assertEqual(reply.get("__status"), 409, reply)
        self.assertEqual(self._code(reply), "attempt_locked")

    def test_more_than_200_items_is_413(self):
        evaluator, questions, user = self._sitting()

        reply = self._batch(evaluator, user,
                            [self._item(questions[0])] * 201)

        self.assertEqual(reply.get("__status"), 413, reply)
        self.assertEqual(self._code(reply), "too_many_answers")
        self.assertFalse(self._row(evaluator, questions[0]),
                         "an oversized batch must store nothing")

    # ── ordering: `updated_at` counts only inside one session ─────────

    @staticmethod
    def _options(question):
        options = question.question_dimension_ids.option_line_ids
        right = options.filtered("is_correct")
        return right, options - right

    @staticmethod
    def _pick(question, option, **extra):
        return dict({"question_id": question.id,
                     "selected_option_ids": option.ids}, **extra)

    def _picked(self, evaluator, question):
        return self._row(evaluator, question).line_ids.selected_option_id

    def _stamp(self, evaluator, question):
        row = self._row(evaluator, question)
        return row.client_updated_at, row.client_session_key

    def _reason(self, reply):
        self.assertTrue(reply.get("ok"), reply)
        return reply["data"]["results"][0]["reason"]

    def test_an_older_save_from_the_same_session_is_stale(self):
        """THE WRITE-BEHIND DATA-LOSS GUARD. A batch is retried, so it can land
        after a newer save from the same tab; its older stamp must not win."""
        evaluator, questions, user = self._sitting()
        q = questions[0]
        right, wrong = self._options(q)

        newer = self._call("exam_answer", evaluator, user, nav="stay",
                           session_key="tab-a", updated_at=2000,
                           **self._pick(q, right))
        self.assertTrue(newer.get("ok"), newer)
        self.assertEqual(self._stamp(evaluator, q), (2000, "tab-a"))

        with self._count_writes() as counted:
            late = self._batch(evaluator, user,
                               [self._pick(q, wrong, updated_at=1000)],
                               session_key="tab-a")

        self.assertEqual(late["data"]["results"], [
            {"question_id": q.id, "accepted": True, "reason": "stale"}])
        self.assertEqual(
            counted["n"], 0, "a stale item must write nothing:\n%s"
            % "\n".join("  " + s for s in counted["statements"]))
        self.assertEqual(self._picked(evaluator, q), right,
                         "the newer save was overwritten")

        # Equal, then newer: both save.
        for stamp, option in ((2000, wrong), (3000, right)):
            reply = self._batch(evaluator, user,
                                [self._pick(q, option, updated_at=stamp)],
                                session_key="tab-a")
            self.assertEqual(self._reason(reply), "saved", stamp)
            self.assertEqual(self._picked(evaluator, q), option, stamp)
        self.assertEqual(self._stamp(evaluator, q), (3000, "tab-a"))

    def test_any_other_save_goes_through_and_replaces_the_stamp(self):
        """Another session (a tab takeover, another device), no session key
        or no stamp: two clocks cannot be compared, so the save wins."""
        evaluator, questions, user = self._sitting()
        q = questions[0]
        right, wrong = self._options(q)
        self._batch(evaluator, user, [self._pick(q, right, updated_at=2000)],
                    session_key="tab-a")

        other = self._batch(evaluator, user,
                            [self._pick(q, wrong, updated_at=1000)],
                            session_key="tab-b")
        self.assertEqual(self._reason(other), "saved")
        self.assertEqual(self._picked(evaluator, q), wrong)
        self.assertEqual(self._stamp(evaluator, q), (1000, "tab-b"))

        keyless = self._batch(evaluator, user,
                              [self._pick(q, right, updated_at=500)])
        self.assertEqual(self._reason(keyless), "saved")
        self.assertEqual(self._picked(evaluator, q), right)
        self.assertEqual(self._stamp(evaluator, q), (500, False))

        unstamped = self._batch(evaluator, user, [self._pick(q, wrong)],
                                session_key="tab-b")
        self.assertEqual(self._reason(unstamped), "saved")
        self.assertEqual(self._picked(evaluator, q), wrong)
        self.assertEqual(self._stamp(evaluator, q), (0.0, "tab-b"))

    def test_a_far_future_stamp_does_not_block_another_session(self):
        evaluator, questions, user = self._sitting()
        q = questions[0]
        right, wrong = self._options(q)
        # A device clock years ahead, still inside the accepted range.
        self._batch(evaluator, user, [self._pick(q, right, updated_at=9e13)],
                    session_key="tab-a")

        reply = self._batch(
            evaluator, user, [self._pick(q, wrong, updated_at=1.8e12)],
            session_key="tab-b")

        self.assertEqual(self._reason(reply), "saved")
        self.assertEqual(self._picked(evaluator, q), wrong)
        self.assertEqual(self._stamp(evaluator, q), (1.8e12, "tab-b"))

    def test_a_draft_over_a_submitted_answer_leaves_the_stamp(self):
        """Prose with the verdict cleared is HELD over a submitted comparison:
        nothing is stored, so the stamp keeps describing the answer on
        record."""
        evaluator, questions, user = self._sitting(last="image_ab")
        q = questions[-1]
        right, _wrong = self._options(q)
        first = self._batch(evaluator, user,
                            [self._pick(q, right, updated_at=1000)],
                            session_key="tab-a")
        self.assertEqual(self._reason(first), "saved")
        self.assertEqual(self._row(evaluator, q).state, "submitted")

        draft = self._batch(evaluator, user, [{
            "question_id": q.id, "updated_at": 2000,
            "justification": "On reflection the right render is better."}],
            session_key="tab-a")

        self.assertEqual(self._reason(draft), "held_draft")
        self.assertEqual(self._stamp(evaluator, q), (1000, "tab-a"))
        self.assertEqual(self._picked(evaluator, q), right)

    def test_a_stamped_option_change_costs_no_extra_write(self):
        """The stamp rides the answer's own UPDATE: changing an option with a
        stamp writes exactly what the same change without one writes."""
        evaluator, questions, user = self._sitting()
        counts = []
        for q, first, second in ((questions[0], {}, {}),
                                 (questions[1], {"updated_at": 1000},
                                  {"updated_at": 2000})):
            right, wrong = self._options(q)
            self._batch(evaluator, user, [self._pick(q, right, **first)],
                        session_key="tab-a")
            with self._count_writes() as counted:
                reply = self._batch(evaluator, user,
                                    [self._pick(q, wrong, **second)],
                                    session_key="tab-a")
            self.assertEqual(self._reason(reply), "saved")
            counts.append(counted)

        self.assertEqual(self._stamp(evaluator, questions[1]),
                         (2000, "tab-a"))
        self.assertEqual(
            counts[1]["n"], counts[0]["n"],
            "unstamped change:\n%s\nstamped change:\n%s" % tuple(
                "\n".join("  " + s for s in c["statements"]) for c in counts))

    def test_a_garbage_stamp_is_read_as_absent(self):
        evaluator, questions, user = self._sitting()
        garbage = (1e300, 10 ** 400, float("nan"), -5, "soon", True)
        for q, stamp in zip(questions, garbage):
            right, _wrong = self._options(q)
            reply = self._batch(evaluator, user,
                                [self._pick(q, right, updated_at=stamp)],
                                session_key="tab-a")
            self.assertEqual(self._reason(reply), "saved", repr(stamp)[:20])
            self.assertEqual(self._stamp(evaluator, q), (0.0, "tab-a"),
                             repr(stamp)[:20])

        # `/answer` reads the stamp the same way: a 400-digit integer is a
        # 200, not an OverflowError 500.
        right, _wrong = self._options(questions[0])
        reply = self._call("exam_answer", evaluator, user, nav="stay",
                           updated_at=10 ** 400, **self._pick(questions[0],
                                                              right))
        self.assertTrue(reply.get("ok"), reply)

    # ── the capability flag ───────────────────────────────────────────

    def test_state_and_begin_advertise_the_batch_route(self):
        """Cross-origin, a server WITHOUT the route fails the preflight, so the
        client sees a transport error, never a 404 - the same thing an
        overloaded load balancer's 503 looks like. The client batches only
        when `/state` or `/begin` said `answers_batch: true`."""
        evaluator, _questions, user = self._sitting()
        evaluator.write({"started_at": False, "state": "pending"})
        self.env.flush_all()

        def flag(reply, outcome):
            self.assertTrue(reply.get("ok"), reply)
            self.assertEqual(reply["data"].get("outcome"), outcome, reply)
            return reply["data"].get("answers_batch")

        self.assertIs(flag(self._call("exam_state", evaluator, user),
                           "instructions"), True, "before the sitting")
        self.assertIs(flag(self._call("exam_begin", evaluator, user),
                           "question"), True, "/begin")
        self.assertIs(flag(self._call("exam_state", evaluator, user),
                           "question"), True, "during a question")
        submitted = self._call("exam_submit", evaluator, user, force=True)
        self.assertTrue(submitted.get("ok"), submitted)
        self.assertIs(flag(self._call("exam_state", evaluator, user),
                           "complete"), True, "after submit")

    # ── the batch interval the client is told to use ──────────────────

    FLUSH_PARAM = "assessments_be_v2.answers_flush_seconds"

    def _flush_seconds(self, stored):
        """What `/state` and `/begin` advertise with `stored` in the setting
        (None = never set); both must agree."""
        evaluator, _questions, user = self._sitting()
        evaluator.write({"started_at": False, "state": "pending"})
        icp = self.env["ir.config_parameter"].sudo()
        if stored is None:
            icp.search([("key", "=", self.FLUSH_PARAM)]).unlink()
        else:
            icp.set_param(self.FLUSH_PARAM, str(stored))
        self.env.flush_all()
        seen = []
        for route in ("exam_state", "exam_begin"):
            reply = self._call(route, evaluator, user)
            self.assertTrue(reply.get("ok"), reply)
            seen.append(reply["data"].get("answers_flush_seconds"))
        self.assertEqual(seen[0], seen[1], seen)
        return seen[0]

    def test_the_batch_interval_defaults_to_60(self):
        self.assertEqual(self._flush_seconds(None), 60)
        self.assertEqual(self._flush_seconds(0), 60)

    def test_a_stored_batch_interval_is_advertised(self):
        self.assertEqual(self._flush_seconds(180), 180)

    def test_an_out_of_range_batch_interval_is_clamped(self):
        self.assertEqual(self._flush_seconds(5), 15)
        self.assertEqual(self._flush_seconds(900), 300)
        self.assertEqual(self._flush_seconds("junk"), 60)

    def test_the_settings_route_range_checks_the_batch_interval(self):
        from ..controllers.api import write as write_api
        from ._paging_harness import call_route, status_of
        self.env.user.group_ids = [(4, self.env.ref(
            "assessments_be_v2.group_assessment_manager").id)]
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param(self.FLUSH_PARAM, "60")

        def update(value):
            return call_route(write_api, write_api.EtpAssessmentApiWrite(),
                              "settings_update", self.env,
                              answers_flush_seconds=value)

        for bad in (10, 301):
            self.assertEqual(status_of(update(bad)), 422, bad)
            self.assertEqual(icp.get_param(self.FLUSH_PARAM), "60")
        self.assertEqual(status_of(update(120)), 200)
        self.assertEqual(icp.get_param(self.FLUSH_PARAM), "120")

    # ── a lost first INSERT is reported, not hidden ───────────────────

    def test_a_lost_first_insert_is_reported_to_the_client(self):
        """`concurrent` means THIS request stored nothing: a sibling won the
        question's first INSERT, and under write-behind that sibling may carry
        OLDER content. `/answer` used to hide it behind `saved: true`."""
        from psycopg2 import IntegrityError

        evaluator, questions, user = self._sitting()
        clash = patch.object(
            type(self.Response), "create",
            side_effect=IntegrityError("duplicate key value violates unique "
                                       "constraint"))

        for q, nav in ((questions[0], "stay"), (questions[1], "next")):
            right, _wrong = self._options(q)
            with clash:
                reply = self._call("exam_answer", evaluator, user, nav=nav,
                                   **self._pick(q, right))
            self.assertTrue(reply.get("ok"), reply)
            self.assertTrue(reply["data"]["saved"], "older clients read it")
            self.assertIs(reply["data"].get("concurrent"), True, nav)
            self.assertFalse(self._row(evaluator, q),
                             "the losing request stored nothing")
        self.assertTrue(reply["data"].get("next"),
                        "the next-question envelope is unchanged")

        right, _wrong = self._options(questions[2])
        normal = self._call("exam_answer", evaluator, user, nav="stay",
                            **self._pick(questions[2], right))
        self.assertTrue(normal.get("ok"), normal)
        self.assertNotIn("concurrent", normal["data"])

        right, _wrong = self._options(questions[3])
        with clash:
            batch = self._batch(evaluator, user,
                                [self._pick(questions[3], right)])
        self.assertEqual(batch["data"]["results"], [
            {"question_id": questions[3].id, "accepted": True,
             "reason": "concurrent"}])
