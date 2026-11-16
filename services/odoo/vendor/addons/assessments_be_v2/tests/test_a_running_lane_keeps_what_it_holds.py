# -*- coding: utf-8 -*-
"""A candidate a RUNNING lane is grading belongs to that lane.

From the 2026-09-22 adversarial review of the four-lane grader:

  1. TWO LANES, ONE PAPER, A KILL. Lane B reached the killed paper and settled
     it: it parked the candidate lane A was grading, cleared its re-score keys
     and lowered the flag. A's queued calls then passed the kill check (billed)
     and A's store collided with B's write (paid marks discarded).
  2. A LANE THAT DIED left its candidate in `scoring`. Kill skips `scoring` and
     the settle parked only `scoring_requested` rows, so an individual-only
     re-score sat in `scoring` for ever.
  3. THE ADMIN BUTTONS rewrote a candidate being graded (pending / reset
     answers): the lane's paid result collided and Kill could no longer see it.
  4. A serial-mode token refresh lost to another lane cost the answer an
     attempt.

"Being graded right now" is `scoring` AND the lane that owns the row
(evaluator id % shards) holding its lock - a lane that died leaves `scoring`
behind, and that row is nobody's.
"""
from concurrent.futures import Future
from contextlib import contextmanager
from datetime import timedelta
from unittest import SkipTest
from unittest.mock import patch
from uuid import uuid4

from psycopg2.errors import SerializationFailure

from odoo import SUPERUSER_ID, api
from odoo.sql_db import db_connect
from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger

from ..constants import MAX_SCORING_SHARDS
from ..models.assessment import RescoreRefused, _lane_lock
from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc
from ..services.locks import CRON_LEASE_TTL
from .test_individual_scoring_stays_individual import _Paper


@contextmanager
def a_lane_is_running(env):
    """Hold every scoring lane's lock on a connection of its own, as lanes
    mid-tick do."""
    with db_connect(env.cr.dbname).cursor() as lane:
        try:
            for shard in range(MAX_SCORING_SHARDS):
                lane.execute("SELECT pg_try_advisory_lock(%s)",
                             [_lane_lock(shard)])
                if not lane.fetchone()[0]:
                    raise SkipTest(
                        "a real grading lane holds shard %d" % shard)
            yield
        finally:
            # Session-level: closing gives the connection back to the pool
            # with the locks still held.
            lane.execute("SELECT pg_advisory_unlock_all()")


@contextmanager
def a_lane_holds_its_lease(env, lapsed=False):
    """Every scoring lane's lease row, as lanes mid-tick hold them in lease
    mode (`services/locks.py`), in the test's own transaction. ``lapsed``:
    the leases ran out a minute ago."""
    end = timedelta(minutes=-1 if lapsed else 20)
    env.cr.execute("""
        INSERT INTO assessments_be_cron_lease
               (key, holder, acquired_at, expires_at)
        SELECT k, 'test:lane', now() + %(end)s - %(ttl)s, now() + %(end)s
          FROM unnest(%(keys)s::bigint[]) k
        ON CONFLICT (key) DO UPDATE
           SET holder = EXCLUDED.holder, acquired_at = EXCLUDED.acquired_at,
               expires_at = EXCLUDED.expires_at
    """, {"end": end, "ttl": CRON_LEASE_TTL,
          "keys": [_lane_lock(shard) for shard in range(MAX_SCORING_SHARDS)]})
    try:
        yield
    finally:
        env.cr.execute("DELETE FROM assessments_be_cron_lease "
                       "WHERE holder = 'test:lane'")


