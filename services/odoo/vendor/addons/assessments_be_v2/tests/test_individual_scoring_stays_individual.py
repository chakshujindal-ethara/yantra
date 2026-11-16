# -*- coding: utf-8 -*-
"""Individual scoring stays individual (W6, `docs/ETP_PLANS_AND_STRATEGY.md` §3.8).

"Individual" is one candidate, or chosen answers of one candidate: Odoo's
attempt-level "Re-score N answer(s)" and Re-score This Answer, and the app's
per-answer / per-candidate / selected re-score, all through
`action_rescore_individually` and `POST /attempts/<id>/rescore`.

The click only QUEUES: the chosen answers get one random key per click, and the
lane that owns the candidate grades them first, each click's answers in calls of
their own - never with another click, another candidate or the bulk run. A
scored answer's mark is replaced only when the new grade succeeds.

The first class walks the "What the admin sees - cases" table row by row
(candidate Asha, Q7 scored 40/100); the rest pin each rule the table rests on.
"""
import json
from unittest.mock import patch
from uuid import uuid4
from datetime import timedelta

from odoo import fields
from odoo.tests.common import HttpCase, TransactionCase, tagged
from odoo.tools import mute_logger

from ..controllers.api import serializers as S
from ..models.assessment import RescoreRefused
from ..services import evidence
from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc

_ICP = "assessments_be_v2.%s"
_JSON = {"Content-Type": "application/json"}


class _Paper:
    """Fixtures shared by the ORM and the HTTP cases."""

    def _pin_settings(self):
        # erase purges snapshots; keep tests off the bucket
        purge = patch.object(evidence, "purge_evidence")
        purge.start()
        self.addCleanup(purge.stop)
        icp = self.env["ir.config_parameter"].sudo()
        for key, value in (("scoring_batch_size", "20"),
                           ("llm_max_attempts", "3"),
                           ("scoring_shards", "1"),
                           # 0 disables each cap, so ambient ledger rows on the
                           # test database cannot refuse a fixture.
                           ("daily_llm_cap_usd", "0"),
                           ("per_evaluator_llm_cap_usd", "0"),
                           ("vertex_max_rpm", "0")):
            icp.set_param(_ICP % key, value)
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "W6 %s" % uuid4().hex[:6]})
        self.paper = self._new_paper()

    def _new_paper(self):
        return self.env["assessments.be"].create({
            "name": "W6 paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
        })

    def _candidate(self, n=1, *, scored=None, errored=(), mcq=0,
                   requested=False, paper=None):
        """``n`` written answers, pending unless ``scored`` ({index: raw})
        or ``errored`` (indexes, attempts spent) say otherwise, plus ``mcq``
        answers scored in code."""
        paper = paper or self.paper
        scored = scored or {}
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Asha %s" % uuid4().hex[:6],
            "email_from": "asha_%s@example.com" % uuid4().hex[:8],
        })
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id})
        for i in range(n + mcq):
            written = i < n
            question = self.env["assessments.be.question"].create({
                "name": "Q%d %s" % (i + 1, uuid4().hex[:4]),
                "question_type": "subjective_rubric" if written else "mcq",
                "prompt": "Describe",
                "generator_id": self.generator.id,
                "assessment_ids": [(4, paper.id)],
            })
            vals = {
                "assessment_evaluator_id": ev.id,
                "evaluator_id": applicant.id,
                "question_id": question.id,
                "assessment_id": paper.id,
                "state": "submitted",
                "justification": ("A considered written answer, number %d, "
                                  "long enough to grade." % i) if written
                else False,
                "llm_state": "pending" if written else "not_needed",
            }
            if i in scored:
                vals.update(llm_state="scored", llm_raw_100=scored[i],
                            llm_attempts=1, llm_judge_model="gemini-old",
                            llm_prompt_version="bundled:0ld0ld00")
            elif i in errored:
                vals.update(llm_state="error", llm_attempts=3,
                            llm_feedback="Scoring call failed: boom")
            self.env["assessments.be.response"].create(vals)
        ev.write({"state": "submitted", "scoring_requested": requested})
        ev._compute_subjective_rollup()
        return ev

    @staticmethod
    def _answers(ev):
        return ev.response_ids.sorted("id")

    def _judge(self, scores=None, error=None, reply=None):
        """Vertex, standing in. Records each call's item ids and ledger note."""
        calls = []

        def judge(env, system_prompt, user_text, **kw):
            items = json.loads(user_text[user_text.index('{"items"'):])["items"]
            ids = [int(it["id"]) for it in items]
            calls.append({"ids": ids, "note": kw["usage_ctx"]["note"],
                          "evaluator_id": kw["usage_ctx"]["evaluator_id"]})
            kw["served_model_out"].append("gemini-new-judge")
            if error is not None:
                raise error
            if reply is not None:
                return json.dumps(reply(ids))
            return json.dumps({"results": [
                {"id": i, "score": (scores or {}).get(i, 80)} for i in ids]})
        return calls, patch.object(vertex_svc, "_call_vertex", judge)


