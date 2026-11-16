# -*- coding: utf-8 -*-
"""What `POST /attempts/<id>/rescore` refuses, and why it says so.

One rule: a re-score never does something WIDER or more expensive than what
was asked for, and never reports "nothing to do" when the honest answer is
"not now".

  * swe-api-models-3 / qa-backend-api-4 - only an ABSENT (or null) key means
    "every unresolved answer" (W6). `[]`, a word, objects, or one unreadable
    id among good ones get 422 `invalid`: read as "no ids", one malformed
    payload would turn "re-score this answer" into a paid call per answer.
  * swe-api-models-4 / swe-api-models-6 / apc-4 (owner decision) - a candidate
    being graded right now is refused the same way with or without ids: 409
    `being_graded` (a 200 `queued: 0` reads in the app as "Nothing to
    re-score", i.e. "these answers are fine"). `/scoring/queue` reports what
    it queued and skipped, not what it selected.
  * swe-api-models-9 / qa-backend-api-19 (owner decision) - a released mark is
    one the candidate has already seen, so moving it takes `confirm: true`,
    the way `/scoring/requeue_errored` asks for `force`; without it, 409.
"""
import json
from unittest.mock import patch

from odoo.tests.common import HttpCase, TransactionCase, tagged

from ..models.assessment import RescoreRefused
from ..services import vertex as vertex_svc
from .test_a_running_lane_keeps_what_it_holds import a_lane_is_running
from .test_individual_scoring_stays_individual import _Paper

_JSON = {"Content-Type": "application/json"}


@tagged("-at_install", "post_install")
class TestAMalformedQuestionIdsListIsRefused(_Paper, HttpCase):
    """"Key absent" and "key present but unusable" are different requests."""

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.authenticate("admin", "admin")

    def _post(self, ev, body):
        response = self.url_open(
            "/api/v1/attempts/%s/rescore" % ev.id, data=json.dumps(body),
            headers=_JSON, timeout=30)
        return response.status_code, response.json()

    def _unusable(self, value):
        asha = self._candidate(4)
        status, payload = self._post(asha, {"question_ids": value})
        self.assertEqual(
            status, 422,
            "question_ids=%r was accepted and re-scored %s answer(s) - a "
            "shape nobody can read must not mean 'all of them': %s"
            % (value, payload.get("data", {}).get("queued"), payload))
        self.assertEqual(payload["error"]["code"], "invalid")
        self.assertFalse(
            any(self._answers(asha).mapped("rescore_request_key")),
            "nothing may be queued by a request that was refused")

    def test_an_empty_list_is_not_every_answer(self):
        self._unusable([])

    def test_a_word_is_not_every_answer(self):
        self._unusable("abc")

    def test_a_list_of_objects_is_not_every_answer(self):
        self._unusable([{"x": 1}])

    def test_an_object_is_not_every_answer(self):
        self._unusable({"a": 1})

    def test_one_unreadable_id_among_good_ones_is_refused(self):
        asha = self._candidate(2)
        ids = self._answers(asha).question_id.ids
        status, payload = self._post(asha, {"question_ids": ids + ["nope"]})
        self.assertEqual(status, 422, payload)
        self.assertFalse(any(self._answers(asha).mapped("rescore_request_key")))

    def test_an_absent_key_still_queues_todays_set(self):
        """The older-app contract, unchanged."""
        asha = self._candidate(3, scored={0: 40})
        status, payload = self._post(asha, {})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["queued"], 2)

    def test_an_explicit_null_reads_as_absent(self):
        asha = self._candidate(3, scored={0: 40})
        status, payload = self._post(asha, {"question_ids": None})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["queued"], 2)

    def test_a_comma_string_and_a_bare_int_still_work(self):
        asha = self._candidate(2)
        first, second = self._answers(asha)
        status, payload = self._post(
            asha, {"question_ids": "%s,%s" % (first.question_id.id,
                                              second.question_id.id)})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["queued"], 2)

        ben = self._candidate(2)
        status, payload = self._post(
            ben, {"question_ids": self._answers(ben)[0].question_id.id})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["queued"], 1)


@tagged("-at_install", "post_install")
class TestBeingGradedRefusesTheSameWayBothWays(_Paper, TransactionCase):
    """Owner decision: keep the refusal, make it consistent."""

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.busy = self._candidate(2, requested=True)
        self.busy.llm_state = "scoring"
        self.before = self._answers(self.busy).read(
            ["llm_state", "llm_attempts", "rescore_request_key"])

    def _assert_untouched(self):
        self.assertEqual(
            self._answers(self.busy).read(
                ["llm_state", "llm_attempts", "rescore_request_key"]),
            self.before, "an answer the lane is grading was rewritten")

    def test_no_ids_is_refused_like_chosen_ids(self):
        with a_lane_is_running(self.env), \
                self.assertRaises(RescoreRefused) as caught:
            self.busy.action_rescore_individually()
        self.assertEqual(caught.exception.code, "being_graded")
        self.assertIn("being graded right now", str(caught.exception))
        self._assert_untouched()

    def test_both_paths_say_the_same_thing(self):
        def refusal(question_ids):
            with a_lane_is_running(self.env), \
                    self.assertRaises(RescoreRefused) as caught:
                self.busy.action_rescore_individually(question_ids)
            return str(caught.exception)

        self.assertEqual(
            refusal(None),
            refusal(self._answers(self.busy).question_id.ids),
            "an admin must not get two different stories for one state")


