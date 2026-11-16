"""One sitting must stay inside a stated write budget, and the budget is asserted.

THE GAP (G11). `assertQueryCount`, `query_count` and `cr.sql_log` had **zero**
hits across 104 test files, so the two headline scale targets - "<=70 writes per
sitting" and "<=20 SQL statements per answer" - were unenforceable by
construction. Every plan quoted them; nothing could tell you whether a change
had moved them. That is why this file comes BEFORE the write-reduction work
rather than after: a target nothing measures is not a target, and a reduction
nobody can verify is a claim.

WHAT IS MEASURED, and why it is writes rather than queries. A read scales with
the ORM's prefetching and with cache state, so a query-count assertion over a
whole request is brittle and teaches people to edit the number. WRITES are
different: each INSERT or UPDATE is a row the database must durably record, they
are what contend on locks, and they are what turned a 100-candidate cohort into
82 failures on 2026-09-03. So this counts INSERT/UPDATE/DELETE only, and ignores
SELECT entirely.

HOW THE NUMBERS WERE CHOSEN. Measured first, then set as a ceiling with headroom -
never picked and then reverse-engineered. The test prints what it measured on
failure, so the next person sees the real figure rather than only that a bound
was crossed.

PROVED BY NEGATIVE CONTROL, and the first attempt did NOT prove it. Injecting ONE
extra write per answer into `exam_answer` left every assertion passing: 2 -> 3
against a per-answer budget of 4, and 12 -> 18 against a sitting budget of 24 -
both inside the headroom. That is the deliberate property stated below, not a
broken test, but it is worth being explicit that these bounds do NOT catch a
single extra write. Injecting THREE reported the real figures and failed three of
the four tests:

    one /answer call issued 5 writes against a budget of 4
    a 6-question sitting issued 30 writes against a budget of 24 - 5.0 per answer
    re-sending an IDENTICAL answer wrote 3 row(s)

So the bounds catch amplification at roughly 1.5x and above, and the re-save
assertion below catches ANY new write on the repeat path - which is the one that
actually multiplies across a cohort.

WHAT THIS IS NOT. It is not the load harness (SNo 151-153) and does not simulate
concurrency: it drives ONE sitting through the real endpoints in one process. Its
job is to catch a change that multiplies per-answer writes - the amplification
class of defect - not to prove the platform holds at 1,200 concurrent.
"""
import json
from contextlib import contextmanager
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestASittingStaysInsideItsWriteBudget(TransactionCase):

    #: Questions on the paper this test sits. Small enough to be quick, large
    #: enough that a PER-ANSWER regression shows up as a multiple rather than as
    #: noise.
    QUESTIONS = 6

    #: Writes allowed for the whole sitting: begin, one answer per question, and
    #: submit.
    #:
    #: MEASURED AT 12 for six questions - 2.0 per answer - by forcing this bound
    #: to 0 and reading what the failure printed. 24 is therefore a ceiling with
    #: real headroom, not a number reverse-engineered from a target.
    #:
    #: The DELIBERATE property is the RATIO. Per-answer amplification is the
    #: defect class this catches: at 2.0/answer a change that adds one write per
    #: answer costs 6 more and passes, while one that writes per answer PER
    #: QUESTION costs ~72 and fails loudly.
    #:
    #: THOSE FIGURES WERE INSERTs ONLY. The counter could not see a flushed
    #: ORM UPDATE (see `_count_writes`), so "12" was really 38 - 6.3 per
    #: answer. With every write counted and one flush per save, this sitting
    #: (five mcq, one written answer, a request flush each) MEASURES 26: begin
    #: 1, an mcq 4, the written answer 3, submit 2 (the attempt and the
    #: paper's cohort flag). The bound is that measured figure, no headroom:
    #: any new write fails it.
    MAX_WRITES_PER_SITTING = 26

    #: Writes allowed for one `/answer` call. MEASURED AT 4 with every write
    #: counted (it was 6 before the save stopped flushing per step): the
    #: answer's INSERT, its line's INSERT, ONE UPDATE of the answer (marks and
    #: state) and ONE of the attempt (its totals). No headroom left.
    MAX_WRITES_PER_ANSWER = 4

    #: Writes allowed for one `cleared: true` `/answer`, MEASURED: a clear
    #: with no row yet is 2 (the INSERT and its marks' UPDATE); a clear of a
    #: written answer is 2 (ONE UPDATE of the answer, ONE of the attempt,
    #: whose answered count drops); an answer holding options also DELETEs
    #: them, 3. No headroom.
    MAX_WRITES_PER_CLEAR = 2
    MAX_WRITES_PER_CLEAR_WITH_OPTIONS = 3

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Write budget fixture %s" % uuid4().hex[:6]})
        self.controller = self._controller()
        # WHAT THE REAL CLIENT SENDS: one `session_key` on every call, and an
        # `updated_at` per answer taken when it was edited (so an unchanged
        # re-send carries the same stamp). Without them the budgets measured
        # a client nobody runs: the stamp and session columns never moved.
        self.session_key = uuid4().hex
        self.stamps = {}

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

    # ── measurement ───────────────────────────────────────────────────

    @contextmanager
    def _count_writes(self):
        """Count INSERT/UPDATE/DELETE statements issued inside the block.

        Spies on the cursor rather than using `sql_log`, which is off unless the
        server runs at debug level - a test that silently measured nothing is
        exactly the failure mode this file exists to prevent, so the count must
        not depend on a log setting.

        Odoo's own bookkeeping (`ir_attachment`, `ir_cron`, sequence bumps) is
        counted too. That is deliberate: it is real write load, and excluding it
        would let a change hide behind "that was the framework".
        """
        counted = {"n": 0, "statements": []}
        cr = self.env.cr
        original = cr.execute

        def spy(query, params=None, **kw):
            # ODOO 19 PASSES AN `SQL` OBJECT, NOT A STRING, so `str(query)`
            # renders as `SQL('INSERT INTO "assessments_be_response" ...')` -
            # it does NOT start with INSERT. A first version of this file tested
            # `startswith("INSERT")` and counted zero writes for everything,
            # which is why `test_the_counter_itself_is_not_vacuous` exists and
            # is what caught it.
            #
            # Matching on the verb ANYWHERE in the rendered text would count a
            # SELECT that merely mentions a column called `update_date`, so the
            # verb is looked for at the start of the SQL *inside* the wrapper.
            text = " ".join(str(query).split())
            head = text.lstrip()
            if head.upper().startswith("SQL("):
                # Step past `SQL(`, the opening quote AND the whitespace after
                # it. The ORM's flush writes `SQL(' UPDATE "table" ...')` - a
                # space inside the quote (`_write_multi`) - and without the
                # last `lstrip` every flushed UPDATE was invisible: the budgets
                # below counted INSERTs and raw SQL only.
                head = head[4:].lstrip().lstrip("'\"").lstrip()
            if head.upper().startswith(("INSERT", "UPDATE", "DELETE")):
                counted["n"] += 1
                counted["statements"].append(text[:110])
            if params is not None:
                return original(query, params, **kw)
            return original(query, **kw)

        cr.execute = spy
        try:
            yield counted
        finally:
            cr.execute = original

    # ── fixtures ──────────────────────────────────────────────────────

    def _question(self, n, qtype="mcq"):
        q = self.Question.create({
            "name": "Q%d %s" % (n, uuid4().hex[:4]),
            "question_type": qtype,
            "prompt": "Pick one",
            "difficulty": "easy",
            "sequence": n * 10,
            "generator_id": self.generator.id,
        })
        if qtype == "subjective_rubric":
            # Prose only: no axes, so the justification IS the answer and it
            # goes to the grader queue (`needs_llm`).
            return q
        self.QDim.create({
            "question_id": q.id,
            "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": name, "sequence": j * 10,
                        "is_correct": j == 0})
                for j, name in enumerate(("Alpha", "Bravo"))
            ],
        })
        return q

    def _sitting(self, last="subjective_rubric"):
        """A launched assessment with one candidate ready to sit it."""
        # The LAST question is subjective (or a comparison): its save queues
        # the grader and rolls the attempt's `llm_state` up, the path an
        # unchanged autosave used to turn into an UPDATE of the attempt row.
        questions = self.Question.browse()
        for n in range(self.QUESTIONS):
            questions |= self._question(
                n, last if n == self.QUESTIONS - 1 else "mcq")
        assessment = self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, questions.ids)],
            "question_limit": self.QUESTIONS,
            "duration_minutes": 60,
            "state": "in_progress",
        })
        applicant = self.Applicant.create({
            "partner_name": "Budget Sitter",
            "email_from": "%s@example.com" % uuid4().hex[:10],
        })
        evaluator = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": json.dumps(questions.ids),
            "access_token": uuid4().hex,
        })
        # THE REQUEST HAS TO BE THE CANDIDATE, or every write is refused 403
        # `wrong_candidate` - `_write_guard` gates on `is_assigned_candidate`,
        # which compares `request.env.user` against the attempt's resolved
        # portal user, precisely so a manager holding the token for preview can
        # never write into a real attempt.
        #
        # Without this the budgets measured a REJECTION: the counts came out at
        # 0 and two of the assertions passed vacuously, which is exactly what
        # the `ok` guard in each test now catches.
        assessment.sudo()._ensure_candidate_user(applicant)
        candidate_user = evaluator.sudo()._candidate_user()
        self.assertTrue(
            candidate_user,
            "the fixture has no portal user, so every write would be refused "
            "and the budget would measure nothing")
        return assessment, evaluator, questions, candidate_user

    def _call(self, route, evaluator, user, **params):
        """Invoke a candidate route through the real controller, AS `user`."""
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

        # EACH REQUEST IS ITS OWN TRANSACTION, so it stamps its own
        # `write_date`. Inside one test transaction an assignment of an
        # unchanged value re-stamps the SAME `write_date`, which the ORM drops
        # as no change - so a no-op write that costs an UPDATE per request in
        # production was invisible here.
        self.env.cr._now = self.env.cr.now() + timedelta(seconds=1)
        params.setdefault("session_key", self.session_key)
        fake = _Req(env, params)
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            result = getattr(self.controller, route)(
                evaluator.access_token, **params)
        # THE REQUEST ENDS HERE, as a real one commits. Without this the whole
        # sitting shared one env and flushed once at the end, so an UPDATE the
        # ORM coalesced across requests - one per request in production - was
        # counted once.
        self.env.flush_all()
        return result

    def _answer(self, evaluator, user, question):
        """One answer, the way the runner sends it: the correct option, or
        prose for the subjective question, stamped with its edit time."""
        stamp = self.stamps.setdefault(
            question.id, 1_800_000_000_000 + len(self.stamps))
        if question.question_type == "subjective_rubric":
            return self._call(
                "exam_answer", evaluator, user, question_id=question.id,
                justification="The left render keeps the cup upright.",
                nav="stay", updated_at=stamp)
        option = question.question_dimension_ids[:1].option_line_ids.filtered(
            "is_correct")[:1]
        # `selected_option_ids` is the key the route reads
        # (`_selected_option_lines`, `candidate.py:757`). A first version sent
        # `option_ids`, which the route simply did not see - so every answer came
        # back 422 `incomplete_answer` and the write count measured a rejection.
        return self._call(
            "exam_answer", evaluator, user,
            question_id=question.id,
            selected_option_ids=option.ids,
            updated_at=stamp,
        )

    # ── the budgets ───────────────────────────────────────────────────

    def test_one_answer_stays_inside_its_write_budget(self):
        """THE PER-ANSWER BOUND, which is the one that amplifies.

        A sitting issues one of these per question, so an extra write here is
        multiplied by the length of the paper - and by the size of the cohort.
        This is the number that turned 100 concurrent candidates into 82
        failures.
        """
        _assessment, evaluator, questions, user = self._sitting()
        self._call("exam_begin", evaluator, user)
        self.env.flush_all()

        with self._count_writes() as counted:
            response = self._answer(evaluator, user, questions[0])
            self.env.flush_all()

        self.assertTrue(
            response.get("ok"),
            "the answer was refused, so the count measures a rejection: %r"
            % (response,))
        self.assertLessEqual(
            counted["n"], self.MAX_WRITES_PER_ANSWER,
            "one /answer call issued %d writes against a budget of %d.\n%s"
            % (counted["n"], self.MAX_WRITES_PER_ANSWER,
               "\n".join("  " + s for s in counted["statements"])))

    def test_a_whole_sitting_stays_inside_its_write_budget(self):
        """THE END-TO-END BOUND: begin, answer every question, submit."""
        _assessment, evaluator, questions, user = self._sitting()
        self.env.flush_all()

        with self._count_writes() as counted:
            self._call("exam_begin", evaluator, user)
            for question in questions:
                self._answer(evaluator, user, question)
            self._call("exam_submit", evaluator, user)
            self.env.flush_all()

        self.assertLessEqual(
            counted["n"], self.MAX_WRITES_PER_SITTING,
            "a %d-question sitting issued %d writes against a budget of %d - "
            "that is %.1f per answer.\nFirst 25 statements:\n%s"
            % (self.QUESTIONS, counted["n"], self.MAX_WRITES_PER_SITTING,
               counted["n"] / float(self.QUESTIONS),
               "\n".join("  " + s for s in counted["statements"][:25])))

    def test_re_saving_an_unchanged_answer_writes_nothing(self):
        """THE PROPERTY BEHIND THE BUDGET, asserted directly.

        The client debounces and also saves on navigation, so the same answer is
        submitted more than once in normal use. The dirty check
        (`_answerSent` / the server-side diff) is what stops that becoming a
        second INSERT - and it is the single biggest contributor to the
        amplification measured on 2026-09-03.

        Worth pinning separately from the totals: this fails LOUDLY and names the
        cause, where a budget breach only says a number grew.
        """
        _assessment, evaluator, questions, user = self._sitting()
        self._call("exam_begin", evaluator, user)
        self._answer(evaluator, user, questions[0])
        self.env.flush_all()

        with self._count_writes() as counted:
            self._answer(evaluator, user, questions[0])
            self.env.flush_all()

        self.assertEqual(
            counted["n"], 0,
            "re-sending an IDENTICAL answer wrote %d row(s); the same answer "
            "arriving twice is normal (debounce plus navigation save), so this "
            "multiplies every sitting.\n%s"
            % (counted["n"], "\n".join("  " + s
                                       for s in counted["statements"])))

    def test_re_saving_an_unchanged_subjective_answer_writes_nothing(self):
        """THE AUTOSAVE OF A WRITTEN ANSWER, the runner's most frequent call.

        Its re-save re-queues the grader (`_enqueue_subjective_scoring`), which
        assigned `llm_state` and `scoring_requested` and rolled the attempt's
        `llm_state` up whether or not anything changed - and an ORM assignment
        of the same value still bumps `write_date`. So every autosave was an
        UPDATE of the attempt row. Grading switched on, so the
        `scoring_requested` write is exercised too.
        """
        assessment, evaluator, questions, user = self._sitting()
        assessment.llm_auto_score = True
        subjective = questions[-1]
        self._call("exam_begin", evaluator, user)
        first = self._answer(evaluator, user, subjective)
        self.assertTrue(first.get("ok"), first)
        self.assertTrue(evaluator.scoring_requested,
                        "the first save did not queue the grader, so the "
                        "repeat below proves nothing about re-queueing")

        with self._count_writes() as counted:
            again = self._answer(evaluator, user, subjective)

        self.assertTrue(again.get("ok"), again)
        self.assertEqual(
            counted["n"], 0,
            "re-sending an IDENTICAL written answer wrote %d row(s):\n%s"
            % (counted["n"], "\n".join("  " + s
                                       for s in counted["statements"])))

    def test_re_saving_an_unchanged_comparison_writes_nothing(self):
        """An image_ab with picks and no reference reasoning is settled at
        save (verdict-only) and reads "scored", so each autosave re-stored
        the same verdict on the answer and re-stamped the attempt's
        `llm_scored_at`: two UPDATEs that changed nothing."""
        _assessment, evaluator, questions, user = self._sitting(
            last="image_ab")
        comparison = questions[-1]
        self._call("exam_begin", evaluator, user)
        first = self._answer(evaluator, user, comparison)
        self.assertTrue(first.get("ok"), first)
        self.assertEqual(evaluator.llm_state, "scored",
                         "the fixture is not on the verdict-only path")

        with self._count_writes() as counted:
            again = self._answer(evaluator, user, comparison)

        self.assertTrue(again.get("ok"), again)
        self.assertEqual(
            counted["n"], 0,
            "re-sending an IDENTICAL comparison wrote %d row(s):\n%s"
            % (counted["n"], "\n".join("  " + s
                                       for s in counted["statements"])))

    def test_re_saving_an_unchanged_held_draft_writes_nothing(self):
        """Prose typed before the verdict is HELD as a draft and autosaved per
        keystroke pause; the held-draft branch wrote `justification` without
        comparing, so each unchanged autosave was an UPDATE that only moved
        `write_date`."""
        _assessment, evaluator, questions, user = self._sitting(
            last="image_ab")
        comparison = questions[-1]
        self._call("exam_begin", evaluator, user)
        prose = {"question_id": comparison.id, "nav": "stay",
                 "justification": "The right render keeps the cup level."}
        first = self._call("exam_answer", evaluator, user, **prose)
        self.assertEqual((first.get("error") or {}).get("code"),
                         "incomplete_answer", first)
        held = self.env["assessments.be.response"].search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "=", comparison.id)])
        self.assertEqual(held.state, "draft",
                         "the fixture is not on the held-draft path")

        with self._count_writes() as counted:
            again = self._call("exam_answer", evaluator, user, **prose)

        self.assertEqual((again.get("error") or {}).get("code"),
                         "incomplete_answer", again)
        self.assertEqual(
            counted["n"], 0,
            "re-sending an IDENTICAL held draft wrote %d row(s):\n%s"
            % (counted["n"], "\n".join("  " + s
                                       for s in counted["statements"])))

    def test_a_clear_stays_inside_its_write_budget(self):
        """`cleared: true`: a clear with no row yet INSERTs the cleared row; a
        clear of a stored answer is ONE UPDATE of the answer plus ONE of the
        attempt (its answered count drops), and an answer holding options
        DELETEs them too. Re-sending the same clear writes nothing."""
        _assessment, evaluator, questions, user = self._sitting()
        self._call("exam_begin", evaluator, user)
        for question in (questions[0], questions[-1]):
            self.assertTrue(self._answer(evaluator, user, question).get("ok"))
        # Graded mid-sitting: the clear blanks the grade's prose in the SAME
        # UPDATE as the rest of the answer, so the budget does not move.
        self.env["assessments.be.response"].search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "=", questions[-1].id)]).write({
                "llm_state": "scored", "llm_raw_100": 90.0,
                "llm_feedback": "Clear.", "llm_verdict": "Pass",
                "llm_reasoning": "Matches.", "llm_deductions_json": "[]",
                "llm_credit_json": "[]", "label_box_scores_json": "{}",
                "llm_judge_model": "judge-x"})
        self.env.flush_all()

        for question, budget, case in (
                (questions[1], self.MAX_WRITES_PER_CLEAR, "no row yet"),
                (questions[-1], self.MAX_WRITES_PER_CLEAR, "a written answer"),
                (questions[0], self.MAX_WRITES_PER_CLEAR_WITH_OPTIONS,
                 "an answer holding options")):
            stamp = self.stamps.setdefault(
                question.id, 1_800_000_000_000 + len(self.stamps))
            clear = {"question_id": question.id, "cleared": True,
                     "nav": "stay", "updated_at": stamp + 1}
            with self.subTest(case=case):
                with self._count_writes() as counted:
                    reply = self._call("exam_answer", evaluator, user,
                                       **clear)
                self.assertTrue(reply["data"].get("cleared"), reply)
                self.assertLessEqual(
                    counted["n"], budget,
                    "one clear (%s) issued %d writes against a budget of "
                    "%d.\n%s" % (case, counted["n"], budget, "\n".join(
                        "  " + s for s in counted["statements"])))
                with self._count_writes() as again:
                    self._call("exam_answer", evaluator, user, **clear)
                self.assertEqual(
                    again["n"], 0,
                    "a repeated clear wrote:\n%s"
                    % "\n".join("  " + s for s in again["statements"]))

    def test_one_violation_is_one_update(self):
        """The counter, the log and the latest-violation fields move in ONE
        statement; they used to be a raw UPDATE plus an ORM write."""
        _assessment, evaluator, _questions, _user = self._sitting()
        self.env.flush_all()

        with self._count_writes() as counted:
            count = evaluator._record_violation("tab_switch")
            self.env.flush_all()

        self.assertEqual(count, 1)
        self.assertEqual(
            counted["n"], 1,
            "one violation issued %d writes:\n%s"
            % (counted["n"], "\n".join("  " + s
                                       for s in counted["statements"])))
        self.assertTrue(evaluator.is_violated)
        self.assertEqual(evaluator.violation_reason, "tab_switch")
        self.assertTrue(evaluator.violation_datetime)
        self.assertEqual(evaluator.violation_count, 1)
        self.assertEqual(len(evaluator.violation_log or []), 1)

    def test_the_counter_itself_is_not_vacuous(self):
        """GUARD THE MEASUREMENT.

        Every assertion above is an upper bound, so a counter that always
        returned 0 would satisfy all of them - which is precisely how a
        query-budget test comes to prove nothing. This does one write and
        insists the spy sees it.
        """
        with self._count_writes() as counted:
            self.env["assessments.be.prompt"].create(
                {"name": "Counter probe %s" % uuid4().hex[:6]})
            self.env.flush_all()

        self.assertGreater(
            counted["n"], 0,
            "the write counter saw nothing for a create() - every budget "
            "assertion in this file is therefore vacuous")

    def test_the_counter_sees_a_flushed_orm_update(self):
        """THE SECOND BLIND SPOT, and the one that shipped: an ORM write is
        flushed as `SQL(' UPDATE ...')`, and the counter missed every one, so
        the budgets measured INSERTs only."""
        probe = self.env["assessments.be.prompt"].create(
            {"name": "Counter probe %s" % uuid4().hex[:6]})
        self.env.flush_all()

        with self._count_writes() as counted:
            probe.name = "Counter probe renamed %s" % uuid4().hex[:6]
            self.env.flush_all()

        self.assertEqual(
            counted["n"], 1,
            "the counter saw %d writes for one flushed ORM update"
            % counted["n"])