@tagged("-at_install", "post_install")
class TestWhatTheAdminSees(_Paper, TransactionCase):
    """One test per row of the §3.8 "What the admin sees - cases" table."""

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_rescore_on_a_scored_answer_grades_it_alone(self):
        asha = self._candidate(3, scored={0: 40, 1: 70, 2: 90})
        q7 = self._answers(asha)[0]

        q7.action_rescore_this_answer()
        self.assertTrue(S.response_row(q7)["rescore_requested"],
                        "the app shows 'Re-score queued' off this")

        calls, judge = self._judge({q7.id: 80})
        with judge:
            asha._action_llm_score()
        self.assertEqual([c["ids"] for c in calls], [[q7.id]])
        self.assertEqual(q7.llm_raw_100, 80.0)
        self.assertFalse(S.response_row(q7)["rescore_requested"])
        self.assertEqual(self._answers(asha).mapped("llm_raw_100"),
                         [80.0, 70.0, 90.0])

    def test_rescore_on_an_errored_answer_is_that_answer_with_three_tries(self):
        asha = self._candidate(3, errored=(0,))
        q7, others = self._answers(asha)[0], self._answers(asha)[1:]

        q7.action_rescore_this_answer()

        self.assertEqual(q7.llm_attempts, 0, "a fresh 3-attempt budget")
        self.assertTrue(q7.rescore_request_key)
        self.assertFalse(any(others.mapped("rescore_request_key")),
                         "only the answer asked about is queued")
        calls, judge = self._judge()
        with judge:
            asha._action_llm_score()
        self.assertEqual([c["ids"] for c in calls], [[q7.id]])
        self.assertEqual(q7.llm_state, "scored")
        self.assertEqual(set(others.mapped("llm_state")), {"pending"})

    def test_three_chosen_answers_are_one_call_and_only_hers(self):
        asha = self._candidate(5)
        three = self._answers(asha)[:3]

        asha.action_rescore_individually(three.question_id.ids)

        calls, judge = self._judge()
        with judge:
            asha._action_llm_score()
        self.assertEqual([sorted(c["ids"]) for c in calls], [sorted(three.ids)])
        self.assertEqual(set(three.mapped("llm_state")), {"scored"})
        self.assertEqual(
            set((self._answers(asha) - three).mapped("llm_state")), {"pending"})

    def test_ticked_answers_of_two_candidates_are_graded_per_candidate(self):
        asha, ben = self._candidate(10), self._candidate(10)
        a3, a9 = self._answers(asha)[2], self._answers(asha)[8]
        b3 = self._answers(ben)[2]

        # The app sends one request per candidate, with only the ticked ones.
        asha.action_rescore_individually([a3.question_id.id, a9.question_id.id])
        ben.action_rescore_individually([b3.question_id.id])

        calls, judge = self._judge()
        with judge:
            (asha | ben)._action_llm_score()
        self.assertEqual(sorted(sorted(c["ids"]) for c in calls),
                         sorted([sorted([a3.id, a9.id]), [b3.id]]))
        graded = (a3 | a9 | b3)
        self.assertEqual(set(graded.mapped("llm_state")), {"scored"})
        self.assertEqual(
            set(((self._answers(asha) | self._answers(ben)) - graded)
                .mapped("llm_state")), {"pending"})

    @mute_logger("odoo.addons.assessments_be_v2.services.scoring")
    def test_a_failed_regrade_keeps_the_mark_and_says_why(self):
        asha = self._candidate(1, scored={0: 40})
        q7 = self._answers(asha)

        q7.action_rescore_this_answer()
        _calls, judge = self._judge(error=RuntimeError("Vertex 500"))
        with judge:
            asha._action_llm_score()

        self.assertEqual((q7.llm_state, q7.llm_raw_100, q7.llm_attempts),
                         ("scored", 40.0, 1))
        self.assertFalse(q7.rescore_request_key, "click again later")
        self.assertIn("previous mark was kept", asha.llm_error)
        self.assertIn("Vertex 500", asha.llm_error)

    def test_a_reached_daily_cap_refuses_at_once_and_queues_nothing(self):
        asha = self._candidate(2, scored={0: 40})
        self.env["ir.config_parameter"].sudo().set_param(
            _ICP % "daily_llm_cap_usd", "400")
        self.env["assessments.be.llm.usage"].create({
            "operation": "score_subjective", "model": "gemini-3-pro",
            "cost_usd": 401.0, "note": "cap fixture"})

        with self.assertRaises(RescoreRefused) as caught:
            asha.action_rescore_individually()
        self.assertEqual(caught.exception.code, "spend_limit")
        self.assertIn("Nothing was queued", str(caught.exception))
        self.assertFalse(any(self._answers(asha).mapped("rescore_request_key")))
        self.assertEqual(self._answers(asha)[0].llm_raw_100, 40.0)

    def test_kill_clears_queued_requests_and_keeps_marks(self):
        asha = self._candidate(2, scored={0: 40})
        asha.action_rescore_individually(self._answers(asha).question_id.ids)

        self.paper.action_kill_scoring()

        self.assertFalse(any(self._answers(asha).mapped("rescore_request_key")))
        self.assertEqual(self._answers(asha)[0].llm_raw_100, 40.0)
        self.assertEqual(self._answers(asha)[0].llm_state, "scored")
        Assessment = self.env["assessments.be"]
        self.assertFalse(Assessment._auto_score_eligible(asha),
                         "nothing is left for the cron to grade")
        self.assertNotIn(asha, Assessment._scoring_shard_evaluators(
            0, 1, limit=10000))

    def test_a_kill_that_only_cancels_re_scores_says_so(self):
        # Nothing was queued in bulk, so the old message read "Nothing to
        # stop" while it had just cancelled a request the admin had made.
        asha = self._candidate(2, scored={0: 40})
        asha.action_rescore_individually(self._answers(asha)[:1].question_id.ids)

        params = self.paper.action_kill_scoring()["params"]

        self.assertEqual(params["title"], "Scoring stopped")
        self.assertIn("1 re-score request(s) cancelled", params["message"])

    def test_an_mcq_is_never_queued(self):
        asha = self._candidate(1, mcq=1)
        q2 = self._answers(asha)[1]
        self.assertFalse(q2.needs_llm, "fixture guard: scored in code")

        result = asha.action_rescore_individually([q2.question_id.id])

        self.assertEqual(result["rescore"],
                         {"queued": 0, "skipped": 1, "question_ids": []})
        self.assertFalse(q2.rescore_request_key)
        arch = self.env.ref(
            "assessments_be_v2.assessments_be_response_form").arch
        self.assertIn('invisible="not needs_llm', arch,
                      "no Re-score button on an answer scored in code")


