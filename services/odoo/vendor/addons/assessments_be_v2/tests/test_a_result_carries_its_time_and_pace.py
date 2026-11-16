# -*- coding: utf-8 -*-
"""Time analysis belongs to the candidate's result, and the server owns the median.

The console used to work "time taken, the test's median, Fast/Normal/Slow" out
in the browser from whatever attempts it had cached, so an attempt opened by
direct link was compared with itself. The server now sends the paper's median
on the attempt DETAIL route (`test_median_seconds`) and the Results export
carries four appended columns: `submitted_at`, `time_taken_minutes`,
`test_median_minutes`, `pace`.

What is pinned here is the arithmetic at its edges, because every one of these
is a place a "close enough" implementation quietly differs from the client:
the even-count median rounds UP (100 s and 101 s give 101), a sitting without
both ends or with a non-positive span is not a data point, and a pace ratio is
rounded half up to two decimals BEFORE it meets the 0.75 / 1.25 cut-offs.
"""
import csv
import io
import json
from datetime import datetime, timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ..services import export, pace
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"

#: The header BEFORE the time columns existed. Somebody's spreadsheet is keyed
#: to these positions, so they are pinned as a literal rather than derived.
OLD_RESULTS_COLUMNS = [
    "rank", "candidate", "email", "assessment", "assessment_state",
    "candidate_state",
    "objective_score", "objective_max",
    "subjective_marks", "subjective_max",
    "total_score", "total_max", "score_percent", "pass_threshold",
    "result", "subjective_scoring_state", "results_released",
    "is_locked", "violation_count", "violation_detail", "started_at",
    "Flagged", "Flag Remarks",
]
TIME_COLUMNS = ["submitted_at", "time_taken_minutes", "test_median_minutes",
                "pace"]
#: The per-candidate roster facts, appended after the time columns so this is
#: the one per-candidate file. Two integers on purpose: "8 / 14" in one cell is
#: read as a date by spreadsheets.
ROSTER_COLUMNS = ["invite_state", "answered_count", "question_count"]
#: The AI proctoring violations, counted apart (R5), appended after the roster.
AI_COLUMNS = ["ai_violation_count", "ai_violation_detail"]

START = datetime(2026, 10, 6, 9, 0, 0)


