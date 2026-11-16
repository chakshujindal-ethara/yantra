# -*- coding: utf-8 -*-
"""W8 - "Scored" and "Score Pending" split Submitted, by ANSWERS.

The candidates roster gains two chips after Submitted. Defined on the answers,
not on the attempt's own `llm_state`, because an objective-only attempt is
never rolled up and keeps `pending` for ever:

  * Scored        = submitted, and no answer that needs the grader is unscored.
  * Score Pending = submitted, and at least one such answer is not scored -
                    queued, never queued, in flight, partial, failed, error,
                    cancelled by a Kill, or on an archived paper.

So Scored + Score Pending = Submitted, always, and a queued re-score of an
already-scored answer keeps the candidate in Scored (the mark stays until a
new one replaces it).

The chip numbers come from `meta.counts` on the roster itself - one entry per
value `state` accepts - in two queries whatever the cohort's size. They used to
come from a console-wide cache that nothing refreshed when a run ended.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"

#: Every value the roster's `state` accepts, and so every key of `meta.counts`
#: beside `pass` / `fail` (the `result` chips, pinned in
#: `test_the_candidates_table_counts_passed_and_failed`).
ACCEPTED = {"all", "pending", "in_progress", "submitted", "scored",
            "score_pending"}


@tagged("-at_install", "post_install")
class _Roster(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.admin = api_admin.EtpAssessmentApiAdmin()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "W8 %s" % uuid4().hex[:6]})
        self.assessment = self._paper()
        self.written = self._question("subjective_rubric")
        self.written_too = self._question("subjective_rubric")
        self.choice = self._question("mcq")

    def _paper(self):
        return self.env["assessments.be"].create({
            "name": "W8 paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
        })

    def _question(self, qtype):
        return self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": qtype,
            "prompt": "Answer it.",
            "difficulty": "easy",
            "generator_id": self.generator.id,
        })

    def _candidate(self, answers, *, state="submitted", llm_state="pending",
                   requested=False, assessment=None, name=None):
        """One attempt; `answers` is [(question, answer llm_state or None)].
        None = an objective answer (no justification, needs no grader)."""
        assessment = assessment or self.assessment
        applicant = self.env["hr.applicant"].create({
            "partner_name": name or "Cand %s" % uuid4().hex[:6],
            "email_from": "w8_%s@example.com" % uuid4().hex[:8],
        })
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        self.env["assessments.be.response"].create([{
            "assessment_evaluator_id": ev.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "assessment_id": assessment.id,
            "state": "submitted",
            "justification": "an answer" if answer_state else False,
            "llm_state": answer_state or "not_needed",
            "llm_raw_100": 80.0 if answer_state == "scored" else 0.0,
        } for question, answer_state in answers])
        ev.write({"state": state, "llm_state": llm_state,
                  "scoring_requested": requested})
        return ev

    def _roster(self, assessment=None, limit=200, **params):
        response = call_route(
            api_admin, self.admin, "assessment_candidates", self.env,
            path={"assessment_id": (assessment or self.assessment).id},
            limit=limit, **params)
        self.assertEqual(status_of(response), 200, response)
        return response

    def _ids(self, state, assessment=None):
        return {row["id"] for row in
                self._roster(assessment, state=state)["data"]}


class TestEachCaseLandsInOneChip(_Roster):

    def setUp(self):
        super().setUp()
        w, w2, c = self.written, self.written_too, self.choice
        self.scored = {
            "all graded": self._candidate(
                [(w, "scored"), (c, None)], llm_state="scored"),
            "objective only": self._candidate(
                [(c, None)], llm_state="pending"),
            "re-score queued on a scored answer": self._candidate(
                [(w, "scored")], llm_state="pending", requested=True),
        }
        self.pending = {
            "never queued": self._candidate([(w, "pending")]),
            "queued": self._candidate(
                [(w, "queued")], requested=True),
            "in flight": self._candidate(
                [(w, "pending")], llm_state="scoring", requested=True),
            "partial": self._candidate(
                [(w, "scored"), (w2, "pending")], llm_state="partial"),
            "failed": self._candidate([(w, "failed")], llm_state="failed"),
            "error": self._candidate([(w, "error")], llm_state="error"),
            "cancelled by a Kill": self._candidate(
                [(w, "pending")], llm_state="cancelled"),
        }
        self.not_submitted = {
            "not started": self._candidate([], state="pending"),
            "mid-exam with an unscored answer": self._candidate(
                [(w, "pending")], state="in_progress"),
        }

    def test_each_scored_case_is_scored(self):
        got = self._ids("scored")
        for case, ev in self.scored.items():
            self.assertIn(ev.id, got, "%s is not under Scored" % case)
        self.assertEqual(got, {ev.id for ev in self.scored.values()})

    def test_each_pending_case_is_score_pending(self):
        got = self._ids("score_pending")
        for case, ev in self.pending.items():
            self.assertIn(ev.id, got, "%s is not under Score Pending" % case)
        self.assertEqual(got, {ev.id for ev in self.pending.values()})

    def test_an_archived_paper_is_score_pending(self):
        paper = self._paper()
        ev = self._candidate([(self.written, "pending")], assessment=paper)
        paper.active = False
        self.assertEqual(self._ids("score_pending", paper), {ev.id})
        self.assertEqual(self._ids("scored", paper), set())

    def test_the_counts_cover_every_accepted_value(self):
        counts = self._roster()["meta"]["counts"]
        self.assertEqual(set(counts), ACCEPTED | {"pass", "fail"})
        self.assertEqual({k: counts[k] for k in ACCEPTED}, {
            "all": 12, "pending": 1, "in_progress": 1, "submitted": 10,
            "scored": 3, "score_pending": 7,
        })

    def test_scored_and_score_pending_add_up_to_submitted(self):
        counts = self._roster()["meta"]["counts"]
        self.assertEqual(counts["scored"] + counts["score_pending"],
                         counts["submitted"])
        self.assertEqual(
            self._ids("scored") | self._ids("score_pending"),
            self._ids("submitted"))
        self.assertFalse(self._ids("scored") & self._ids("score_pending"))

    def test_a_chip_count_is_what_pressing_it_lists(self):
        """The number beside a chip equals the rows the chip returns - for
        every chip, and under a search too."""
        for params in ({}, {"search": "Filtered"}):
            if params:
                self._candidate([(self.written, "pending")],
                                name="Filtered One")
                self._candidate([(self.written, "scored")],
                                llm_state="scored", name="Filtered Two")
            counts = self._roster(**params)["meta"]["counts"]
            for state in ACCEPTED:
                total = self._roster(state=state, **params)["meta"]["total"]
                self.assertEqual(
                    counts[state], total,
                    "%s: chip says %d, pressing it lists %d (params %s)"
                    % (state, counts[state], total, params))
        self.assertEqual(counts["all"], 2)

    def test_all_is_everyone(self):
        self.assertEqual(self._ids("all"), self._ids(""))
        self.assertEqual(len(self._ids("all")), 12)

    def test_the_counts_ignore_the_chip_being_pressed(self):
        # Every key, under a pressed state or a pressed result: the tiles are
        # one choice, counted over one cohort (R1).
        unpressed = self._roster()["meta"]["counts"]
        for params in ({"state": "scored"}, {"result": "fail"}):
            self.assertEqual(self._roster(**params)["meta"]["counts"],
                             unpressed, params)


class TestTheCountsCostTheSameAtAnySize(_Roster):

    def _cohort(self, n):
        for i in range(n):
            if i % 2:
                self._candidate([(self.written, "scored")],
                                llm_state="scored")
            else:
                self._candidate([(self.written, "pending")])

    def _queries(self):
        self.env.flush_all()
        self.env.invalidate_all()
        before = self.env.cr.sql_log_count
        # ONE ROW A PAGE, so the page itself costs the same at either size and
        # only the counts could grow with the cohort.
        response = self._roster(limit=1)
        return self.env.cr.sql_log_count - before, response["meta"]["counts"]

    def test_five_and_fifty_candidates_cost_the_same(self):
        self._cohort(5)
        small, counts = self._queries()
        self.assertEqual(counts["submitted"], 5)
        self._cohort(45)
        big, counts = self._queries()
        self.assertEqual(counts["submitted"], 50)
        self.assertEqual(counts["scored"] + counts["score_pending"], 50)
        self.assertEqual(
            big, small,
            "the roster cost %d queries at 5 candidates and %d at 50 - the "
            "chip counts are no longer a fixed number of queries"
            % (small, big))