@tagged("-at_install", "post_install")
class TestTheCronGradesExactlyWhatWasChosen(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_one_answer_is_one_call_with_one_item_noted_rescore(self):
        asha = self._candidate(4)
        q = self._answers(asha)[1]
        q.action_rescore_this_answer()

        calls, judge = self._judge()
        with judge:
            asha._action_llm_score()
        self.assertEqual(calls, [{"ids": [q.id], "note": "rescore(1)",
                                  "evaluator_id": asha.id}])

    def test_a_scored_40_becomes_80_with_the_new_model_and_prompt(self):
        asha = self._candidate(1, scored={0: 40})
        q7 = self._answers(asha)
        q7.action_rescore_this_answer()

        _calls, judge = self._judge({q7.id: 80})
        with judge:
            asha._action_llm_score()
        self.assertEqual(q7.llm_raw_100, 80.0)
        self.assertEqual(q7.llm_judge_model, "gemini-new-judge")
        self.assertTrue(q7.llm_prompt_version)
        self.assertNotEqual(q7.llm_prompt_version, "bundled:0ld0ld00")
        self.assertFalse(q7.rescore_request_key)

    @mute_logger("odoo.addons.assessments_be_v2.services.scoring")
    def test_a_failed_regrade_never_moves_a_mark(self):
        cases = {
            "call error": dict(error=RuntimeError("boom")),
            "missing result": dict(
                reply=lambda ids: {"results": [{"id": 999999999, "score": 90}]}),
            "null score": dict(
                reply=lambda ids: {"results": [
                    {"id": i, "score": None} for i in ids]}),
        }
        for name, judged in cases.items():
            with self.subTest(name):
                asha = self._candidate(1, scored={0: 40})
                q7 = self._answers(asha)
                q7.action_rescore_this_answer()
                _calls, judge = self._judge(**judged)
                with judge:
                    asha._action_llm_score()
                self.assertEqual(
                    (q7.llm_state, q7.llm_raw_100, q7.llm_attempts,
                     q7.llm_judge_model), ("scored", 40.0, 1, "gemini-old"))
                self.assertFalse(q7.rescore_request_key)
                self.assertIn("previous mark was kept", asha.llm_error)

    def test_a_truncated_labelling_reply_never_moves_a_mark(self):
        question = self.env["assessments.be.question"].create({
            "name": "Label %s" % uuid4().hex[:6],
            "question_type": "image_label",
            "prompt": "Describe each numbered control.",
            "generator_id": self.generator.id,
        })
        asha = self._candidate(0)
        q7 = self.env["assessments.be.response"].create({
            "assessment_evaluator_id": asha.id,
            "evaluator_id": asha.applicant_id.id,
            "question_id": question.id,
            "assessment_id": self.paper.id,
            "state": "submitted",
            "justification": json.dumps({"1": "Opens the menu",
                                         "2": "Closes the menu"}),
            "llm_state": "scored", "llm_raw_100": 40.0,
            # The LAST attempt: a first grade would take the truncated reply
            # as final here, a re-grade must not.
            "llm_attempts": 2,
        })
        self.assertTrue(q7.needs_llm, "fixture guard")
        q7.action_rescore_this_answer()

        def truncated(resp, it):
            return dict(it, label_scores={"unscored_attempted": [2],
                                          "boxes_returned_by_judge": 1,
                                          "attempted_boxes": 2})
        _calls, judge = self._judge({q7.id: 95})
        with judge, patch.object(scoring_svc, "_apply_image_label_boxes",
                                 truncated):
            asha._action_llm_score()
        self.assertEqual((q7.llm_state, q7.llm_raw_100, q7.llm_attempts),
                         ("scored", 40.0, 2))
        self.assertFalse(q7.rescore_request_key)
        self.assertIn("truncated", asha.llm_error)

    def test_25_of_30_chosen_are_calls_of_20_and_5(self):
        asha = self._candidate(30)
        asha.action_rescore_individually(
            self._answers(asha)[:25].question_id.ids)

        calls, judge = self._judge()
        with judge:
            asha._action_llm_score()
        self.assertEqual(sorted(len(c["ids"]) for c in calls), [5, 20])
        self.assertEqual({c["note"] for c in calls},
                         {"rescore(20)", "rescore(5)"})
        self.assertEqual(
            set(self._answers(asha)[25:].mapped("llm_state")), {"pending"})

    def test_calls_never_mix_candidates(self):
        asha, ben = self._candidate(3), self._candidate(3)
        asha.action_rescore_individually()
        ben.action_rescore_individually()

        calls, judge = self._judge()
        with judge:
            (asha | ben)._action_llm_score()
        for call in calls:
            owners = self.env["assessments.be.response"].browse(
                call["ids"]).assessment_evaluator_id
            self.assertEqual(len(owners), 1, call)
            self.assertEqual(call["evaluator_id"], owners.id)

    def test_separate_clicks_are_separate_calls(self):
        asha = self._candidate(3)
        q1, q2 = self._answers(asha)[:2]
        q1.action_rescore_this_answer()
        q2.action_rescore_this_answer()

        calls, judge = self._judge()
        with judge:
            asha._action_llm_score()
        self.assertEqual(sorted(c["ids"] for c in calls), [[q1.id], [q2.id]])

    def test_a_second_click_on_a_queued_answer_is_graded_once(self):
        asha = self._candidate(2)
        q1 = self._answers(asha)[0]
        q1.action_rescore_this_answer()
        key = q1.rescore_request_key

        result = q1.action_rescore_this_answer()

        self.assertEqual(q1.rescore_request_key, key, "one request kept")
        self.assertEqual(result["rescore"]["queued"], 1)
        calls, judge = self._judge()
        with judge:
            asha._action_llm_score()
        self.assertEqual([c["ids"] for c in calls], [[q1.id]])

    def test_an_individual_only_candidate_leaves_other_answers_alone(self):
        asha = self._candidate(4, errored=(3,))
        q1 = self._answers(asha)[0]
        self.assertFalse(asha.scoring_requested, "fixture guard")
        q1.action_rescore_this_answer()

        calls, judge = self._judge()
        with judge:
            asha._action_llm_score()
        self.assertEqual([c["ids"] for c in calls], [[q1.id]])
        rest = self._answers(asha)[1:]
        self.assertEqual(rest.mapped("llm_state"),
                         ["pending", "pending", "error"])
        self.assertEqual(rest.mapped("llm_attempts"), [0, 0, 3])

    def test_a_bulk_queued_candidate_grades_chosen_answers_in_their_own_call(
            self):
        asha = self._candidate(4, requested=True)
        q1, rest = self._answers(asha)[0], self._answers(asha)[1:]
        q1.action_rescore_this_answer()

        calls, judge = self._judge()
        with judge:
            asha._action_llm_score()
        self.assertEqual(
            sorted((c["note"], sorted(c["ids"])) for c in calls),
            [("rescore(1)", [q1.id]), ("submission(3)", sorted(rest.ids))])

    def test_a_rescore_job_is_marked_individual(self):
        asha = self._candidate(3, requested=True)
        self._answers(asha)[0].action_rescore_this_answer()
        jobs = []
        prepare = scoring_svc._prepare_submission

        def spy(env, responses, individual=False, **kw):
            scored, job = prepare(env, responses, individual=individual, **kw)
            jobs.append(job)
            return scored, job

        _calls, judge = self._judge()
        with judge, patch.object(scoring_svc, "_prepare_submission", spy):
            asha._action_llm_score()
        self.assertEqual(sorted(j.individual for j in jobs), [False, True])

    def test_a_refusal_keeps_the_request_and_spends_no_attempt(self):
        refusals = (vertex_svc.VertexQuotaError("429"),
                    vertex_svc.VertexBudgetError("cap"),
                    vertex_svc.VertexCancelledError("kill"))
        for refusal in refusals:
            with self.subTest(type(refusal).__name__):
                asha = self._candidate(2, scored={0: 40})
                q7, q8 = self._answers(asha)
                asha.action_rescore_individually(
                    (q7 | q8).question_id.ids)
                keys = (q7 | q8).mapped("rescore_request_key")
                _calls, judge = self._judge(error=refusal)
                with judge:
                    asha._action_llm_score()
                # A kill drops the request instead (R1-02).
                if isinstance(refusal, vertex_svc.VertexCancelledError):
                    keys = [False, False]
                self.assertEqual((q7 | q8).mapped("rescore_request_key"), keys,
                                 "retried on the next tick")
                self.assertEqual((q7.llm_raw_100, q7.llm_attempts), (40.0, 1))
                self.assertEqual((q8.llm_state, q8.llm_attempts),
                                 ("pending", 0))

    def test_a_rate_limit_does_not_refuse_the_request(self):
        asha = self._candidate(1)
        self.env["ir.config_parameter"].sudo().set_param(
            _ICP % "vertex_max_rpm", "1")
        self.env["assessments.be.llm.usage"].create({
            "operation": "score_subjective", "model": "gemini-3-pro",
            "cost_usd": 0.01, "note": "rate fixture"})

        asha.action_rescore_individually()

        self.assertTrue(self._answers(asha).rescore_request_key)

    @mute_logger("odoo.addons.assessments_be_v2.services.scoring")
    def test_an_errored_answer_gets_three_fresh_attempts(self):
        asha = self._candidate(1, errored=(0,))
        q = self._answers(asha)
        q.action_rescore_this_answer()
        self.assertEqual(q.llm_attempts, 0)

        _calls, judge = self._judge(error=RuntimeError("boom"))
        with judge:
            for attempt in (1, 2):
                asha._action_llm_score()
                self.assertEqual((q.llm_state, q.llm_attempts),
                                 ("failed", attempt))
                self.assertTrue(q.rescore_request_key,
                                "still queued while attempts remain")
            asha._action_llm_score()
        self.assertEqual((q.llm_state, q.llm_attempts), ("error", 3))
        self.assertFalse(q.rescore_request_key)

    def test_the_cron_tick_grades_a_request_on_a_scored_candidate(self):
        asha = self._candidate(2, scored={0: 40, 1: 60})
        q7 = self._answers(asha)[0]
        q7.action_rescore_this_answer()

        calls, judge = self._judge({q7.id: 85})
        with judge, patch.object(self.env.cr, "commit", self.env.flush_all):
            self.env["assessments.be"]._cron_llm_auto_score(shard=0)
        self.assertEqual([c["ids"] for c in calls
                          if c["evaluator_id"] == asha.id], [[q7.id]])
        self.assertEqual(self._answers(asha).mapped("llm_raw_100"), [85.0, 60.0])
        self.assertEqual(asha.llm_state, "scored")

    def test_a_parallel_lane_grades_requests_the_same_way(self):
        asha = self._candidate(3, requested=True)
        q1 = self._answers(asha)[0]
        q1.action_rescore_this_answer()

        calls, judge = self._judge()
        with judge, patch.object(
                scoring_svc, "_grade_on_own_cursor",
                lambda registry, uid, ctx, job:
                scoring_svc._grade_outcome(self.env, job)), \
                patch.object(self.env.cr, "commit", self.env.flush_all):
            self.env["assessments.be"]._drain_in_parallel(asha, workers=2)
        self.assertEqual(sorted(c["note"] for c in calls),
                         ["rescore(1)", "submission(2)"])
        self.assertEqual(set(self._answers(asha).mapped("llm_state")),
                         {"scored"})

    def test_a_bulk_save_that_lands_first_answers_the_request(self):
        """If a bulk call for the same answer was already in flight, whichever
        saves first wins - here the bulk one, so nothing is graded twice."""
        asha = self._candidate(1, requested=True)
        q = self._answers(asha)
        _scored, job = scoring_svc._prepare_submission(self.env, q)
        q.action_rescore_this_answer()

        scoring_svc._store_submission(
            self.env, job, [{"id": q.id, "score": 70}], None)

        self.assertEqual((q.llm_raw_100, q.rescore_request_key), (70.0, False))
        calls, judge = self._judge()
        with judge:
            asha._action_llm_score()
        self.assertFalse(calls)


@tagged("-at_install", "post_install")
class TestTheRequestAndTheQueue(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_no_ids_queue_every_unresolved_answer(self):
        asha = self._candidate(4, scored={0: 40}, errored=(1,), mcq=1)
        q = self._answers(asha)

        result = asha.action_rescore_individually()

        self.assertEqual(result["rescore"]["queued"], 3)
        self.assertEqual(
            [bool(k) for k in q.mapped("rescore_request_key")],
            [False, True, True, True, False])

    def test_ids_of_another_attempt_are_refused_and_nothing_is_queued(self):
        asha, ben = self._candidate(2), self._candidate(1)
        with self.assertRaises(RescoreRefused) as caught:
            asha.action_rescore_individually(
                self._answers(asha)[:1].question_id.ids
                + self._answers(ben).question_id.ids)
        self.assertEqual(caught.exception.code, "not_on_attempt")
        self.assertFalse(any(self._answers(asha).mapped("rescore_request_key")))

    def test_a_reached_per_candidate_cap_refuses(self):
        asha = self._candidate(1)
        self.env["ir.config_parameter"].sudo().set_param(
            _ICP % "per_evaluator_llm_cap_usd", "20")
        self.env["assessments.be.llm.usage"].create({
            "operation": "score_subjective", "model": "gemini-3-pro",
            "cost_usd": 20.5, "evaluator_id": asha.id, "note": "cap fixture"})

        with self.assertRaises(RescoreRefused):
            asha.action_rescore_individually()
        self.assertFalse(self._answers(asha).rescore_request_key)

    def test_the_request_writes_only_the_chosen_rows(self):
        """The candidate's row belongs to the grading lane, which may be
        holding it mid-call; the click touches only the answers it names."""
        from odoo.sql_db import Cursor
        asha = self._candidate(5, scored={0: 40}, errored=(1,))
        chosen = self._answers(asha)[:2]
        self.env.flush_all()
        seen = []
        execute = Cursor.execute

        def spy(cr, query, params=None, log_exceptions=True):
            execute(cr, query, params, log_exceptions)
            seen.append((cr._format(query, params), cr._obj.rowcount))

        with patch("odoo.sql_db.Cursor.execute", spy):
            asha.action_rescore_individually(chosen.question_id.ids)
            self.env.flush_all()

        updates = [(q, n) for q, n in seen if q.lstrip().upper().startswith(
            "UPDATE")]
        self.assertFalse([q for q, _n in updates
                          if '"assessments_be_evaluator"' in q], updates)
        self.assertEqual(
            sum(n for q, n in updates if '"assessments_be_response"' in q), 2,
            updates)
        self.assertTrue(all(chosen.mapped("rescore_request_key")))

    def test_the_chatter_logs_who_and_the_previous_mark(self):
        asha = self._candidate(2, scored={0: 40})
        q7 = self._answers(asha)[0]

        q7.action_rescore_this_answer()

        body = self.env["mail.message"].search([
            ("model", "=", "assessments.be"), ("res_id", "=", self.paper.id),
        ], order="id desc", limit=1).body
        for needle in ("Re-score requested", self.env.user.name,
                       asha.applicant_id.partner_name, q7.question_id.name,
                       "40/100", "gemini-old", "bundled:0ld0ld00"):
            self.assertIn(needle, body)

    def test_the_cron_takes_requests_first(self):
        bulk = self._candidate(1, requested=True)
        asha = self._candidate(1, scored={0: 40})
        self.assertLess(bulk.id, asha.id, "fixture guard: bulk is older")
        self._answers(asha).action_rescore_this_answer()

        picked = self.env["assessments.be"]._scoring_shard_evaluators(
            0, 1, limit=1)

        self.assertEqual(picked, asha)
        self.assertTrue(self.env["assessments.be"]._auto_score_eligible(asha),
                        "a scored, un-queued candidate with a request")

    def test_the_settle_clears_requests(self):
        asha = self._candidate(1, scored={0: 40})
        self._answers(asha).action_rescore_this_answer()

        self.paper._settle_scoring_cancelled()

        self.assertFalse(self._answers(asha).rescore_request_key)
        self.assertEqual(self._answers(asha).llm_raw_100, 40.0)

    def test_the_phase_counts_a_queued_rescore(self):
        self.env["ir.cron"].sudo().with_context(active_test=False).search([
            ("code", "like", "_cron_llm_auto_score"),
            ("model_id.model", "=", "assessments.be"),
        ]).write({"active": True,
                  "nextcall": fields.Datetime.now() + timedelta(minutes=1)})
        asha = self._candidate(1, scored={0: 40})
        self.assertEqual(self.paper.scoring_phase, "idle")

        self._answers(asha).action_rescore_this_answer()

        self.assertEqual(self.paper.scoring_phase, "queued")
        self.assertIn("1 queued", self.paper.scoring_summary)

    def test_the_odoo_buttons_use_the_one_path(self):
        answer_form = self.env.ref(
            "assessments_be_v2.assessments_be_response_form").arch
        self.assertIn('name="action_rescore_this_answer"', answer_form)
        self.assertIn('groups="assessments_be_v2.group_assessment_manager"',
                      answer_form)
        candidate_form = self.env.ref(
            "assessments_be_v2.assessments_be_evaluator_form").arch
        # ONE CONTROL NOW (swe-odoo-ui-9), in two spellings. "Score
        # Subjective" and "Reset & Re-score Errored" both called this method
        # with no arguments, so they were the same click with two promises
        # and the second reset nothing. What is left is one counted,
        # manager-only button - plus the same button carrying the released
        # confirmation, because Odoo's `confirm=` cannot be conditional.
        # Exactly one of the pair is ever visible.
        self.assertEqual(
            candidate_form.count('name="action_rescore_individually"'), 2,
            "the plain click and the released-attempt confirmation")
        self.assertEqual(candidate_form.count('name="rescore_label"'), 2)
        self.assertIn("rescore_confirm_released", candidate_form)

        asha = self._candidate(3, scored={0: 40, 1: 50}, errored=(2,))
        asha.action_rescore_individually()   # what the Re-score button calls
        self.assertEqual(
            [bool(k) for k in self._answers(asha).mapped("rescore_request_key")],
            [False, False, True])


@tagged("-at_install", "post_install")
class TestTheRescoreRoute(_Paper, HttpCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.authenticate("admin", "admin")

    def _post(self, ev, body):
        response = self.url_open(
            "/api/v1/attempts/%s/rescore" % ev.id, data=json.dumps(body),
            headers=_JSON, timeout=30)
        return response.status_code, response.json()

    def test_the_route_queues_and_never_calls_vertex(self):
        asha = self._candidate(3, scored={0: 40})
        q7 = self._answers(asha)[0]

        with patch.object(vertex_svc, "_call_vertex",
                          side_effect=AssertionError("graded in the request")):
            status, payload = self._post(
                asha, {"question_ids": [q7.question_id.id]})

        self.assertEqual(status, 200, payload)
        data = payload["data"]
        self.assertEqual((data["id"], data["queued"], data["skipped"],
                          data["question_ids"]),
                         (asha.id, 1, 0, [q7.question_id.id]))
        self.assertTrue(q7.rescore_request_key)
        self.assertEqual(q7.llm_raw_100, 40.0, "only the lane writes marks")

    def test_no_ids_queue_what_older_app_builds_expect(self):
        asha = self._candidate(3, scored={0: 40}, errored=(1,))

        status, payload = self._post(asha, {})

        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["queued"], 2)
        self.assertEqual(
            [bool(k) for k in self._answers(asha).mapped("rescore_request_key")],
            [False, True, True])

    def test_ids_of_another_attempt_are_a_422(self):
        asha, ben = self._candidate(1), self._candidate(1)

        status, payload = self._post(
            asha, {"question_ids": self._answers(ben).question_id.ids})

        self.assertEqual(status, 422, payload)
        self.assertEqual(payload["error"]["code"], "not_on_attempt")
        self.assertFalse(self._answers(asha).rescore_request_key)

    def test_a_reached_cap_is_a_409_spend_limit(self):
        asha = self._candidate(1)
        self.env["ir.config_parameter"].sudo().set_param(
            _ICP % "daily_llm_cap_usd", "1")
        self.env["assessments.be.llm.usage"].create({
            "operation": "score_subjective", "model": "gemini-3-pro",
            "cost_usd": 2.0, "note": "cap fixture"})

        status, payload = self._post(asha, {})

        self.assertEqual(status, 409, payload)
        self.assertEqual(payload["error"]["code"], "spend_limit")
        self.assertFalse(self._answers(asha).rescore_request_key)

    def test_the_answer_payloads_say_a_rescore_is_queued(self):
        asha = self._candidate(1, scored={0: 40})
        q7 = self._answers(asha)
        self._post(asha, {"question_ids": q7.question_id.ids})

        response = self.url_open(
            "/api/v1/responses/%s/%s" % (asha.id, q7.question_id.id),
            data=json.dumps({}), headers=_JSON, timeout=30)
        self.assertTrue(response.json()["data"]["rescore_requested"])
