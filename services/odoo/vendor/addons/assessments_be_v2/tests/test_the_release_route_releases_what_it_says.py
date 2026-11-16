# -*- coding: utf-8 -*-
"""`POST /assessments/<id>/release` and `/scoring/queue`, over HTTP.

M1 (G2-01, R2-07, R4-01, R6-06): release-all crashed with a 500 and released
nobody; once fixed, its reply listed skipped candidates as released.
M1 / N12 (R4-02): unreadable ids fell through to the whole cohort.
G1-23: releasing only a candidate being graded answered like a success.
An id like 1e400 gave a 500 on /release, /scoring/queue and /rescore.
"""
import json

from odoo.tests.common import HttpCase, tagged

from .test_a_running_lane_keeps_what_it_holds import a_lane_is_running
from .test_individual_scoring_stays_individual import _Paper

_JSON = {"Content-Type": "application/json"}
_UNREADABLE = ("abc", [{"id": 1}], True, {"a": 1}, ["7", "x"])


@tagged("-at_install", "post_install")
class TestTheReleaseRoute(_Paper, HttpCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.authenticate("admin", "admin")
        self.busy = self._candidate(1, requested=True)
        self.busy.llm_state = "scoring"
        self.idle = self._candidate(1, scored={0: 80})

    def _post(self, url, body):
        response = self.url_open(url, data=json.dumps(body), headers=_JSON,
                                 timeout=30)
        return response.status_code, response.json()

    def _release(self, body):
        return self._post(
            "/api/v1/assessments/%s/release" % self.paper.id, body)

    def _released(self):
        cohort = self.paper.assessment_evaluator_ids
        cohort.invalidate_recordset(["results_released"])
        return cohort.filtered("results_released")

    def test_release_all_skips_the_candidate_a_lane_holds(self):
        with a_lane_is_running(self.env):
            status, payload = self._release({})
        self.assertEqual(status, 200, payload)
        data = payload["data"]
        self.assertEqual((data["released_count"], data["skipped_count"]),
                         (1, 1), data)
        self.assertEqual([c["id"] for c in data["candidates"]],
                         [self.idle.id],
                         "a skipped candidate was listed as released")
        self.assertEqual(self._released(), self.idle)
        self.assertTrue(data["notice"]["is_warning"])

    def test_unreadable_ids_release_nobody(self):
        for value in ([], None) + _UNREADABLE:
            status, payload = self._release({"evaluator_ids": value})
            self.assertEqual(status, 422, (value, payload))
            self.assertEqual(payload["error"]["code"], "invalid")
            self.assertIn("evaluator ids", payload["error"]["message"])
        self.assertFalse(self._released(),
                         "an unreadable id list released the cohort")

    def test_only_a_candidate_being_graded_is_not_a_success(self):
        with a_lane_is_running(self.env):
            status, payload = self._release(
                {"evaluator_ids": [str(self.busy.id)]})
        self.assertEqual(status, 200, payload)
        data = payload["data"]
        self.assertEqual((data["released_count"], data["skipped_count"],
                          data["still_grading_count"]), (0, 1, 0), data)
        self.assertEqual(data["candidates"], [])
        self.assertTrue(data["notice"]["is_warning"], data)
        self.assertIn("not released", data["notice"]["message"])
        self.assertFalse(self._released())

    def test_named_ids_list_only_what_this_call_released(self):
        self.idle.results_released = True
        other = self._candidate(1, scored={0: 70})
        status, payload = self._release(
            {"evaluator_ids": [self.idle.id, other.id]})
        self.assertEqual(status, 200, payload)
        data = payload["data"]
        self.assertEqual(data["released_count"], 1)
        self.assertEqual([c["id"] for c in data["candidates"]], [other.id],
                         "an earlier release was reported as this one")
        self.assertNotIn("notice", data)

    def test_the_queue_route_refuses_unreadable_ids(self):
        waiting = self._candidate(1)
        for value in _UNREADABLE:
            status, payload = self._post(
                "/api/v1/scoring/queue",
                {"assessment_id": self.paper.id, "evaluator_ids": value})
            self.assertEqual(status, 422, (value, payload))
            self.assertEqual(payload["error"]["code"], "invalid")
        waiting.invalidate_recordset(["scoring_requested"])
        self.assertFalse(waiting.scoring_requested,
                         "an unreadable id list queued the whole paper")

    def test_an_id_past_a_float_is_invalid_not_a_crash(self):
        """JSON 1e400 reads as infinity; int() raised OverflowError, a 500."""
        for url, raw in (
                ("/api/v1/assessments/%s/release" % self.paper.id,
                 '{"evaluator_ids": [1e400]}'),
                ("/api/v1/scoring/queue", '{"assessment_id": %d, '
                 '"evaluator_ids": [1e400]}' % self.paper.id),
                ("/api/v1/attempts/%s/rescore" % self.idle.id,
                 '{"question_ids": [1e400]}')):
            response = self.url_open(url, data=raw, headers=_JSON, timeout=30)
            self.assertEqual(response.status_code, 422, (url, response.text))
            self.assertEqual(response.json()["error"]["code"], "invalid")
        self.assertFalse(self._released())

    def test_the_queue_route_still_reads_an_empty_list_as_no_ids(self):
        """Both app builds send `evaluator_ids: []` with Score All."""
        waiting = self._candidate(1)
        status, payload = self._post(
            "/api/v1/scoring/queue",
            {"assessment_id": self.paper.id, "evaluator_ids": []})
        self.assertEqual(status, 200, payload)
        waiting.invalidate_recordset(["scoring_requested"])
        self.assertTrue(waiting.scoring_requested)
