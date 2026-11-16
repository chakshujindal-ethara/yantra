# -*- coding: utf-8 -*-
"""Grading neither sticks nor spends where it should not, and Reset to Draft
asks before it erases released results.

  RV1-01 - erasing an attempt a lane was grading left it `scoring` forever,
  and the deploy gate refused every deploy after that.
  F1 - on the parallel lane an erase that committed mid-call did not collide,
  and the store wrote the grader's prose back onto the scrubbed answers.
  F2 - a `scoring` row left by a dead lane on a paper then cancelled was
  never selected again and held the deploy gate shut.
  RV1-02 - a paper cancelled mid-tick was still graded and billed for the rest
  of the tick, re-scores first.
  RV4-01 - the org-wide "Reset & re-score errored" was refused whole (422) for
  one candidate on a cancelled paper.
  A-257 - every re-post of a scored image_ab answer queued a paid re-grade.
  A-262 - the verdict-only, gated and key-drift stores counted an attempt
  none of them made.
  A-040 - Cancel then Reset to Draft erased released results without asking.
"""
from concurrent.futures import Future
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger

from ..models.assessment import RescoreRefused
from ..services import scoring as scoring_svc
from .test_a_running_lane_keeps_what_it_holds import a_lane_is_running
from .test_archive_suspends_and_delete_destroys import _call, _write_controller
from .test_individual_scoring_stays_individual import _Paper