@tagged("-at_install", "post_install")
class TestTwoLanesOnOnePaperAndAKill(TransactionCase):
    """Real connections: lane A, the web request pressing Kill, lane B.

    The fixture is committed (another connection cannot see this test's
    uncommitted rows) and removed again in cleanup."""

    def _fixture(self):
        with self.registry.cursor() as cr:
            env = api.Environment(cr, SUPERUSER_ID, {})
            paper = env["assessments.be"].create(
                {"name": "Two lanes %s" % uuid4().hex[:6]})
            question = env["assessments.be.question"].create({
                "name": "Q %s" % uuid4().hex[:4],
                "question_type": "subjective_rubric",
                "prompt": "Describe",
                "assessment_ids": [(4, paper.id)],
            })
            evs = env["assessments.be.evaluator"]
            for i in range(2):
                applicant = env["hr.applicant"].create(
                    {"partner_name": "Cand %s" % uuid4().hex[:6]})
                ev = env["assessments.be.evaluator"].create({
                    "assessment_id": paper.id, "applicant_id": applicant.id})
                env["assessments.be.response"].create({
                    "assessment_evaluator_id": ev.id,
                    "evaluator_id": applicant.id,
                    "question_id": question.id,
                    "assessment_id": paper.id,
                    "state": "submitted",
                    "justification": "an answer %d" % i,
                    "llm_state": "pending",
                })
                ev.write({"state": "submitted", "scoring_requested": True,
                          "llm_state": "pending"})
                evs |= ev
            cr.commit()
            self.addCleanup(self._purge, paper.id, question.id,
                            evs.applicant_id.ids)
            return paper.id, evs.ids

    def _purge(self, paper_id, question_id, applicant_ids):
        with self.registry.cursor() as cr:
            env = api.Environment(cr, SUPERUSER_ID, {})
            paper = env["assessments.be"].browse(paper_id)
            paper.assessment_evaluator_ids.response_ids.unlink()
            paper.assessment_evaluator_ids.unlink()
            paper.with_context(**{
                paper.CONFIRMED_DESTROY_CTX: True}).unlink()
            env["assessments.be.question"].browse(question_id).unlink()
            env["hr.applicant"].browse(applicant_ids).unlink()

    def _read(self, sql, params):
        with self.registry.cursor() as cr:
            cr.execute(sql, params)
            return cr.fetchone()

    def test_the_other_lane_leaves_a_held_candidate_and_the_flag(self):
        Assessment = type(self.env["assessments.be"])
        with patch.object(Assessment, "_scoring_shard_count", lambda self: 2):
            paper_id, (ev_a, ev_b) = self._fixture()
            self.assertNotEqual(ev_a % 2, ev_b % 2,
                                "fixture guard: one candidate per lane")
            with self.registry.cursor() as cr_a:
                cr_a.execute("SELECT pg_try_advisory_lock(%s)",
                             [_lane_lock(ev_a % 2)])
                if not cr_a.fetchone()[0]:
                    self.skipTest("a real grading lane holds that shard")
                try:
                    lane_a = api.Environment(cr_a, SUPERUSER_ID, {})
                    # Lane A plans ev_a and queues its call...
                    lane_a["assessments.be"]._auto_score_begin(
                        lane_a["assessments.be.evaluator"].browse(ev_a),
                        lambda job: Future())
                    # ...and commits (it moves on to its next candidate).
                    cr_a.commit()

                    with self.registry.cursor() as cr_k:
                        api.Environment(cr_k, SUPERUSER_ID, {})[
                            "assessments.be"].browse(
                                paper_id).action_kill_scoring()
                        cr_k.commit()

                    # Lane B reaches its own candidate of the killed paper.
                    with self.registry.cursor() as cr_b:
                        lane_b = api.Environment(cr_b, SUPERUSER_ID, {})
                        lane_b["assessments.be"]._auto_score_eligible(
                            lane_b["assessments.be.evaluator"].browse(ev_b))
                        cr_b.commit()

                    held = self._read(
                        "SELECT llm_state, scoring_requested FROM "
                        "assessments_be_evaluator WHERE id = %s", [ev_a])
                    parked = self._read(
                        "SELECT llm_state FROM assessments_be_evaluator "
                        "WHERE id = %s", [ev_b])[0]
                    raised = self._read(
                        "SELECT scoring_cancel_requested FROM assessments_be "
                        "WHERE id = %s", [paper_id])[0]
                    with self.registry.cursor() as cr_w:
                        with self.assertRaises(
                                vertex_svc.VertexCancelledError,
                                msg="lane A's queued call must still be "
                                    "refused - it went out and was billed"):
                            vertex_svc._check_scoring_cancelled(
                                api.Environment(cr_w, SUPERUSER_ID, {}),
                                {"evaluator_id": ev_a})
                finally:
                    cr_a.execute("SELECT pg_advisory_unlock_all()")
                    cr_a.rollback()

        self.assertEqual(
            held, ("scoring", True),
            "lane B parked the candidate lane A is grading - A's store then "
            "collides with it and the paid marks are thrown away")
        self.assertEqual(parked, "cancelled")
        self.assertTrue(raised, "the flag stays up while lane A holds a row")