@tagged("-at_install", "post_install")
class TestBeingGradedIsA409(_Paper, HttpCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.authenticate("admin", "admin")

    def test_the_route_answers_409_being_graded_with_no_ids(self):
        busy = self._candidate(2, requested=True)
        busy.llm_state = "scoring"
        with a_lane_is_running(self.env):
            response = self.url_open(
                "/api/v1/attempts/%s/rescore" % busy.id, data=json.dumps({}),
                headers=_JSON, timeout=30)
        payload = response.json()
        self.assertEqual(
            response.status_code, 409,
            "a no-ids re-score on a candidate mid-grade answered ok, which "
            "the app shows as 'Nothing to re-score': %s" % payload)
        self.assertEqual(payload["error"]["code"], "being_graded")


@tagged("-at_install", "post_install")
class TestTheQueueRouteReportsWhatItQueued(_Paper, HttpCase):
    """swe-api-models-6: both paths counted before the skip happened."""

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.authenticate("admin", "admin")
        self.busy = self._candidate(1, requested=True)
        self.busy.llm_state = "scoring"
        self.idle = self._candidate(1)

    def _queue(self, body):
        response = self.url_open(
            "/api/v1/scoring/queue", data=json.dumps(body), headers=_JSON,
            timeout=30)
        return response.status_code, response.json()

    def test_named_candidates_report_queued_and_skipped(self):
        with a_lane_is_running(self.env):
            status, payload = self._queue(
                {"evaluator_ids": [self.busy.id, self.idle.id]})
        self.assertEqual(status, 200, payload)
        self.assertEqual((payload["data"]["queued"], payload["data"]["skipped"]),
                         (1, 1), payload)

    def test_a_whole_paper_reports_queued_and_skipped(self):
        with a_lane_is_running(self.env):
            status, payload = self._queue({"assessment_id": self.paper.id})
        self.assertEqual(status, 200, payload)
        self.assertEqual((payload["data"]["queued"], payload["data"]["skipped"]),
                         (1, 1), payload)


@tagged("-at_install", "post_install")
class TestARescoreOfAReleasedMarkIsConfirmed(_Paper, TransactionCase):
    """Owner decision: released marks move only on purpose."""

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def test_a_released_attempt_is_refused_without_confirmation(self):
        asha = self._candidate(2, scored={0: 40})
        asha.results_released = True
        with self.assertRaises(RescoreRefused) as caught:
            asha.action_rescore_individually(
                [self._answers(asha)[0].question_id.id])
        self.assertEqual(caught.exception.code, "released_confirm_required")
        self.assertFalse(any(self._answers(asha).mapped("rescore_request_key")))

    def test_the_no_ids_path_is_refused_too(self):
        asha = self._candidate(2, scored={0: 40})
        asha.results_released = True
        with self.assertRaises(RescoreRefused):
            asha.action_rescore_individually()

    def test_confirmation_queues_it(self):
        asha = self._candidate(2, scored={0: 40})
        asha.results_released = True
        result = asha.action_rescore_individually(
            [self._answers(asha)[0].question_id.id], confirm_released=True)
        self.assertEqual(result["rescore"]["queued"], 1)

    def test_an_odoo_button_confirms_through_the_context(self):
        """What the answer form's confirm dialog passes."""
        asha = self._candidate(1)
        asha.results_released = True
        answer = self._answers(asha)[0]
        result = answer.with_context(
            rescore_confirm_released=True).action_rescore_this_answer()
        self.assertEqual(result["rescore"]["queued"], 1)

    def test_an_unreleased_attempt_needs_no_confirmation(self):
        asha = self._candidate(2, scored={0: 40})
        result = asha.action_rescore_individually(
            [self._answers(asha)[0].question_id.id])
        self.assertEqual(result["rescore"]["queued"], 1)


@tagged("-at_install", "post_install")
class TestTheRouteAsksForConfirmation(_Paper, HttpCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.authenticate("admin", "admin")

    def _post(self, ev, body):
        response = self.url_open(
            "/api/v1/attempts/%s/rescore" % ev.id, data=json.dumps(body),
            headers=_JSON, timeout=30)
        return response.status_code, response.json()

    def test_a_released_attempt_is_409_released_confirm_required(self):
        asha = self._candidate(1)
        asha.results_released = True
        with patch.object(vertex_svc, "_call_vertex",
                          side_effect=AssertionError("graded in the request")):
            status, payload = self._post(asha, {})
        self.assertEqual(status, 409, payload)
        self.assertEqual(payload["error"]["code"], "released_confirm_required")
        self.assertFalse(any(self._answers(asha).mapped("rescore_request_key")))

    def test_confirm_true_queues_it(self):
        asha = self._candidate(1)
        asha.results_released = True
        status, payload = self._post(asha, {"confirm": True})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["queued"], 1)
        self.assertTrue(self._answers(asha)[0].rescore_request_key)
