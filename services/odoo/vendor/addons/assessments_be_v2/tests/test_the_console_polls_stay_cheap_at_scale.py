# -*- coding: utf-8 -*-
"""W4 - the three reads every open console tab repeats stay cheap.

Measured on one process with a 750-candidate paper (`ETP_PLANS_AND_STRATEGY.md`
§3.15), three costs on the hottest admin paths had nothing to do with what
the screens show:

  * DETAIL sent `candidates` - every attempt, serialised: 904 KB of the 1 MB
    payload - and the app never reads it (it reads `roster`; the roster tab
    pages `/candidates`). Every open tab re-reads detail when a run ends.
  * LIST counted the bank once per row for `questions_available`: an N+1.
  * `/scoring` counted its six lanes and the queue in seven queries, ran the
    errored search when nothing had errored, and asked the grader-health
    check twice - once itself and once inside the paper's phase.

Response shapes are unchanged apart from the dropped key, which is why the
lanes are checked against the old per-lane counts rather than just a number.
"""
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class _Console(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.admin = api_admin.EtpAssessmentApiAdmin()
        self.token = uuid4().hex[:8]

    def _call(self, method, path=None, **params):
        return call_route(api_admin, self.admin, method, self.env,
                          path=path, **params)

    def _queries(self, method, path=None, **params):
        self.env.flush_all()
        self.env.invalidate_all()
        before = self.env.cr.sql_log_count
        response = self._call(method, path=path, **params)
        self.assertEqual(status_of(response), 200, response)
        return self.env.cr.sql_log_count - before

    def _generator(self):
        return self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})

    def _question(self, generator, qtype="subjective_rubric", **extra):
        return self.env["assessments.be.question"].create(dict({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": qtype,
            "prompt": "Answer it.",
            "difficulty": "easy",
            "generator_id": generator.id,
        }, **extra))

    def _assessment(self, generator=None):
        return self.env["assessments.be"].create({
            "name": "Paper %s %s" % (self.token, uuid4().hex[:6]),
            "generator_id": (generator or self._generator()).id,
        })


class TestTheDetailSendsTheRosterNotTheAttempts(_Console):

    def test_detail_carries_no_candidates(self):
        assessment = self._assessment()
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Detail %s" % self.token,
            "email_from": "detail_%s@example.com" % self.token,
        })
        assessment.evaluator_ids = [(4, applicant.id)]
        self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id, "applicant_id": applicant.id})

        data = self._call("assessment_detail",
                          path={"assessment_id": assessment.id})["data"]

        self.assertNotIn(
            "candidates", data,
            "detail still serialises every attempt; the app reads `roster` "
            "and pages `/candidates`, so this is dead weight on every reload")
        self.assertEqual([r["id"] for r in data["roster"]], applicant.ids)


class TestTheListCountsTheBankOnce(_Console):

    def _papers(self, n):
        for _ in range(n):
            generator = self._generator()
            self._question(generator)
            self._assessment(generator)

    def test_questions_available_is_right_per_row(self):
        """Mirrors launch's draw: active, not retired, this generator only."""
        generator = self._generator()
        self._question(generator)
        self._question(generator)
        self._question(generator, retired=True)
        self._question(generator, active=False)
        mine = self._assessment(generator)
        other = self._assessment()
        empty = self.env["assessments.be"].create(
            {"name": "Paper %s none" % self.token})

        rows = {r["id"]: r for r in self._call(
            "assessment_list", search=self.token, limit=200)["data"]}

        self.assertEqual(rows[mine.id]["questions_available"], 2)
        self.assertEqual(rows[other.id]["questions_available"], 0)
        self.assertEqual(rows[empty.id]["questions_available"], 0)

    def test_the_page_costs_the_same_at_two_rows_and_at_ten(self):
        self._papers(2)
        small = self._queries("assessment_list", search=self.token, limit=200)
        self._papers(8)
        big = self._queries("assessment_list", search=self.token, limit=200)
        self.assertEqual(
            big, small,
            "2 rows cost %d queries and 10 rows cost %d - something on the "
            "list row is counted once per assessment" % (small, big))


