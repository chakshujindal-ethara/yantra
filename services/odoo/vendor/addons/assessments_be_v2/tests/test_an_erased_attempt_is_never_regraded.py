# -*- coding: utf-8 -*-
"""An erased attempt keeps the mark the erase left it with.

Erasure replaces every written answer with the tag `[anonymized]` - non-empty
on purpose, so `needs_llm` stays true and the answer keeps its place in the
scoring denominator - and KEEPS the numeric score, which is exactly what
"Numeric scores and pass/fail were kept" tells the operator.

Re-scoring one then paid the grader to mark the literal string `[anonymized]`
and replaced the kept mark with whatever came back: the erase promise broken, a
call wasted, and a candidate's result able to flip. Both lanes that queue a
re-grade - the chosen-answers one behind Re-score This Answer and
`POST /attempts/<id>/rescore`, and the reset behind Retry Failed Scoring -
refuse an erased attempt now.
"""
from odoo.tests.common import TransactionCase, tagged

from ..models.assessment import RescoreRefused
from .test_individual_scoring_stays_individual import _Paper


@tagged("-at_install", "post_install")
class TestAnErasedAttemptIsNeverRegraded(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_a_chosen_answer_of_an_erased_attempt_is_refused(self):
        asha = self._candidate(2, scored={0: 75, 1: 60})
        answer = self._answers(asha)[0]
        asha.action_erase_candidate_data()
        self.assertTrue(asha.pii_anonymized)

        with self.assertRaises(RescoreRefused) as caught:
            asha.action_rescore_individually([answer.question_id.id])

        self.assertEqual(caught.exception.code, "erased",
                         "the route answers 409 `erased` off this code")
        self.assertFalse(answer.rescore_request_key,
                         "nothing may be queued on an erased attempt")
        self.assertEqual(answer.llm_raw_100, 75.0, "the kept mark stands")

    def test_a_whole_attempt_rescore_is_refused_the_same_way(self):
        asha = self._candidate(2)
        asha.action_erase_candidate_data()
        with self.assertRaises(RescoreRefused) as caught:
            asha.action_rescore_individually()
        self.assertEqual(caught.exception.code, "erased")
        self.assertFalse(any(self._answers(asha).mapped("rescore_request_key")))

    def test_a_reset_leaves_an_erased_attempt_alone(self):
        asha = self._candidate(2, errored=(0,))
        errored = self._answers(asha)[0]
        asha.action_erase_candidate_data()

        result = asha.action_reset_failed_scoring()

        self.assertEqual(result["reset"]["answers"], 0,
                         "an erased attempt has nothing left to re-grade")
        self.assertEqual(result["reset"]["skipped"], 1)
        self.assertEqual(errored.llm_state, "error",
                         "the answer is not sent back to the grader")

    def test_a_reset_still_works_on_an_attempt_that_was_not_erased(self):
        asha = self._candidate(2, errored=(0,))
        result = asha.action_reset_failed_scoring()
        self.assertEqual(result["reset"]["answers"], 1)
        self.assertEqual(self._answers(asha)[0].llm_state, "pending")
