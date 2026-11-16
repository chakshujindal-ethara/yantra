# -*- coding: utf-8 -*-
"""`/api/v1/attempts?changed_since=` returns only the attempts that changed.

The console re-walked every attempt on every poll. It now asks for what changed
since the last answer's `meta.server_time` (minus 5 s), so two things must hold:

  * every value a row SHOWS moves the attempt's `write_date` - or is caught by
    the assessment branch of the filter - or a change never reaches the screen;
  * `meta.server_time` is ISO-8601 UTC ending in `Z` (the client ignores
    anything else) and never later than the read it describes.

Stamps are set by SQL because one test transaction gives every write the same
`cr.now()`.
"""
from datetime import timedelta
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ..controllers.api import serializers as S
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class TestAPollFetchesOnlyWhatChanged(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.controller = api_admin.EtpAssessmentApiAdmin()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        self.question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric", "prompt": "Answer it.",
            "difficulty": "easy", "generator_id": generator.id})
        self.assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, self.question.ids)]})
        self.applicants = self.env["hr.applicant"].create([{
            "partner_name": "Cand %d %s" % (i, uuid4().hex[:6]),
            "email_from": "c%d.%s@example.com" % (i, uuid4().hex[:8]),
        } for i in range(3)])
        self.rows = self.env["assessments.be.evaluator"].create([{
            "assessment_id": self.assessment.id, "applicant_id": a.id,
        } for a in self.applicants]).sorted("id")
        self.now = self.env.cr.now()
        self._stamp(self.rows, hours=2)
        self._stamp(self.assessment, hours=2)
        self.since = S.iso(self.now - timedelta(hours=1))

    def _stamp(self, records, **ago):
        self.env.flush_all()
        self.env.cr.execute(
            'UPDATE "%s" SET write_date = %%s WHERE id IN %%s'
            % records._table, (self.now - timedelta(**ago), tuple(records.ids)))
        records.invalidate_recordset()

    def _poll(self, **params):
        self.env.flush_all()
        return call_route(api_admin, self.controller, "attempt_list", self.env,
                          assessment_id=self.assessment.id, **params)

    def _ids(self, response):
        self.assertEqual(status_of(response), 200, response)
        return [row["id"] for row in response["data"]]

    def test_server_time_is_iso_utc_ending_in_z(self):
        for params in ({}, {"changed_since": self.since}):
            with self.subTest(**params):
                stamp = self._poll(**params)["meta"]["server_time"]
                self.assertRegex(
                    stamp, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
                self.assertLessEqual(stamp, S.iso(self.env.cr.now()))

    def test_without_changed_since_every_attempt_comes_back(self):
        self.assertEqual(sorted(self._ids(self._poll())), self.rows.ids)

    def test_only_the_changed_attempt_comes_back(self):
        self.rows[1].write({"manual_flagged": True})

        self.assertEqual(self._ids(self._poll(changed_since=self.since)),
                         [self.rows[1].id])

    def test_most_recently_changed_first_and_still_paged(self):
        self._stamp(self.rows[0], minutes=10)
        self._stamp(self.rows[2], minutes=5)

        first = self._poll(changed_since=self.since, limit=1)
        second = self._poll(changed_since=self.since, limit=1, offset=1)

        self.assertEqual(self._ids(first) + self._ids(second),
                         [self.rows[2].id, self.rows[0].id])
        self.assertEqual(first["meta"]["total"], 2)
        self.assertTrue(first["meta"]["has_more"])
        self.assertFalse(second["meta"]["has_more"])

    def test_an_answer_moves_the_attempt(self):
        """Scores, answered counts, grading state and flags are stored
        computes over the answers; their recompute stamps the attempt."""
        row = self.rows[0]
        self.env["assessments.be.response"].create({
            "question_id": self.question.id,
            "assessment_id": self.assessment.id,
            "evaluator_id": row.applicant_id.id,
            "assessment_evaluator_id": row.id,
            "state": "submitted",
            "justification": "An answer."})
        row.invalidate_recordset()
        self.assertEqual(row.answered_count, 1, "the fixture must answer")

        self.assertEqual(self._ids(self._poll(changed_since=self.since)),
                         [row.id])

    def test_a_paper_setting_change_brings_its_attempts(self):
        """`violation_limit_breached` and the paper's name are read off the
        assessment, not stored on the attempt."""
        self.assessment.write({"max_violations": 1})

        self.assertEqual(
            sorted(self._ids(self._poll(changed_since=self.since))),
            self.rows.ids)

    def test_an_unreadable_changed_since_is_refused(self):
        response = self._poll(changed_since="yesterday")

        self.assertEqual(status_of(response), 422)
        self.assertEqual(response["error"]["code"], "invalid")

    def test_a_change_inside_the_asked_second_is_not_dropped(self):
        """Odoo rounds `> 09:59:55` up to `>= 09:59:56`; a row stamped
        09:59:55.4 must still come back to a client asking from 09:59:55."""
        second = (self.now - timedelta(minutes=30)).replace(microsecond=0)
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be_evaluator SET write_date = %s WHERE id = %s",
            (second + timedelta(milliseconds=400), self.rows[0].id))
        self.rows.invalidate_recordset()

        self.assertEqual(
            self._ids(self._poll(changed_since=S.iso(second))),
            [self.rows[0].id])