@tagged("-at_install", "post_install")
class TestAnErasedAttemptIsNotLeftScoring(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_erasing_an_attempt_a_lane_holds_parks_it(self):
        asha = self._candidate(1, requested=True)
        asha.llm_state = "scoring"

        asha.action_erase_candidate_data()

        self.assertEqual(asha.llm_state, "cancelled")
        self.assertTrue(asha.llm_error)
        with a_lane_is_running(self.env):
            self.assertFalse(asha._being_graded(),
                             "the deploy gate counts it as grading forever")


@tagged("-at_install", "post_install")
class TestAParallelStoreSkipsAnAttemptErasedMidCall(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_nothing_is_stored_on_an_attempt_erased_while_its_call_was_out(self):
        asha = self._candidate(1, requested=True)
        answer = self._answers(asha)
        calls, judge = self._judge()

        def dispatch(job):
            done = Future()
            done.set_result(scoring_svc._grade_outcome(self.env, job))
            return done

        with judge:
            run = asha._llm_score_begin(dispatch)
            self.assertEqual(len(calls), 1, "fixture guard: the call went out")
            asha.action_erase_candidate_data()
            self.assertEqual(asha._llm_score_finish(run), 0)

        self.assertEqual(asha.llm_state, "cancelled")
        self.assertEqual(answer.llm_state, "pending")
        self.assertFalse(answer.llm_result_json,
                         "the grader's reply was written onto erased answers")


@tagged("-at_install", "post_install")
class TestAScoringRowNoLaneHoldsIsParked(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_cancel_parks_it_and_leaves_a_held_one(self):
        orphan = self._candidate(1, requested=True)
        orphan.llm_state = "scoring"        # its lane died mid-call
        self.paper.action_cancel()
        self.assertEqual(orphan.llm_state, "cancelled")

        self.paper = self._new_paper()
        held = self._candidate(1, requested=True)
        held.llm_state = "scoring"
        with a_lane_is_running(self.env):
            self.paper.action_cancel()
        self.assertEqual(held.llm_state, "scoring", "its lane still has it")


@tagged("-at_install", "post_install")
class TestACancelledPaperIsNotGradedMidTick(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_cancelling_mid_tick_stops_the_rest_of_the_tick(self):
        queued = self._candidate(1, requested=True)
        keyed = self._candidate(1, scored={0: 40})
        self._answers(keyed).action_rescore_this_answer()
        Assessment = self.env["assessments.be"]
        for ev in (queued, keyed):
            self.assertTrue(Assessment._auto_score_eligible(ev),
                            "fixture guard: both are the lane's work")

        self.paper.state = "cancelled"

        for ev, name in ((queued, "queued"), (keyed, "re-score")):
            with self.subTest(name):
                self.assertFalse(Assessment._auto_score_eligible(ev))


@tagged("-at_install", "post_install")
class TestAnOrgWideRetrySkipsACancelledPaper(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.env.user.group_ids = [(4, self.env.ref(
            "assessments_be_v2.group_assessment_manager").id)]

    def _requeue(self, **params):
        from unittest.mock import patch

        from ..controllers.api import admin as admin_api
        from ..controllers.api import common as api_common

        class _Req:
            env = self.env

            def __init__(self):
                self.params = params

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req()
        with patch.object(admin_api, "request", fake), \
                patch.object(api_common, "request", fake):
            return admin_api.EtpAssessmentApiAdmin(
            ).scoring_requeue_errored(**params)

    def test_the_live_paper_is_reset_and_the_cancelled_one_skipped(self):
        live = self._candidate(1, errored=(0,))
        gone = self._new_paper()
        dead = self._candidate(1, errored=(0,), paper=gone)
        gone.state = "cancelled"

        answer = self._requeue(evaluator_ids=[live.id, dead.id],
                               states=["failed", "error"])

        self.assertTrue(answer.get("ok"), answer)
        self.assertEqual(answer["data"]["skipped"], 1)
        self.assertEqual(answer["data"]["requeued"], 1)
        self.assertEqual(answer["data"]["answers_reset"], 1)
        self.assertEqual(self._answers(live).llm_state, "pending")
        self.assertTrue(live.scoring_requested)
        self.assertEqual(self._answers(dead).llm_state, "error")
        self.assertFalse(dead.scoring_requested)


class _Comparison(_Paper):
    """One submitted image_ab answer: a verdict pick and a justification."""

    def _comparison(self, reasoning="A is sharper; B has lighting artefacts."):
        question = self.env["assessments.be.question"].create({
            "name": "AB %s" % uuid4().hex[:6],
            "question_type": "image_ab",
            "prompt": "Which render is better?",
            "official_reasoning": reasoning,
            "generator_id": self.generator.id,
            "assessment_ids": [(4, self.paper.id)],
        })
        self.overall = self.env["assessments.be.question.dimension"].create({
            "question_id": question.id,
            "name": "Overall Choice",
            "option_line_ids": [
                (0, 0, {"name": "A", "sequence": 0, "is_correct": True}),
                (0, 0, {"name": "B", "sequence": 10, "is_correct": False}),
            ],
        })
        ev = self._candidate(0)
        return self.env["assessments.be.response"].create({
            "assessment_evaluator_id": ev.id,
            "evaluator_id": ev.applicant_id.id,
            "question_id": question.id,
            "assessment_id": self.paper.id,
            "state": "submitted",
            "justification": "A is sharper and follows the brief.",
            "line_ids": [(0, 0, {
                "question_dimension_id": self.overall.id,
                "selected_option_id": self.overall.option_line_ids.sorted(
                    "sequence")[0].id})],
        })


@tagged("-at_install", "post_install")
class TestAnUnchangedComparisonIsNotReGraded(_Comparison, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.paper.llm_auto_score = True

    def _scored(self):
        answer = self._comparison()
        self.assertTrue(answer._image_ab_uses_llm(), "fixture guard")
        scoring_svc._store_scored(answer, {"score": 80})
        self.assertEqual(answer.llm_state, "scored")
        return answer

    def test_an_unchanged_repost_is_not_queued_again(self):
        answer = self._scored()

        answer._enqueue_subjective_scoring()

        self.assertEqual(answer.llm_state, "scored")
        self.assertFalse(answer.assessment_evaluator_id.scoring_requested)

    def test_a_changed_text_or_pick_is_queued_once(self):
        edits = {
            "text": lambda a: a.write({"justification": "B, on reflection."}),
            "pick": lambda a: a.line_ids.write({
                "selected_option_id": self.overall.option_line_ids.sorted(
                    "sequence")[1].id}),
        }
        for name, edit in edits.items():
            with self.subTest(name):
                answer = self._scored()
                edit(answer)

                answer._enqueue_subjective_scoring()

                self.assertEqual(answer.llm_state, "pending")
                self.assertTrue(
                    answer.assessment_evaluator_id.scoring_requested)


@tagged("-at_install", "post_install")
class TestAVerdictOnlyStoreSpendsNoAttempt(_Comparison, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_the_verdict_only_store_leaves_attempts_alone(self):
        answer = self._comparison(reasoning=False)
        self.assertFalse(answer._image_ab_uses_llm(), "fixture guard")

        scoring_svc._store_ab_verdict_only(answer)

        self.assertEqual(answer.llm_state, "scored")
        self.assertEqual(answer.llm_attempts, 0, "no LLM call was made")

    def test_the_gated_and_key_drift_stores_leave_attempts_alone(self):
        stores = {
            "gated": lambda a: scoring_svc._store_gated(
                a, {"gate": "prompt_injection", "flags": []}),
            "key drift": lambda a: scoring_svc._store_ab_key_drift(
                a, ["Q1: stored A, construction B"]),
        }
        for name, store in stores.items():
            with self.subTest(name):
                answer = self._comparison()
                self.assertFalse(answer.rescore_request_key,
                                 "fixture guard: a first grade")

                with mute_logger(
                        "odoo.addons.assessments_be_v2.services.scoring"):
                    store(answer)

                self.assertEqual(
                    (answer.llm_state, answer.llm_raw_100), ("scored", 0.0))
                self.assertEqual(answer.llm_attempts, 0,
                                 "no LLM call was made")


@tagged("-at_install", "post_install")
class TestResetToDraftAsksBeforeErasingReleasedResults(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.env.user.group_ids = [(4, self.env.ref(
            "assessments_be_v2.group_assessment_manager").id)]
        self.controller = _write_controller()

    def _cancelled(self, released):
        evs = self._candidate(1) | self._candidate(1)
        evs[:released].write({"results_released": True})
        self.paper.action_cancel()
        return evs

    def test_the_model_refuses_without_confirmation(self):
        evs = self._cancelled(released=2)

        with self.assertRaises(RescoreRefused) as caught:
            self.paper.action_reset_draft()

        self.assertEqual(caught.exception.code, "released_results")
        self.assertEqual(caught.exception.http_status, 409)
        self.assertIn("2 candidate(s)", str(caught.exception))
        self.assertEqual(len(evs.exists()), 2, "nothing was deleted")
        self.assertEqual(self.paper.state, "cancelled")

        self.paper.with_context(confirm_released=True).action_reset_draft()
        self.assertFalse(evs.exists())
        self.assertEqual(self.paper.state, "draft")

    def test_the_route_is_409_released_results_until_confirmed(self):
        evs = self._cancelled(released=1)

        refused = _call(self, "assessment_reset_draft",
                        assessment_id=self.paper.id)

        self.assertEqual(refused["__status"], 409, refused)
        self.assertEqual(refused["error"]["code"], "released_results")
        self.assertIn("1 candidate(s)", refused["error"]["message"])
        self.assertEqual(len(evs.exists()), 2)

        done = _call(self, "assessment_reset_draft",
                     assessment_id=self.paper.id, confirm_released=True)
        self.assertTrue(done.get("ok"), done)
        self.assertFalse(evs.exists())
        self.assertEqual(self.paper.state, "draft")

    def test_a_paper_with_nothing_released_resets_as_before(self):
        evs = self._cancelled(released=0)

        self.paper.action_reset_draft()

        self.assertFalse(evs.exists())
        self.assertEqual(self.paper.state, "draft")
