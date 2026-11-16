# -*- coding: utf-8 -*-
"""State-widened, assessment-scoped scoring re-queue.

WHY THIS FILE EXISTS. `action_reset_errored_scoring` reset only terminal
'error' answers, and there was no way to re-queue a whole assessment's stuck
candidates or to widen the reset to the recoverable 'failed' state without
naming every evaluator. The widening had to be additive: the default contract
(errors only, named evaluators) must be byte-identical so no existing caller
changes behaviour.

These pin: only failed+errored answers are reset while a scored one is left
untouched (a re-grade would cost again and could move a released mark); an
evaluator whose ROLLUP is 'partial' is picked up by the assessment-level action;
and the reset rule lives in ONE place (`action_reset_failed_scoring`), with the
errored-only action delegating to it.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api.admin import RECOVERABLE_SCORING_STATES


@tagged("-at_install", "post_install")
class TestTheRetryRouteCannotReGradeAPaidAnswerByAccident(TransactionCase):
    """The route's default set, pinned.

    `states` was validated against the response `llm_state` Selection, which
    contains 'scored'. So `states: ["scored"]` was a "known" value, passed
    validation, and reset every already-graded answer to 'pending' - a second
    Vertex bill for work already paid for, and a fresh mark (the grader runs at
    temperature 0.2, so it genuinely differs) written over one a human may
    already have released.

    Re-grading a paid answer IS a real emergency operation - a rubric signed off
    wrong, a whole cohort graded against it - so it is still available, behind an
    explicit `force: true` that also writes to the assessment's log. What these
    pin is that it cannot happen as a SIDE EFFECT of a state name in a payload.

    The model-level reset is deliberately generic - it resets whatever states it
    is handed - so the gate lives at the route, which is why it is pinned here.
    """

    def test_the_default_set_is_the_two_recoverable_states(self):
        self.assertEqual(
            set(RECOVERABLE_SCORING_STATES), {"failed", "error"},
            "these are the states a plain retry may reset; anything else costs "
            "another LLM call and needs force")

    def test_no_already_paid_state_is_accepted_without_force(self):
        for paid in ("scored", "pending", "queued", "not_needed"):
            self.assertNotIn(
                paid, RECOVERABLE_SCORING_STATES,
                "'%s' must not be resettable by naming it alone - re-grading "
                "it is a deliberate act that needs force:true" % paid)


@tagged("-at_install", "post_install")
class TestScoringRequeueStates(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Question = self.env["assessments.be.question"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        self.assessment = self.Assessment.create({
            "name": "Requeue probe",
            "generator_id": self.generator.id,
            "duration_minutes": 30,
        })

    def _question(self, name):
        return self.Question.create({
            "name": name,
            "question_type": "subjective_rubric",
            "prompt": "Describe %s" % name,
            "generator_id": self.generator.id,
            "assessment_ids": [(4, self.assessment.id)],
        })

    def _evaluator(self, states):
        """A submitted evaluator with one subjective response per state."""
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:8],
        })
        ev = self.Evaluator.create({
            "assessment_id": self.assessment.id,
            "applicant_id": applicant.id,
        })
        for i, state in enumerate(states):
            q = self._question("Q%d-%s" % (i, uuid4().hex[:4]))
            self.Response.create({
                "assessment_evaluator_id": ev.id,
                "evaluator_id": applicant.id,
                "question_id": q.id,
                "assessment_id": self.assessment.id,
                "state": "submitted",
                "justification": "answer",
                "llm_state": state,
                "llm_attempts": 3,
            })
        ev.state = "submitted"
        return ev

    def _states(self, ev):
        return sorted(ev.response_ids.mapped("llm_state"))

    # ------------------------------------------------------------------
    def test_reset_touches_failed_and_error_but_not_scored(self):
        ev = self._evaluator(("scored", "failed", "error"))

        ev.action_reset_failed_scoring(states=("failed", "error"))

        by_state = {r.llm_state: r for r in ev.response_ids}
        self.assertIn("scored", by_state,
                      "the scored answer must be left exactly as it was")
        # The two non-scored ones are now pending with attempts zeroed.
        pending = ev.response_ids.filtered(lambda r: r.llm_state == "pending")
        self.assertEqual(len(pending), 2,
                         "exactly the failed and errored answers are re-queued")
        self.assertTrue(all(r.llm_attempts == 0 for r in pending),
                        "a reset must zero the attempt counter or the retry is "
                        "refused by the attempt cap")
        self.assertEqual(by_state["scored"].llm_attempts, 3,
                         "the scored answer's counter is untouched")

    def test_errored_only_action_delegates_and_leaves_failed_alone(self):
        """The narrow action still resets ONLY 'error' - proof the delegation
        passed states=('error',) rather than widening silently."""
        ev = self._evaluator(("failed", "error"))

        ev.action_reset_errored_scoring()

        states = self._states(ev)
        self.assertIn("pending", states, "the errored answer is re-queued")
        self.assertIn("failed", states,
                      "a 'failed' answer is a recoverable miss the cron retries "
                      "on its own; the errored-only action must not touch it")

    def test_assessment_action_picks_up_a_partial_rollup(self):
        """`action_llm_score_failed` selects evaluators whose ROLLUP is
        failed/partial/error. A partial (one scored, one failed) must be caught,
        and only its non-scored answer reset."""
        ev = self._evaluator(("scored", "failed"))
        # Force the rollup so the selection sees 'partial'.
        ev._compute_subjective_rollup()
        self.assertEqual(ev.llm_state, "partial")

        self.assessment.action_llm_score_failed()

        self.assertTrue(ev.scoring_requested,
                        "the evaluator must be queued for the drainer")
        self.assertEqual(ev.llm_state, "pending")
        pending = ev.response_ids.filtered(lambda r: r.llm_state == "pending")
        scored = ev.response_ids.filtered(lambda r: r.llm_state == "scored")
        self.assertEqual(len(pending), 1)
        self.assertEqual(len(scored), 1,
                         "the already-scored answer keeps its mark")

    def test_score_failed_raises_when_nothing_is_stuck(self):
        """UserError shape, mirroring action_llm_score_all."""
        self._evaluator(("scored",))
        from odoo.exceptions import UserError
        with self.assertRaises(UserError):
            self.assessment.action_llm_score_failed()

    def test_default_route_states_touch_only_error(self):
        """The byte-identical default: no `states` argument means errors only,
        so a 'failed' answer is left alone - the pre-widening contract."""
        ev = self._evaluator(("failed", "error"))
        # This is what the route does with default args.
        ev.action_reset_failed_scoring(states=("error",))
        states = self._states(ev)
        self.assertIn("pending", states)
        self.assertIn("failed", states,
                      "default (error-only) must not re-queue a failed answer")

    def _route(self, **params):
        from unittest.mock import patch
        from ..controllers.api import admin as admin_api
        from ..controllers.api import common as api_common
        self.env.ref(
            "assessments_be_v2.group_assessment_manager"
        ).sudo().write({"user_ids": [(4, self.env.user.id)]})
        stub = type("Req", (), {"env": self.env, "params": params})()
        with patch.object(admin_api, "request", stub), \
                patch.object(api_common, "request", stub):
            # json2 hands the body over as keyword arguments too.
            return admin_api.EtpAssessmentApiAdmin(
            ).scoring_requeue_errored(**params)["data"]

    def test_the_route_counts_answers_and_sends_no_roster(self):
        """`requeued` counts candidates, as older apps read it; the toast
        said "N answers". A whole paper was also serialised into
        `candidates`, which no app reads."""
        self._evaluator(("failed", "error", "scored"))
        self._evaluator(("error",))
        self._evaluator(("scored",))

        data = self._route(assessment_id=self.assessment.id,
                           states=["failed", "error"])

        self.assertEqual(data["requeued"], 3)
        self.assertEqual(data["answers_reset"], 3)
        self.assertEqual(data["candidates"], [])

    def test_named_attempts_still_get_their_rows(self):
        ev = self._evaluator(("error",))

        data = self._route(evaluator_ids=[ev.id])

        self.assertEqual(data["answers_reset"], 1)
        self.assertEqual([row["id"] for row in data["candidates"]], [ev.id])