class TestTheScoringPollAsksEachThingOnce(_Console):

    #: Measured, then given headroom (see the module docstring of
    #: `test_a_sitting_stays_inside_its_write_budget` for why a ceiling and not
    #: an exact figure): 20 queries before W4, 15 after.
    #:
    #: RAISED 17 -> 18 (audit swe-api-models-2, 2026-09-23). The phase now
    #: counts QUEUED RE-SCORES as queued work - without it `/scoring` reported
    #: `queued: 0` while individual re-scores waited, so a dead grading cron
    #: looked healthy. That is one more `_read_group` on the evaluator with a
    #: `response_ids.rescore_request_key` term, which brings its own subquery
    #: on the answers. It cannot fold into the counts beside it: different
    #: domain, different grouping. One grouped query for a fact the console was
    #: previously wrong about is the right trade, and the ceiling still catches
    #: what it was written to catch - a per-row count or a doubled health probe.
    #:
    #: RAISED 18 -> 19 (8 Oct 2026). `_scoring_drainer_health` now asks
    #: `_scoring_lane_counts` whether each lane is MOVING (the shard-2 stall of
    #: 30 Sep ticked on time and stored nothing for 14 minutes). That is one
    #: grouped query per poll, whatever the cohort size. Measured 19 on a fresh
    #: install; a per-row regression on this 8-candidate cohort would add 8.
    CEILING = 19

    def setUp(self):
        super().setUp()
        # A HEALTHY GRADER, pinned: the phase reads it, and a test database's
        # crons have not ticked in a long time.
        self.env["ir.cron"].sudo().with_context(active_test=False).search([
            ("code", "like", "_cron_llm_auto_score"),
            ("model_id.model", "=", "assessments.be"),
        ]).write({"active": True,
                  "nextcall": fields.Datetime.now() + timedelta(minutes=1)})
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.scoring_shards", "1")
        # And no ambient queue: an old one reads as a stuck lane.
        self.env["assessments.be.evaluator"].search(
            self.env["assessments.be"]._scoring_queue_domain()).write(
                {"scoring_requested": False})
        self.generator = self._generator()
        self.assessment = self._assessment(self.generator)
        self.subjective = self._question(self.generator)
        self.objective = self._question(self.generator, qtype="mcq")

    def _candidate(self, llm_state, *, subjective=True, requested=False,
                   state="submitted"):
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:8],
        })
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": applicant.id,
        })
        self.env["assessments.be.response"].create({
            "assessment_evaluator_id": ev.id,
            "evaluator_id": applicant.id,
            "question_id": (self.subjective if subjective
                            else self.objective).id,
            "assessment_id": self.assessment.id,
            "state": "submitted",
            "justification": "an answer" if subjective else False,
        })
        ev.write({"state": state, "llm_state": llm_state,
                  "scoring_requested": requested})
        return ev

    def _old_lanes(self):
        """The seven counts exactly as the route computed them before."""
        Evaluator = self.env["assessments.be.evaluator"]
        domain = [("state", "=", "submitted"),
                  ("assessment_id", "=", self.assessment.id)]
        lanes = {}
        for lane in ("pending", "scoring", "scored", "partial", "failed",
                     "error"):
            lane_domain = domain + [("llm_state", "=", lane)]
            if lane in ("pending", "scoring", "partial", "failed"):
                lane_domain += [("response_ids.needs_llm", "=", True)]
            lanes[lane] = Evaluator.search_count(lane_domain)
        queued = Evaluator.search_count(
            domain + [("scoring_requested", "=", True)])
        return lanes, queued

    def _scoring(self):
        return self._call("scoring_pipeline",
                          assessment_id=self.assessment.id)["data"]

    def _cohort(self, with_error=True):
        self._candidate("pending", requested=True)
        self._candidate("pending", subjective=False)  # objective-only: no lane
        self._candidate("scoring")
        self._candidate("scored")
        self._candidate("scored", subjective=False)
        self._candidate("partial", requested=True)
        self._candidate("failed")
        self._candidate("pending", state="in_progress")  # not submitted
        if with_error:
            self._candidate("error")

    def test_the_lanes_are_what_the_seven_counts_said(self):
        self._cohort()
        lanes, queued = self._old_lanes()
        data = self._scoring()
        self.assertEqual(data["lanes"], lanes)
        self.assertEqual(list(data["lanes"]), list(lanes), "key order moved")
        self.assertEqual(data["queued"], queued)
        self.assertEqual(data["lanes"], {
            "pending": 1, "scoring": 1, "scored": 2, "partial": 1,
            "failed": 1, "error": 1})
        self.assertEqual(data["queued"], 2)
        self.assertEqual(data["needs_manual_requeue"], 1)
        self.assertEqual(len(data["errored"]), 1)

    def test_nothing_errored_means_no_errored_search(self):
        self._cohort(with_error=False)
        Evaluator = type(self.env["assessments.be.evaluator"])
        original = Evaluator.search
        domains = []

        def spy(recs, domain, *args, **kwargs):
            domains.append(list(domain))
            return original(recs, domain, *args, **kwargs)

        with patch.object(Evaluator, "search", spy):
            data = self._scoring()
        self.assertEqual(data["errored"], [])
        self.assertFalse(
            [d for d in domains if ("llm_state", "=", "error") in d],
            "the errored lane is empty and the route still searched it")

    def test_the_grader_health_is_checked_once(self):
        """Queued and nothing running: the phase compute needs the verdict
        too, and must take the one the route already has. Counted at the
        lock probe, the part of the check that reads `pg_locks`."""
        self._candidate("pending", requested=True)
        Assessment = type(self.env["assessments.be"])
        original = Assessment._running_cron_ids
        calls = []

        def counting(recs, crons):
            calls.append(crons)
            return original(recs, crons)

        with patch.object(Assessment, "_running_cron_ids", counting):
            data = self._scoring()
        self.assertEqual(data["phase"], "queued")
        self.assertEqual(len(calls), 1,
                         "the cron health check ran %d times" % len(calls))

    def test_the_poll_stays_under_its_query_ceiling(self):
        self._cohort()
        spent = self._queries("scoring_pipeline",
                              assessment_id=self.assessment.id)
        self.assertLessEqual(
            spent, self.CEILING,
            "/scoring cost %d queries against a ceiling of %d"
            % (spent, self.CEILING))