@tagged("-at_install", "post_install")
class TestALaneThatDiedLeavesNothingStuck(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def _stuck(self):
        """An individual-only re-score whose lane marked it `scoring` and
        died: `scoring_requested` False, the answer's key still set."""
        ev = self._candidate(1, scored={0: 40})
        self._answers(ev).action_rescore_this_answer()
        ev.llm_state = "scoring"
        return ev

    def test_kill_parks_a_candidate_whose_lane_is_gone(self):
        ev = self._stuck()

        self.paper.action_kill_scoring()

        self.assertEqual(ev.llm_state, "cancelled",
                         "no lane holds it, so nothing ever will")
        self.assertFalse(self._answers(ev).rescore_request_key)
        self.assertEqual(self._answers(ev).llm_raw_100, 40.0)
        self.assertFalse(self.paper.scoring_cancel_requested,
                         "nothing is in flight, so nothing is left to refuse")

    def test_a_lane_settles_a_scoring_row_its_own_dead_tick_left(self):
        """The lane is running again (it holds its lock), but that row is not
        one of its calls: its previous tick left it."""
        ev = self._stuck()
        other = self._candidate(1, requested=True)
        self.paper.scoring_cancel_requested = True

        with a_lane_is_running(self.env), \
                patch.object(self.env.cr, "commit", self.env.flush_all):
            self.env["assessments.be"]._auto_score_eligible(other)

        self.assertEqual(ev.llm_state, "cancelled")
        self.assertFalse(self.paper.scoring_cancel_requested,
                         "the flag must not stay up for a row nobody holds")

    def test_kill_leaves_a_candidate_a_running_lane_holds(self):
        ev = self._stuck()

        with a_lane_is_running(self.env):
            self.paper.action_kill_scoring()

        self.assertEqual(ev.llm_state, "scoring")
        self.assertTrue(self._answers(ev).rescore_request_key,
                        "its lane is grading that answer right now")
        self.assertTrue(self.paper.scoring_cancel_requested)

    def test_kill_leaves_a_candidate_a_lane_holds_by_lease(self):
        """Lease mode: a live lease is the lane's heartbeat, as the lock is."""
        ev = self._stuck()

        with a_lane_holds_its_lease(self.env):
            self.paper.action_kill_scoring()

        self.assertEqual(ev.llm_state, "scoring")
        self.assertTrue(self._answers(ev).rescore_request_key,
                        "its lane is grading that answer right now")
        self.assertTrue(self.paper.scoring_cancel_requested)

    def test_kill_parks_a_candidate_whose_lease_ran_out(self):
        ev = self._stuck()

        with a_lane_holds_its_lease(self.env, lapsed=True):
            self.paper.action_kill_scoring()

        self.assertEqual(ev.llm_state, "cancelled",
                         "a lapsed lease is a lane that is gone")


@tagged("-at_install", "post_install")
class TestATickOutlivesAFailedCheckpoint(_Paper, TransactionCase):
    """The kill checkpoint writes (it settles the paper). It ran outside the
    per-candidate `try`, so a collision there ended the lane's whole tick."""

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.first = self._candidate(1, requested=True)
        self.second = self._candidate(1, requested=True)
        Assessment = type(self.env["assessments.be"])
        original = Assessment._auto_score_eligible
        first = self.first

        def flaky(self_, ev, *args, **kwargs):
            if ev == first:
                raise RuntimeError("the settle's write collided")
            return original(self_, ev, *args, **kwargs)

        self.patches = [
            patch.object(Assessment, "_auto_score_eligible", flaky),
            patch.object(self.env.cr, "commit", self.env.flush_all),
        ]

    @mute_logger("odoo.addons.assessments_be_v2.models.assessment")
    def test_the_serial_lane_grades_the_next_candidate(self):
        _calls, judge = self._judge()
        Assessment = type(self.env["assessments.be"])
        with judge, self.patches[0], self.patches[1], patch.object(
                Assessment, "_scoring_shard_evaluators",
                lambda self_, *a, **k: self.first | self.second):
            self.env["assessments.be"]._cron_llm_auto_score(shard=0)
        self.assertEqual(self.second.llm_state, "scored")

    @mute_logger("odoo.addons.assessments_be_v2.models.assessment")
    def test_the_parallel_lane_grades_the_next_candidate(self):
        _calls, judge = self._judge()
        with judge, self.patches[0], self.patches[1], patch.object(
                scoring_svc, "_grade_on_own_cursor",
                lambda registry, uid, ctx, job:
                scoring_svc._grade_outcome(self.env, job)):
            self.env["assessments.be"]._drain_in_parallel(
                self.first | self.second, workers=2)
        self.assertEqual(self.second.llm_state, "scored")


@tagged("-at_install", "post_install")
class TestTheAdminButtonsLeaveACandidateBeingGraded(_Paper, TransactionCase):
    """Shard 0's lane is running and holds `busy`; `idle` is queued work."""

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.busy = self._candidate(2, errored=(1,), requested=True)
        self.busy.llm_state = "scoring"
        self.idle = self._candidate(1, errored=(0,))
        self.before = self._answers(self.busy).read(
            ["llm_state", "llm_attempts", "rescore_request_key"])

    def _assert_untouched(self):
        self.assertEqual(self.busy.llm_state, "scoring")
        self.assertEqual(
            self._answers(self.busy).read(
                ["llm_state", "llm_attempts", "rescore_request_key"]),
            self.before, "an answer the lane is grading was rewritten")

    def test_score_all(self):
        with a_lane_is_running(self.env):
            result = self.paper.action_llm_score_all()
        self._assert_untouched()
        self.assertTrue(self.idle.scoring_requested)
        self.assertIn("1 candidate(s) being graded right now",
                      result["params"]["message"])

    def test_queue(self):
        with a_lane_is_running(self.env):
            result = (self.busy | self.idle).action_queue_llm_score()
        self._assert_untouched()
        self.assertEqual(self.idle.llm_state, "pending")
        self.assertIn("1 candidate(s) being graded right now",
                      result["params"]["message"])

    def test_reset_failed(self):
        with a_lane_is_running(self.env):
            result = (self.busy | self.idle).action_reset_failed_scoring()
        self._assert_untouched()
        self.assertEqual(self._answers(self.idle).llm_state, "pending")
        self.assertEqual(result["reset"], {"answers": 1, "skipped": 1})

    def test_rescore_without_ids_is_refused_like_chosen_answers(self):
        """DECIDED (apc-4 / swe-api-models-4): the refusal stays and is the
        same either way. This path used to answer ok with `queued: 0`, which
        the app renders as "Nothing to re-score" - an admin reads that as
        "these answers are fine" rather than "come back in a minute"."""
        with a_lane_is_running(self.env), \
                self.assertRaisesRegex(RescoreRefused,
                                       "being graded right now"):
            self.busy.action_rescore_individually()
        self._assert_untouched()

    def test_rescore_of_chosen_answers_is_refused(self):
        with a_lane_is_running(self.env), \
                self.assertRaisesRegex(RescoreRefused,
                                       "being graded right now"):
            self.busy.action_rescore_individually(
                self._answers(self.busy).question_id.ids)
        self._assert_untouched()

    def test_a_scoring_row_no_lane_holds_is_queued_as_usual(self):
        self.paper.action_llm_score_all()
        self.assertEqual(self.busy.llm_state, "pending",
                         "its lane is gone: nothing is in flight to protect")


@tagged("-at_install", "post_install")
class TestTwoLanesRefreshingTheTokenAtOnce(TransactionCase):
    """Serial mode mints on a short cursor of its own. Two lanes refreshing at
    once: the loser's write is a serialization failure, which reached the
    answer as a failed call and cost it an attempt."""

    def _bearer(self, *outcomes):
        minted = iter(outcomes)

        def mint(env):
            outcome = next(minted)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome

        with patch.object(vertex_svc, "_side_cursor_is_safe",
                          return_value=True), \
                patch.object(vertex_svc, "_secret_param", return_value=""), \
                patch.object(vertex_svc, "_minted_bearer", mint):
            return vertex_svc._vertex_bearer(self.env)

    def test_the_loser_reads_the_winners_token(self):
        self.assertEqual(
            self._bearer(SerializationFailure("concurrent update"),
                         "fresh-token"),
            "fresh-token")

    def test_losing_twice_is_a_deferral_not_a_failed_call(self):
        with self.assertRaises(vertex_svc.VertexQuotaError):
            self._bearer(SerializationFailure("concurrent update"),
                         SerializationFailure("concurrent update"))
