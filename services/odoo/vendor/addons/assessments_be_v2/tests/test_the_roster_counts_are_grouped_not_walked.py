"""The roster counts must be answered by the database, not by loading rows.

THE DEFECT (N2, found by review; no tracker row). `_compute_response_count` was
converted to `_read_group` and its docstring names the exact problem it solves.
Its two NEIGHBOURS, six and twenty-five lines below, were left walking the table
in Python:

    _compute_release_state    - 4x .filtered() over assessment_evaluator_ids,
                                the fourth descending into e.response_ids
    _compute_invite_summary   - 3x .filtered() over assessment_evaluator_ids

`.filtered()` is a Python pass, so it has to materialise every record it
filters. Reading `submitted_count` therefore loaded every ATTEMPT of every
assessment in the recordset, and `awaiting_scoring_count` loaded every ANSWER of
every one of those attempts. At 5,000 candidates on a 35-question paper that is
~175,000 `Response` records read to produce four integers per assessment row.

WHY IT IS NOT MERELY SLOW. `/api/v1/analytics` reads these fields for up to 25
assessments (`api/admin.py:1691-1700`), and the assessment LIST renders them per
row. So the route that was repointed to make the console's arithmetic correct is
the one that triggers the heaviest read - the numbers are right and the page that
shows them does not scale.

WHAT THESE TESTS PIN. Two things, and the first matters more:

  1. **The numbers did not change.** A grouped count that disagrees with the
     Python walk is a new bug, not an optimisation, so every count is asserted
     against a hand-built fixture with a known answer - including the shapes
     `_read_group` is easy to get wrong: an assessment with no attempts at all
     (must be 0, not absent), an attempt with SEVERAL unscored answers (counts
     ONCE - it is "attempts waiting", not "answers waiting"), and a mix of
     released and held in one cohort.
  2. **The query count does not grow with the recordset.** That is the whole
     point of the change, and without it a future refactor can quietly
     reintroduce the walk while every value stays correct.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestTheRosterCountsAreGroupedNotWalked(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Grouped counts fixture %s" % uuid4().hex[:6]})
        # subjective_rubric so `needs_llm` computes True on its answers - that
        # flag is what `awaiting_scoring_count` groups on.
        #
        # THREE questions, not one. A unique index enforces one answer per
        # (attempt, question) - `assessments_be_response_uniq_eval_q_sess` - so
        # an attempt with several unscored ANSWERS needs several distinct
        # questions. A first draft of this file reused one question and hit that
        # index rather than testing anything.
        self.questions = self.Question.browse()
        for i in range(3):
            self.questions |= self.Question.create({
                "name": "Q%d %s" % (i, uuid4().hex[:6]),
                "question_type": "subjective_rubric",
                "prompt": "Answer it.",
                "difficulty": "easy",
                "sequence": (i + 1) * 10,
                "generator_id": self.generator.id,
            })
        self.question = self.questions[0]

    def _assessment(self):
        return self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, self.questions.ids)],
        })

    def _sitting(self, assessment, name, state="pending", released=False,
                 invite=None, answers=()):
        """One attempt. `answers` is a tuple of llm_state values, so a caller can
        make an attempt with several unscored answers on purpose."""
        applicant = self.Applicant.create({
            "partner_name": name,
            "email_from": "%s@example.com" % uuid4().hex[:10],
        })
        ev = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": json.dumps(self.questions.ids),
        })
        # One answer per DISTINCT question - see the note in setUp on the unique
        # index. `answers` therefore cannot be longer than `self.questions`.
        self.assertLessEqual(len(answers), len(self.questions),
                             "fixture: not enough distinct questions")
        for question, llm_state in zip(self.questions, answers):
            self.Response.create({
                "assessment_evaluator_id": ev.id,
                "evaluator_id": applicant.id,
                "question_id": question.id,
                "assessment_id": assessment.id,
                "state": "submitted",
                "justification": "An answer.",
                "llm_state": llm_state,
            })
        vals = {}
        if state != "pending":
            vals["state"] = state
        if released:
            vals["results_released"] = True
        if invite:
            vals["invite_state"] = invite
        if vals:
            ev.write(vals)
        return ev

    # ── the counts are unchanged ──────────────────────────────────────

    def test_the_submitted_counts_are_right(self):
        """Three submitted (one released), one still pending."""
        a = self._assessment()
        self._sitting(a, "Submitted Held 1", state="submitted")
        self._sitting(a, "Submitted Held 2", state="submitted")
        self._sitting(a, "Submitted Out", state="submitted", released=True)
        self._sitting(a, "Still Sitting")
        a.invalidate_recordset()

        self.assertEqual(a.submitted_count, 3, "three attempts submitted")
        self.assertEqual(a.released_count, 1, "one of them released")
        self.assertEqual(a.releasable_count, 2,
                         "the other two are still releasable")

    def test_an_assessment_with_no_attempts_reads_zero(self):
        """The shape a grouped count gets wrong: a row absent from the GROUP
        result must read 0, not carry a stale value or raise."""
        a = self._assessment()
        a.invalidate_recordset()
        self.assertEqual(a.submitted_count, 0)
        self.assertEqual(a.released_count, 0)
        self.assertEqual(a.releasable_count, 0)
        self.assertEqual(a.awaiting_scoring_count, 0)
        self.assertFalse(a.invite_summary)

    def test_an_attempt_with_several_unscored_answers_counts_once(self):
        """THE SUBTLE ONE. `awaiting_scoring_count` is a count of ATTEMPTS
        waiting, not of answers - the Python version asked `any(...)` per
        attempt. Grouping over responses without collapsing by attempt would
        report 3 for one candidate with three unscored answers.
        """
        a = self._assessment()
        self._sitting(a, "Three Unscored", state="submitted",
                      answers=("pending", "pending", "pending"))
        a.invalidate_recordset()
        self.assertEqual(
            a.awaiting_scoring_count, 1,
            "one candidate is waiting, however many answers they left")

    def test_a_fully_scored_attempt_is_not_awaiting(self):
        a = self._assessment()
        self._sitting(a, "All Scored", state="submitted",
                      answers=("scored", "scored"))
        a.invalidate_recordset()
        self.assertEqual(a.awaiting_scoring_count, 0)

    def test_only_submitted_attempts_are_awaiting(self):
        """An unsubmitted attempt's answers do not make the cohort 'awaiting' -
        the Python version filtered to submitted first, and the domain must too.
        """
        a = self._assessment()
        self._sitting(a, "Not Submitted Yet", answers=("pending",))
        a.invalidate_recordset()
        self.assertEqual(a.awaiting_scoring_count, 0)

    def test_the_invite_summary_reads_the_same(self):
        """Order and wording are part of the contract - the string is rendered
        as-is."""
        a = self._assessment()
        self._sitting(a, "Q1", invite="queued")
        self._sitting(a, "Q2", invite="queued")
        self._sitting(a, "S1", invite="sent")
        self._sitting(a, "F1", invite="failed")
        a.invalidate_recordset()
        self.assertEqual(a.invite_summary, "2 queued  ·  1 sent  ·  1 failed")

    def test_the_invite_summary_omits_empty_buckets(self):
        a = self._assessment()
        self._sitting(a, "S1", invite="sent")
        a.invalidate_recordset()
        self.assertEqual(a.invite_summary, "1 sent")

    def test_counts_do_not_leak_between_assessments(self):
        """The failure mode of a grouped query keyed wrongly: one assessment's
        attempts landing on another's row."""
        a, b = self._assessment(), self._assessment()
        self._sitting(a, "A1", state="submitted", invite="sent")
        self._sitting(a, "A2", state="submitted", invite="sent")
        self._sitting(b, "B1", state="submitted", released=True, invite="queued")
        (a | b).invalidate_recordset()

        self.assertEqual((a.submitted_count, a.released_count), (2, 0))
        self.assertEqual((b.submitted_count, b.released_count), (1, 1))
        self.assertEqual(a.invite_summary, "2 sent")
        self.assertEqual(b.invite_summary, "1 queued")

    # ── and the point of the change ───────────────────────────────────

    def test_the_answers_are_never_loaded_to_count_them(self):
        """THE REASON THIS CHANGE EXISTS, and the only assertion that catches a
        regression to the walk.

        MEASURING QUERY COUNT DOES NOT WORK HERE, and a first version of this
        test did exactly that and passed against BOTH implementations. Odoo
        prefetches a field across the whole recordset, so `.filtered()` over six
        assessments issues about as few queries as a grouped read does - the
        query count simply does not separate them.

        What separates them is ROWS MATERIALISED. The walk has to pull every
        `Response` of every attempt into the cache to ask `any(r.needs_llm ...)`;
        the grouped read pulls none, because the database answers the question.
        At 175,000 answers that difference is the whole cost.

        So this spies on the cursor and asserts the SHAPE of the SQL: reading
        these counts may issue aggregate queries against the answers table, and
        must issue no plain row fetch against it.
        """
        many = self.Assessment.browse()
        for i in range(6):
            a = self._assessment()
            self._sitting(a, "M%d-1" % i, state="submitted", invite="sent",
                          answers=("pending", "pending"))
            self._sitting(a, "M%d-2" % i, state="submitted", released=True,
                          invite="queued", answers=("scored",))
            many |= a

        # Flush first: pending writes would otherwise show up as our queries.
        self.env.flush_all()
        many.invalidate_recordset()

        cr = self.env.cr
        seen = []
        original = cr.execute

        def spy(query, params=None, **kw):
            seen.append(" ".join(str(query).split()))
            if params is not None:
                return original(query, params, **kw)
            return original(query, **kw)

        cr.execute = spy
        try:
            for rec in many:
                _ = (rec.submitted_count, rec.released_count,
                     rec.releasable_count, rec.awaiting_scoring_count,
                     rec.invite_summary)
        finally:
            cr.execute = original

        answers_sql = [q for q in seen if "assessments_be_response" in q]
        # GUARD THE MEASUREMENT. If the counts can be produced without touching
        # the answers table at all, this test proves nothing either way - and
        # that is exactly how the first version of it came to pass against the
        # walk. `awaiting_scoring_count` reads answer state, so something must
        # ask the database about them.
        self.assertTrue(
            answers_sql,
            "no SQL touched the answers table, so this assertion is vacuous - "
            "the fixture is not exercising awaiting_scoring_count")

        plain = [q for q in answers_sql
                 if "COUNT(" not in q.upper() and "GROUP BY" not in q.upper()]
        self.assertFalse(
            plain,
            "the answer ROWS are being loaded to count them (%d plain fetch(es), "
            "e.g. %s) - `_compute_release_state` is walking with .filtered() "
            "again instead of grouping in the database"
            % (len(plain), plain[0][:160] if plain else ""))