@tagged("-at_install", "post_install")
class TestAResultCarriesItsTimeAndPace(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.controller = api_admin.EtpAssessmentApiAdmin()
        self.paper = self._paper()

    def _paper(self):
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        return self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id})

    def _sit(self, paper, seconds=None, name=None, started=START,
             submitted=None, no_deadline=False):
        """A sitting that began at `started` and was stamped `seconds` later.

        `seconds=None` leaves the sitting unstarted and unsubmitted; pass
        `started` / `submitted` explicitly for a half-stamped one. The stamps
        go in with `write` and no `state`, so nothing re-stamps `submitted_at`.
        The paper is 30 minutes (1800 s), so the sitting's deadline is
        `started + 1800 s`; `seconds` past that is a late settlement.
        `no_deadline` clears it, as for a sitting that has none.
        """
        name = name or "Cand %s" % uuid4().hex[:6]
        applicant = self.env["hr.applicant"].create({
            "partner_name": name,
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id})
        if seconds is not None:
            ev.write({"started_at": started,
                      "submitted_at": started + timedelta(seconds=seconds)})
        elif started is not START or submitted:
            ev.write({"started_at": started if started is not START else False,
                      "submitted_at": submitted or False})
        if no_deadline:
            ev.write({"deadline_datetime": False})
        return ev

    def _detail(self, evaluator):
        out = call_route(api_admin, self.controller, "attempt_detail", self.env,
                         path={"evaluator_id": evaluator.id})
        self.assertEqual(status_of(out), 200, out)
        return out["data"]

    def _csv(self, paper):
        content = export._write_csv(
            export.RESULTS_COLUMNS, export.results_rows(paper)).decode("utf-8")
        reader = csv.DictReader(io.StringIO(content))
        return reader.fieldnames, {r["candidate"]: r for r in reader}

    # -- the median -----------------------------------------------------------

    def test_an_odd_count_takes_the_middle_value(self):
        sittings = [self._sit(self.paper, s) for s in (600, 60, 120)]
        self.assertEqual(pace.median_seconds(self.paper), 120)
        self.assertEqual(
            self._detail(sittings[0])["test_median_seconds"], 120)

    def test_an_even_count_rounds_the_two_middles_up(self):
        """100 s and 101 s give 101, not 100: the client rounds half up, and a
        server that truncated would tag the same sitting differently."""
        for s in (100, 101):
            ev = self._sit(self.paper, s)
        self.assertEqual(pace.median_seconds(self.paper), 101)
        self.assertEqual(self._detail(ev)["test_median_seconds"], 101)
        other = self._paper()
        for s in (100, 102):
            self._sit(other, s)
        self.assertEqual(pace.median_seconds(other), 101)
        four = self._paper()
        for s in (10, 100, 101, 5000):
            self._sit(four, s)
        self.assertEqual(
            pace.median_seconds(four), 101, "only the two middles count")

    def test_no_qualifying_sitting_is_null_on_the_wire_and_empty_in_the_export(
            self):
        pending = self._sit(self.paper, name="Not Started")
        self.assertIsNone(pace.median_seconds(self.paper))
        data = self._detail(pending)
        self.assertIn("test_median_seconds", data)
        self.assertIsNone(data["test_median_seconds"])
        _header, rows = self._csv(self.paper)
        row = rows["Not Started"]
        for col in TIME_COLUMNS:
            self.assertEqual(row[col], "", col)

    def test_a_sitting_that_cannot_give_a_span_is_ignored(self):
        self._sit(self.paper, 120)
        # Started but never submitted, and submitted with no start.
        self._sit(self.paper, started=START + timedelta(hours=1))
        self._sit(self.paper, started=START, submitted=START + timedelta(
            seconds=9000)).write({"started_at": False})
        # Zero span, and a span that runs backwards.
        self._sit(self.paper, 0)
        self._sit(self.paper, -300)
        self.assertEqual(
            pace.median_seconds(self.paper), 120,
            "only the one sitting with both ends and a positive span counts")

    def test_another_papers_sittings_do_not_count(self):
        mine = self._sit(self.paper, 120)
        self._sit(self._paper(), 9999)
        self.assertEqual(self._detail(mine)["test_median_seconds"], 120)

    # -- the pace tag ---------------------------------------------------------

    def test_pace_at_the_edges(self):
        for taken, expected in ((75, "Fast"), (76, "Normal"),
                                (124, "Normal"), (125, "Slow"),
                                (10, "Fast"), (300, "Slow")):
            with self.subTest(taken=taken):
                self.assertEqual(pace.pace(taken, 100), expected)

    def test_the_ratio_is_rounded_half_up_before_the_cut_offs(self):
        """Ties: 0.745 -> 0.75 (Fast), 0.755 -> 0.76 (Normal), 1.245 -> 1.25
        (Slow). Round-half-to-even over a float lands 0.745 on 0.74."""
        for taken, expected in ((149, "Fast"), (151, "Normal"),
                                (248, "Normal"), (249, "Slow")):
            with self.subTest(taken=taken):
                self.assertEqual(pace.pace(taken, 200), expected)

    def test_no_time_or_no_median_is_no_pace(self):
        self.assertEqual(pace.pace(None, 100), "")
        self.assertEqual(pace.pace(100, None), "")
        self.assertEqual(pace.pace(None, None), "")

    def test_the_export_tags_each_row_against_the_papers_median(self):
        """75, 76, 124 and 125 s have a median of (76 + 124 + 1) // 2 = 100."""
        for name, s in (("A", 75), ("B", 76), ("C", 124), ("D", 125)):
            self._sit(self.paper, s, name=name)
        self._sit(self.paper, name="E Unfinished")
        _header, rows = self._csv(self.paper)
        self.assertEqual(
            {n: rows[n]["pace"] for n in "ABCD"},
            {"A": "Fast", "B": "Normal", "C": "Normal", "D": "Slow"})
        # Minutes to one decimal, half up: 75 s = 1.25, 100 s = 1.666...
        self.assertEqual(rows["A"]["time_taken_minutes"], "1.3")
        self.assertEqual(rows["C"]["time_taken_minutes"], "2.1")
        for name in ("A", "B", "C", "D", "E Unfinished"):
            self.assertEqual(rows[name]["test_median_minutes"], "1.7", name)
        unfinished = rows["E Unfinished"]
        self.assertEqual(unfinished["time_taken_minutes"], "")
        self.assertEqual(unfinished["pace"], "")
        self.assertEqual(unfinished["submitted_at"], "")

    def test_submitted_at_is_written_like_started_at(self):
        self._sit(self.paper, 90, name="Timed")
        _header, rows = self._csv(self.paper)
        self.assertEqual(rows["Timed"]["started_at"],
                         fields.Datetime.to_string(START))
        self.assertEqual(
            rows["Timed"]["submitted_at"],
            fields.Datetime.to_string(START + timedelta(seconds=90)))

    def test_the_median_is_computed_once_per_file(self):
        for s in (60, 120, 180):
            self._sit(self.paper, s)
        with patch.object(pace, "median_seconds",
                          wraps=pace.median_seconds) as spy:
            export.results_rows(self.paper)
        self.assertEqual(spy.call_count, 1)

    # -- the deadline cap -----------------------------------------------------

    def test_the_span_stops_at_the_earlier_of_submit_and_deadline(self):
        """`submitted_at` is stamped when a sitting is SETTLED, not when it
        ended, so it can be long after the deadline the sitting ended on."""
        end = START + timedelta(seconds=600)
        late = START + timedelta(seconds=5400)
        cap = START + timedelta(seconds=1800)
        self.assertEqual(pace.span_seconds(START, late, cap), 1800)
        self.assertEqual(pace.span_seconds(START, end, cap), 600)
        self.assertEqual(pace.span_seconds(START, late, None), 5400)
        self.assertEqual(pace.span_seconds(START, late, False), 5400)
        # A deadline that is not after the start leaves no positive span.
        self.assertIsNone(pace.span_seconds(START, late, START))

    def test_a_sitting_settled_after_its_deadline_counts_only_to_the_deadline(
            self):
        """Settled an hour after its 30 minute deadline: it counts 1800 s, in
        the median, in `time_taken_minutes` and in the tag, and the export's
        `submitted_at` cell stays the raw stamp."""
        late = self._sit(self.paper, 1800 + 3600, name="Late")
        self._sit(self.paper, 600, name="Quick")
        # The median is the two middles, so the late one decides it:
        # (600 + 1800 + 1) // 2 = 1200 capped, (600 + 5400 + 1) // 2 = 3000 not.
        self.assertEqual(pace.median_seconds(self.paper), 1200)
        self.assertEqual(self._detail(late)["test_median_seconds"], 1200)
        _header, rows = self._csv(self.paper)
        self.assertEqual(rows["Late"]["time_taken_minutes"], "30.0")
        self.assertEqual(rows["Late"]["test_median_minutes"], "20.0")
        self.assertEqual(
            rows["Late"]["submitted_at"],
            fields.Datetime.to_string(START + timedelta(seconds=5400)),
            "the stamp itself is exported as it was written")
        self.assertEqual(rows["Quick"]["time_taken_minutes"], "10.0")

    def test_a_late_settlement_is_tagged_by_its_capped_span(self):
        """Median 1500 s. Capped, the late sitting is 1800 / 1500 = 1.2 and
        Normal; the raw 5400 / 1500 = 3.6 would tag it Slow for a delay that
        was not the candidate's."""
        self._sit(self.paper, 1500, name="Even One")
        self._sit(self.paper, 1500, name="Even Two")
        self._sit(self.paper, 1800 + 3600, name="Late")
        self.assertEqual(pace.median_seconds(self.paper), 1500)
        _header, rows = self._csv(self.paper)
        self.assertEqual(rows["Late"]["pace"], "Normal")
        self.assertEqual(rows["Late"]["time_taken_minutes"], "30.0")

    def test_a_sitting_with_no_deadline_is_unchanged(self):
        long_one = self._sit(self.paper, 5400, name="No Limit",
                             no_deadline=True)
        self.assertFalse(long_one.deadline_datetime)
        self.assertEqual(pace.median_seconds(self.paper), 5400)
        _header, rows = self._csv(self.paper)
        self.assertEqual(rows["No Limit"]["time_taken_minutes"], "90.0")

    def test_a_sitting_submitted_before_its_deadline_is_unchanged(self):
        early = self._sit(self.paper, 600, name="Early")
        self.assertEqual(
            early.deadline_datetime, START + timedelta(seconds=1800))
        self.assertEqual(pace.median_seconds(self.paper), 600)
        self.assertEqual(self._detail(early)["test_median_seconds"], 600)
        _header, rows = self._csv(self.paper)
        self.assertEqual(rows["Early"]["time_taken_minutes"], "10.0")

    # -- the header -----------------------------------------------------------

    def test_every_column_keeps_its_position(self):
        """Positions, not "last": each later addition is appended after the
        one before it, so the base block, the time block, the roster block and
        the AI block must each stay exactly where they were put."""
        cols = export.RESULTS_COLUMNS
        base = len(OLD_RESULTS_COLUMNS)
        self.assertEqual(cols[:base], OLD_RESULTS_COLUMNS,
                         "every base column keeps its position")
        self.assertEqual(cols[base:base + len(TIME_COLUMNS)], TIME_COLUMNS,
                         "the four time columns keep theirs")
        roster = base + len(TIME_COLUMNS)
        self.assertEqual(cols[roster:roster + len(ROSTER_COLUMNS)],
                         ROSTER_COLUMNS)
        self.assertEqual(cols[roster + len(ROSTER_COLUMNS):], AI_COLUMNS)
        self._sit(self.paper, 60)
        header, _rows = self._csv(self.paper)
        self.assertEqual(header, cols)

    # -- the roster columns ---------------------------------------------------

    def _questions(self, paper, count):
        Question = self.env["assessments.be.question"]
        return Question.concat(*[Question.create({
            "name": "Q %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric",
            "prompt": "Describe",
            "generator_id": paper.generator_id.id,
            "assessment_ids": [(4, paper.id)],
        }) for _ in range(count)])

    def _candidate(self, paper, name, questions, answered=0, invite=None):
        """A candidate whose frozen paper is `questions` and who has answered
        the first `answered` of them."""
        ev = self._sit(paper, name=name)
        ev.write({"question_order": json.dumps(questions.ids)})
        if invite:
            ev.write({"invite_state": invite})
        for question in questions[:answered]:
            self.env["assessments.be.response"].create({
                "assessment_evaluator_id": ev.id,
                "evaluator_id": ev.applicant_id.id,
                "question_id": question.id,
                "assessment_id": paper.id,
                "state": "submitted",
                "justification": "answer",
            })
        return ev

    def test_a_not_started_candidate_is_in_the_file_with_invite_and_no_answers(
            self):
        questions = self._questions(self.paper, 4)
        self._candidate(self.paper, "Invited", questions, invite="sent")
        self._candidate(self.paper, "Never Invited", questions)
        _header, rows = self._csv(self.paper)
        self.assertEqual(
            {k: rows["Invited"][k] for k in ROSTER_COLUMNS},
            {"invite_state": "sent", "answered_count": "0",
             "question_count": "4"})
        self.assertEqual(
            rows["Never Invited"]["invite_state"], "none",
            "the raw value, never an empty cell")
        self.assertEqual(rows["Never Invited"]["answered_count"], "0")
        self.assertEqual(rows["Invited"]["candidate_state"], "pending")

    def test_a_candidate_who_answered_some_shows_their_own_counts(self):
        """`question_count` is THAT candidate's paper: on an independent draw
        two candidates of one assessment sit different numbers of questions."""
        five = self._questions(self.paper, 5)
        self._candidate(self.paper, "Three Of Five", five, answered=3,
                        invite="failed")
        self._candidate(self.paper, "Two Of Two", five[:2], answered=2,
                        invite="queued")
        _header, rows = self._csv(self.paper)
        self.assertEqual(
            {k: rows["Three Of Five"][k] for k in ROSTER_COLUMNS},
            {"invite_state": "failed", "answered_count": "3",
             "question_count": "5"})
        self.assertEqual(
            {k: rows["Two Of Two"][k] for k in ROSTER_COLUMNS},
            {"invite_state": "queued", "answered_count": "2",
             "question_count": "2"})

    def test_a_handed_in_paper_counts_only_its_real_answers(self):
        """Settlement's blank placeholders are not answers: a paper handed in
        with 2 of 4 answered exports 2, not 4."""
        four = self._questions(self.paper, 4)
        ev = self._candidate(self.paper, "Two Then Submit", four, answered=2)
        for question in four[2:]:
            self.env["assessments.be.response"].create({
                "assessment_evaluator_id": ev.id,
                "evaluator_id": ev.applicant_id.id,
                "question_id": question.id,
                "assessment_id": self.paper.id,
                "state": "submitted",
                "auto_submitted": True,
                "justification": "[Submitted with unanswered questions]",
            })
        _header, rows = self._csv(self.paper)
        self.assertEqual(rows["Two Then Submit"]["answered_count"], "2")
        self.assertEqual(rows["Two Then Submit"]["question_count"], "4")

    def _export_queries(self, paper):
        self.env.flush_all()
        self.env.invalidate_all()
        before = self.env.cr.sql_log_count
        rows = export.results_rows(paper)
        return self.env.cr.sql_log_count - before, len(rows)

    def test_the_export_does_not_query_per_row(self):
        """The same statements for one candidate and for five: the roster
        columns are stored fields that ride the row prefetch."""
        one = self._paper()
        self._candidate(one, "Solo", self._questions(one, 3), answered=2,
                        invite="sent")
        five = self._paper()
        questions = self._questions(five, 3)
        for i in range(5):
            self._candidate(five, "Many %d" % i, questions, answered=i % 3,
                            invite="sent")
        queries_one, rows_one = self._export_queries(one)
        queries_five, rows_five = self._export_queries(five)
        self.assertEqual((rows_one, rows_five), (1, 5))
        self.assertEqual(
            queries_one, queries_five,
            "one candidate took %d statements, five took %d: something reads "
            "per row" % (queries_one, queries_five))

    # -- the wire -------------------------------------------------------------

    def test_the_detail_route_sends_the_key_and_a_list_route_does_not(self):
        ev = self._sit(self.paper, 120)
        self.assertEqual(self._detail(ev)["test_median_seconds"], 120)

        for method, path in (("attempt_list", None),
                             ("assessment_candidates",
                              {"assessment_id": self.paper.id})):
            with self.subTest(route=method):
                out = call_route(api_admin, self.controller, method, self.env,
                                 path=path, assessment_id=self.paper.id)
                self.assertEqual(status_of(out), 200, out)
                self.assertTrue(out["data"])
                for row in out["data"]:
                    self.assertNotIn("test_median_seconds", row)
