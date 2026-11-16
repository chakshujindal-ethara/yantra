# -*- coding: utf-8 -*-
"""A scoring run has to be visible while it runs, and only while it runs.

WHY THIS FILE EXISTS. An admin pressed Score All on a 711-candidate paper and
had no way to tell whether anything was happening. Grading is a cron, so the
only feedback was the "Queued N candidate(s)" toast; the form never changed
again until it was reloaded by hand, and on that cohort that is around half an
hour of guessing. Then they pressed Kill Scoring Process, the chatter answered
"0 candidate(s) were still queued" - and the button was still there, offering
to stop a run that had already stopped.

THE DEFECT WAS ONE FIELD DOING TWO JOBS. Both surfaces gated on
`awaiting_scoring_count`, which counts submitted attempts holding a subjective
answer that is not `scored`. That is WORK REMAINING. It is nonzero for a cohort
nobody has ever queued, for one an earlier kill parked in `cancelled`, and for
one whose grading errored - every case where there is demonstrably nothing to
stop. "A run is in flight" is a different question, and the only honest answer
to it is the drainer's own selection predicate in
`_scoring_shard_evaluators`.

`scoring_phase` is that answer, and `scoring_summary` is the tally beside it.
Nothing here calls Vertex: the phase is derived from stored columns, which is
the whole reason it is cheap enough to poll.
"""
import pathlib
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.sql_db import db_connect
from odoo.tests.common import TransactionCase

from ..constants import ADVISORY_LOCK_AUTOSCORE
from ..controllers.api import serializers as S
from .test_a_running_lane_keeps_what_it_holds import (
    a_lane_holds_its_lease, a_lane_is_running,
)

_MODULE_ROOT = pathlib.Path(__file__).resolve().parent.parent


class _Base(TransactionCase):

    def _drainers(self):
        """The four `_cron_llm_auto_score` records, scoped BY MODEL.

        `etp_assessment_pro` is still installed and its crons call a method of
        the same name, so matching on `code` alone returns nine on a stage
        database rather than four.
        """
        return self.env["ir.cron"].sudo().with_context(
            active_test=False).search([
                ("code", "like", "_cron_llm_auto_score"),
                ("model_id.model", "=", "assessments.be"),
            ])

    def setUp(self):
        super().setUp()
        # PIN THE GRADER HEALTHY, because `scoring_phase` now reads it and a
        # test database's crons have not ticked in a long time. `nextcall`
        # frozen in the past is exactly what 'stalled' is FOR, so inheriting
        # the ambient value made every queued fixture here report 'stalled' and
        # failed three tests that are not about the cron at all. A test that
        # depends on how recently the suite's database ran its scheduler is not
        # testing what it says it is.
        self._drainers().write({
            "active": True,
            "nextcall": fields.Datetime.now() + timedelta(minutes=1),
        })
        # PIN THE SHARD COUNT TOO, for the same reason. The health check judges
        # only the shards that are SUPPOSED to be running, so a database
        # carrying a `scoring_shards` of its own would silently change which of
        # the four crons these fixtures are talking about.
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.scoring_shards", "1")
        # AND PARK THE AMBIENT QUEUE, for the same reason again: an old queued
        # row nobody stored past reads as a stuck lane, which is 'stalled'.
        self.env["assessments.be.evaluator"].search(
            self.env["assessments.be"]._scoring_queue_domain()).write(
                {"scoring_requested": False})
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Phase fixture %s" % uuid4().hex[:6]})
        self.assessment = self.env["assessments.be"].create({
            "name": "Phase %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "duration_minutes": 30,
        })

    def _candidate(self, *, llm_state="pending", requested=False,
                   answer_scored=False, submitted=True):
        """One attempt carrying one subjective answer, in a named state.

        `answer_scored` drives the RESPONSE row, which is what
        `awaiting_scoring_count` reads; `llm_state`/`requested` drive the
        ATTEMPT, which is what the drainer reads. Keeping both settable is the
        point of the fixture: the bug lived exactly in the gap between them.
        """
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:8],
        })
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": applicant.id,
        })
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric",
            "prompt": "Describe",
            "generator_id": self.generator.id,
            "assessment_ids": [(4, self.assessment.id)],
        })
        self.env["assessments.be.response"].create({
            "assessment_evaluator_id": ev.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "assessment_id": self.assessment.id,
            "state": "submitted",
            "justification": "an answer",
            "llm_raw_100": 80.0 if answer_scored else 0.0,
            "llm_state": "scored" if answer_scored else "pending",
        })
        ev.write({
            "state": "submitted" if submitted else "pending",
            "scoring_requested": requested,
            "llm_state": llm_state,
        })
        self.assessment.invalidate_recordset()
        return ev


class TestThePhaseIsTheRunAndNotTheBacklog(_Base):
    """The four cases where the old gate was wrong, named one by one."""

    def test_a_cohort_nobody_queued_is_idle_however_much_work_is_left(self):
        """THE BUG, in its simplest form.

        Every attempt here is submitted with an ungraded subjective answer, so
        `awaiting_scoring_count` is 2 and the old condition
        (`awaiting_scoring_count == 0`) showed Kill Scoring Process. No one has
        pressed Score All, so there is no run and nothing to kill.
        """
        self._candidate()
        self._candidate()

        self.assertEqual(
            self.assessment.awaiting_scoring_count, 2,
            "fixture guard: the backlog really is nonzero, which is what made "
            "the old gate fire")
        self.assertEqual(
            self.assessment.scoring_phase, "idle",
            "work waiting to be graded is not a run in flight; the Kill "
            "button must not offer to stop a run nobody started")

    def test_a_queued_run_is_queued(self):
        self._candidate(llm_state="pending", requested=True)

        self.assertEqual(self.assessment.scoring_phase, "queued")

    def test_a_candidate_on_the_wire_is_scoring(self):
        """`scoring` outranks `queued`: it is the state the drainer writes
        immediately before the Vertex call, so it is the one moment money is
        genuinely in flight."""
        self._candidate(llm_state="pending", requested=True)
        self._candidate(llm_state="scoring", requested=True)

        self.assertEqual(self.assessment.scoring_phase, "scoring")

    def test_a_kill_mid_call_reads_as_stopping(self):
        """The kill leaves its flag raised while a lane is mid-call, on
        purpose (`action_kill_scoring`). The operator should be able to see
        that, rather than reading a still-live run as 'Scoring'."""
        self._candidate(llm_state="scoring", requested=True)

        with a_lane_is_running(self.env):
            self.assessment.action_kill_scoring()

        self.assertTrue(
            self.assessment.scoring_cancel_requested,
            "fixture guard: a lane in flight keeps the flag up")
        self.assertEqual(self.assessment.scoring_phase, "stopping")

    def test_a_kill_whose_lane_has_parked_itself_settles_to_idle(self):
        """A STATE WITH NO EXIT IS THE BUG, not a detail of it.

        `action_kill_scoring` leaves the flag raised on purpose while a lane is
        mid-call, and the lane that consumes the kill parks ITSELF - that is
        verbatim what `_action_llm_score`'s VertexCancelledError branch writes.
        The drainer does not lower the flag afterwards: it only revisits rows
        with `scoring_requested`, and that row no longer has it, so the in-loop
        `_settle_scoring_cancelled` checkpoint is never reached. Only the end
        of a lane's tick (`_clear_finished_scoring_kills`) lowers it, later.

        Read off the raised flag alone the phase would say 'stopping' with
        nothing running and nothing queued - keeping the Kill button on screen
        offering to stop a run that had already stopped (pressing it answers
        "No candidate was being graded"), and the header badge polling
        `orm.read` for a change no tick of this paper would bring. So the
        phase has to be a total function of what is actually in flight.
        """
        ev = self._candidate(llm_state="scoring", requested=True)
        with a_lane_is_running(self.env):
            self.assessment.action_kill_scoring()
        self.assertEqual(
            self.assessment.scoring_phase, "stopping",
            "fixture guard: while the lane is genuinely mid-call there IS "
            "something left to stop")

        ev.write({"llm_state": "cancelled", "scoring_requested": False})
        self.assessment.invalidate_recordset()

        self.assertTrue(
            self.assessment.scoring_cancel_requested,
            "fixture guard: the lane parking itself does not lower the flag, "
            "and no tick is coming that would")
        self.assertEqual(
            self.assessment.scoring_phase, "idle",
            "a kill with nothing running and nothing queued has stopped; "
            "reporting 'stopping' for ever keeps the Kill button on screen "
            "and the 3s poll running until the tab is closed")

    def test_after_a_kill_has_drained_there_is_nothing_left_to_stop(self):
        """THE REPORTED SEQUENCE. Kill parks the queue, the chatter says "0
        candidate(s) were still queued" on the next press, and the button was
        still on screen offering a third. `awaiting_scoring_count` is still 1
        here, because a `cancelled` candidate's answer is still not `scored` -
        which is precisely why it was the wrong thing to gate on."""
        self._candidate(llm_state="pending", requested=True)

        self.assessment.action_kill_scoring()
        self.assessment.invalidate_recordset()

        self.assertEqual(
            self.assessment.awaiting_scoring_count, 1,
            "fixture guard: the backlog survives a kill, so the old gate "
            "stayed true forever")
        self.assertEqual(
            self.assessment.scoring_phase, "idle",
            "a drained kill leaves nothing to stop, and the button must go")

    def test_an_unsubmitted_candidate_is_not_a_run(self):
        """The drainer only ever selects `state = 'submitted'`, so neither
        does the phase."""
        self._candidate(llm_state="pending", requested=True, submitted=False)

        self.assertEqual(self.assessment.scoring_phase, "idle")

    def test_an_archived_cohort_is_idle_however_much_is_parked_in_it(self):
        """ARCHIVE IS A SUSPEND, AND IT MUST NOT READ AS A RUN.

        `_suspend_scoring_for_archive` raises `scoring_cancel_requested` and
        leaves it raised for as long as the paper is filed away. Read naively
        that is 'stopping' forever, and the header badge polls while the phase
        is busy - a timer that never settles on a cohort nobody is grading.
        The drainer's own domain opens with `assessment_id.active = True`, so
        the honest answer is that an archived paper has no run.
        """
        self._candidate(llm_state="pending", requested=True)
        self.assessment.action_archive()
        self.assessment.invalidate_recordset()

        self.assertTrue(
            self.assessment.scoring_cancel_requested,
            "fixture guard: archiving raises the same flag a kill does")
        self.assertEqual(self.assessment.scoring_phase, "idle")
        self.assertIn(
            "1 queued", self.assessment.scoring_summary,
            "the tally still reports what is parked, so filing a cohort away "
            "does not hide what is waiting in it")

    def test_a_fully_scored_cohort_is_idle(self):
        self._candidate(llm_state="scored", answer_scored=True)

        self.assertEqual(self.assessment.scoring_phase, "idle")
        self.assertEqual(self.assessment.awaiting_scoring_count, 0)


class TestAQueueNobodyIsDrainingSaysSo(_Base):
    """THE SIX-HOUR BLACKOUT, pinned.

    On 2026-09-03 all four `_cron_llm_auto_score` records sat `active=False`
    with `nextcall` frozen six hours in the past. 1,948 answers were queued and
    6 were scored. Both admin buttons are queue-only by design, so both
    correctly answered "queued", and nothing anywhere reported that the thing
    which drains the queue was dead - a growing queue is indistinguishable from
    a busy one. The console eventually grew a banner off `/api/v1/scoring`; the
    Odoo header had nothing, because the verdict was computed inside the route
    and no other caller could reach it.
    """

    def test_a_queue_with_dead_crons_is_stalled_not_queued(self):
        self._candidate(llm_state="pending", requested=True)
        self.assertEqual(
            self.assessment.scoring_phase, "queued",
            "fixture guard: with live crons this is an ordinary queue")

        self._drainers().write({"active": False})
        self.assessment.invalidate_recordset()

        self.assertEqual(self.assessment.scoring_phase, "stalled")

    def test_an_overdue_cron_is_stalled_even_while_active(self):
        """`nextcall` is the authoritative signal: Odoo advances it every tick,
        so a value in the past means the record is not running whatever its
        `active` column claims."""
        self._candidate(llm_state="pending", requested=True)

        self._drainers().write({
            "active": True,
            "nextcall": fields.Datetime.now() - timedelta(hours=6),
        })
        self.assessment.invalidate_recordset()

        self.assertEqual(self.assessment.scoring_phase, "stalled")

    def test_a_candidate_on_the_wire_outranks_a_dead_cron(self):
        """A row in `scoring` is proof a worker picked it up, so the drainer
        cannot be dead. Reporting 'stalled' over live work would send an
        operator to re-enable a cron that is already running."""
        self._candidate(llm_state="scoring", requested=True)
        self._candidate(llm_state="pending", requested=True)

        self._drainers().write({"active": False})
        self.assessment.invalidate_recordset()

        self.assertEqual(self.assessment.scoring_phase, "scoring")

    def test_an_empty_queue_is_idle_however_dead_the_cron_is(self):
        """No work waiting means nothing is being starved, so there is nothing
        to warn about. A blanket cron-health badge on every assessment would be
        noise on the papers it cannot affect."""
        self._candidate(llm_state="scored", answer_scored=True)

        self._drainers().write({"active": False})
        self.assessment.invalidate_recordset()

        self.assertEqual(self.assessment.scoring_phase, "idle")

    def test_the_route_and_the_field_share_one_verdict(self):
        """`scoring_pipeline` used to decide this inline. Both now resolve it
        through `_scoring_drainer_health`, which is the only thing stopping the
        console banner and the Odoo alert from disagreeing."""
        self._candidate(llm_state="pending", requested=True)
        self._drainers().write({"active": False})
        self.assessment.invalidate_recordset()

        health = self.env["assessments.be"]._scoring_drainer_health()

        self.assertTrue(health["blocked"])
        self.assertEqual(
            health["total"], 1,
            "at the default one shard, shard 0 is the only drainer that is "
            "supposed to be running - so it is the only one the verdict and "
            "the sentence built from it may count")
        self.assertEqual(health["inactive"], health["total"])
        self.assertEqual(self.assessment.scoring_phase, "stalled")

    def test_an_inactive_higher_shard_is_not_evidence_of_anything(self):
        """THE OPPOSITE LIE, and the one that sends an operator to re-enable a
        cron that is already running.

        Shards 1-3 ship active but return at their first line until
        `scoring_shards` is raised, so a one-shard installation switches them
        off - and `migrations/19.0.3.15.0` says in as many words that an
        upgrade leaves them off, because that is a legitimate installed state.
        Counting every `_cron_llm_auto_score` record flat made ONE disabled
        higher shard enough to declare the grader dead at the shipped default.
        `stalled` is terminal to the header badge, so the form would then stop
        polling a run that shard 0 is draining perfectly normally.

        `nextcall` is dragged into the past as well, because Odoo never
        advances it on a disabled cron - so a shard switched off an hour ago is
        frozen there and trips the overdue term on its own. Both halves of the
        verdict have to be scoped, not just the inactive count.
        """
        self._candidate(llm_state="pending", requested=True)
        higher = self._drainers().filtered(
            lambda c: "shard=0" not in (c.code or "").replace(" ", ""))
        self.assertEqual(len(higher), 3, "fixture guard: three higher shards")

        higher.write({
            "active": False,
            "nextcall": fields.Datetime.now() - timedelta(hours=6),
        })
        self.assessment.invalidate_recordset()

        health = self.env["assessments.be"]._scoring_drainer_health()
        self.assertFalse(
            health["blocked"],
            "shard 0 is active and on time, so the queue is being drained")
        self.assertEqual(health["total"], 1)
        self.assertEqual(health["inactive"], 0)
        self.assertEqual(health["overdue"], 0)
        self.assertEqual(self.assessment.scoring_phase, "queued")

    def test_a_shard_that_is_supposed_to_run_and_is_off_is_still_stalled(self):
        """The scoping must not become an excuse. A shard inside
        `scoring_shards` owns a disjoint slice of the queue (id %% N == shard),
        so switching it off starves that slice permanently however healthy the
        others look."""
        self._candidate(llm_state="pending", requested=True)
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.scoring_shards", "4")
        shard_2 = self._drainers().filtered(
            lambda c: "shard=2" in (c.code or "").replace(" ", ""))
        self.assertEqual(len(shard_2), 1, "fixture guard")

        shard_2.write({"active": False})
        self.assessment.invalidate_recordset()

        self.assertEqual(self.assessment.scoring_phase, "stalled")


class TestTheSummaryTalliesTheRun(_Base):
    """The string beside the badge, which is the "how far along" half of the
    report. Ordering follows `invite_summary`: what is still to happen, then
    what happened, then what went wrong."""

    def test_it_counts_each_lane_separately(self):
        self._candidate(llm_state="pending", requested=True)
        self._candidate(llm_state="pending", requested=True)
        self._candidate(llm_state="scoring", requested=True)
        self._candidate(llm_state="scored", answer_scored=True)
        self._candidate(llm_state="error")
        self._candidate(llm_state="cancelled")

        summary = self.assessment.scoring_summary

        self.assertIn("2 queued", summary)
        self.assertIn("1 scoring", summary)
        self.assertIn("1 scored", summary)
        self.assertIn("1 failed", summary)
        self.assertIn("1 stopped", summary)

    def test_an_empty_run_says_nothing_rather_than_a_row_of_zeroes(self):
        self.assertFalse(
            self.assessment.scoring_summary,
            "an assessment with no attempts must render no tally at all, so "
            "the header stays clean")

    def test_a_requeued_failure_is_queued_and_not_also_failed(self):
        """Retry Failed Scoring re-queues a `failed` candidate in place, so it
        is simultaneously "failed so far" and "waiting for another go".
        Reporting both reads as two candidates when there is one, and the
        number the operator actually needs is how many still want a human."""
        self._candidate(llm_state="failed", requested=True)
        self._candidate(llm_state="failed", requested=False)

        summary = self.assessment.scoring_summary

        self.assertIn("1 queued", summary)
        self.assertIn("1 failed", summary)
        self.assertNotIn("2 failed", summary)

    def test_a_candidate_on_the_wire_is_not_counted_twice(self):
        """`scoring` is excluded from the queued tally, so 1 candidate never
        reports as '1 queued  ·  1 scoring'."""
        self._candidate(llm_state="scoring", requested=True)

        summary = self.assessment.scoring_summary

        self.assertIn("1 scoring", summary)
        self.assertNotIn("queued", summary)


class TestEverySurfaceGatesOnTheSameFact(_Base):
    """Three surfaces ask "is it scoring": the Odoo header, the REST
    serializer and the Flutter console. A hand-rolled condition in any one of
    them drifts the moment another is edited, which is how the Odoo button and
    the console button came to disagree in the first place."""

    def test_the_serializer_carries_the_phase_and_the_tally(self):
        self._candidate(llm_state="pending", requested=True)

        row = S.assessment_row(self.assessment)

        self.assertEqual(row["scoring_phase"], "queued")
        self.assertIn("1 queued", row["scoring_summary"])

    def test_the_kill_button_is_gated_on_the_phase_and_not_the_backlog(self):
        """A guard against the view regressing, read from the arch rather than
        asserted about behaviour, because the defect WAS the view's condition
        and no runtime assertion would have caught it."""
        view = self.env.ref("assessments_be_v2.assessments_be_form")
        arch = view.arch

        kill = arch.split('name="action_kill_scoring"', 1)[1].split("/>", 1)[0]

        self.assertIn("scoring_phase", kill)
        self.assertNotIn(
            "awaiting_scoring_count", kill,
            "`awaiting_scoring_count` is the backlog, not the run; gating the "
            "kill on it is the bug this file exists for")


class TestAKillStopsTheWholeTickAndNotJustItsFirstRow(_Base):
    """A KILL THAT KEEPS SPENDING IS NOT A KILL.

    `_cron_llm_auto_score` browses its tick's evaluators once, at the top of
    the loop. The kill checkpoint inside it is asked of the ASSESSMENT, and
    `_settle_scoring_cancelled` lowers `scoring_cancel_requested` as its very
    last act - so every other candidate of that same paper still sitting in the
    already-browsed list walked straight past the guard into
    `_action_llm_score`, which validates only that the attempt was submitted.

    Those rows had been parked `cancelled` a moment earlier by the settle
    itself, and the per-call checkpoint in the Vertex service re-reads the same
    lowered flag - so nothing stopped them either. The operator who pressed Kill
    was billed for the rest of the tick anyway, and got back candidates marked
    'scored' carrying the kill's own "cancelled by an admin" error text.
    """

    def _run_the_tick(self):
        """Drive one shard-0 tick, recording who would have been sent to
        Vertex.

        The cron commits between candidates and a `TransactionCase` forbids a
        real commit - it would release the savepoint the whole test runs in.
        Flushing instead does the half that matters here: the writes the settle
        made are visible to the next iteration, exactly as they are in
        production, they are simply not made durable.
        """
        graded = []
        Evaluator = type(self.env["assessments.be.evaluator"])

        def _record(records):
            graded.extend(records.ids)
            return 0

        with patch.object(self.env.cr, "commit", self.env.flush_all), \
                patch.object(Evaluator, "_action_llm_score", _record):
            self.env["assessments.be"]._cron_llm_auto_score(shard=0)
        return graded

    def test_a_killed_paper_costs_nothing_for_the_rest_of_the_tick(self):
        queued = [self._candidate(llm_state="pending", requested=True)
                  for _ in range(3)]
        ids = {ev.id for ev in queued}
        # The flag raised over a queue the drainer can still see is precisely
        # what the cron's own snapshot meets: the kill is committed by a web
        # worker after this tick browsed its list, or by a lane that refused
        # its call and parked itself without lowering the flag.
        self.assessment.scoring_cancel_requested = True

        graded = self._run_the_tick()

        self.assertFalse(
            ids & set(graded),
            "the kill settled the paper on its first candidate and then "
            "graded - and billed for - every other candidate of the same "
            "paper left in the tick's already-browsed list")
        for ev in queued:
            self.assertEqual(ev.llm_state, "cancelled")
            self.assertFalse(ev.scoring_requested)

    def test_an_unkilled_paper_is_still_drained_in_full(self):
        """The guard reads the ROW, so it must not refuse a row that is simply
        waiting its turn."""
        queued = [self._candidate(llm_state="pending", requested=True)
                  for _ in range(3)]
        ids = {ev.id for ev in queued}

        graded = self._run_the_tick()

        self.assertEqual(
            ids & set(graded), ids,
            "every queued candidate of a live paper must still be graded")


class TestTheBadgeAgreesWithTheAlertUnderIt(_Base):
    """`docs/ETP_PLANS_AND_STRATEGY.md` §3.16: "phase = 'stalled' -> badge goes red
    and STOPS polling". It stopped polling and it stayed grey - the one tone
    the widget uses for work that has settled normally - while the red alert
    two rows below it on the same form said grading had stopped. Asserted
    against the asset source because the defect IS the rendering, and no
    runtime assertion about the model would have caught it.
    """

    WIDGET = "static/src/fields/auto_refresh"

    def test_a_stalled_grader_renders_red_and_not_settled_grey(self):
        js = (_MODULE_ROOT / self.WIDGET / "auto_refresh.js").read_text()
        xml = (_MODULE_ROOT / self.WIDGET / "auto_refresh.xml").read_text()

        parts = js.split("get toneClass()", 1)
        self.assertEqual(
            len(parts), 2,
            "the badge tone is not chosen in one named place, so 'stalled' "
            "cannot be told apart from a run that finished normally")
        tone = parts[1].split("\n    }", 1)[0]

        self.assertIn(
            "stalled", tone,
            "the tone does not distinguish a dead grader from a settled run")
        self.assertIn(
            "text-bg-danger", tone,
            "a stalled grader must read as a failure, the way the list row "
            "and the form alert already do")
        self.assertIn(
            "toneClass", xml,
            "the template still picks its own tone, so the getter above is "
            "decoration")

    def test_stalled_rechecks_every_thirty_seconds_without_reloading(self):
        """The red must not be bought by putting `stalled` back in the busy
        set: the badge re-checks it every 30 s (MAX_POLL_MS) while it reads
        stalled, since it can clear on its own, and reloads the form only when
        the value changes."""
        js = (_MODULE_ROOT / self.WIDGET / "auto_refresh.js").read_text()

        busy = js.split("const DEFAULT_BUSY", 1)[1].split("]", 1)[0]

        self.assertNotIn("stalled", busy)


class TestARunningTickIsNotOverdue(_Base):
    """2026-09-21: one tick grades up to `scoring_tick_limit` candidates in a
    row, ~45s each, and Odoo moves `nextcall` only when the tick ends. Past
    fifteen minutes the banner read "Grading is not running" while 55
    candidates were graded beneath it."""

    def test_a_lane_holding_its_shard_lock_is_reported_running(self):
        shard0 = self._drainers().filtered(
            lambda c: "shard=0" in (c.code or "").replace(" ", ""))
        Assessment = self.env["assessments.be"]
        with db_connect(self.env.cr.dbname).cursor() as lane:
            lane.execute("SELECT pg_try_advisory_lock(%s)",
                         [ADVISORY_LOCK_AUTOSCORE])
            if not lane.fetchone()[0]:
                self.skipTest("a real grading lane holds shard 0 right now")
            self.assertEqual(Assessment._running_cron_ids(shard0), {shard0.id})
            lane.execute("SELECT pg_advisory_unlock(%s)",
                         [ADVISORY_LOCK_AUTOSCORE])
        self.assertEqual(Assessment._running_cron_ids(shard0), set())

    def test_a_lane_holding_its_lease_is_not_overdue(self):
        """Lease mode (`services/locks.py`): a live lease row is the lane's
        heartbeat, as the lock is in advisory mode; a lapsed one is not."""
        self._candidate(llm_state="pending", requested=True)
        shard0 = self._drainers().filtered(
            lambda c: "shard=0" in (c.code or "").replace(" ", ""))
        Assessment = self.env["assessments.be"]
        if Assessment._running_cron_ids(shard0):
            self.skipTest("a real grading lane holds shard 0 right now")
        shard0.write({"nextcall": fields.Datetime.now() - timedelta(minutes=40)})
        with a_lane_holds_its_lease(self.env):
            self.assertEqual(Assessment._running_cron_ids(shard0), {shard0.id})
            health = Assessment._scoring_drainer_health()
            self.assertEqual(health["overdue"], 0)
            self.assertFalse(health["blocked"])
        with a_lane_holds_its_lease(self.env, lapsed=True):
            self.assertEqual(Assessment._running_cron_ids(shard0), set())
            self.assertEqual(Assessment._scoring_drainer_health()["overdue"],
                             1, "a lapsed lease excuses nothing")

    def test_a_lock_silent_far_longer_than_any_tick_is_not_running(self):
        """A lock leaked onto a pooled connection, or held by a hung thread,
        would otherwise read as a running tick for ever and hide a dead
        grader (`ETP_PLANS_AND_STRATEGY.md` §2.5, W3.7)."""
        shard0 = self._drainers().filtered(
            lambda c: "shard=0" in (c.code or "").replace(" ", ""))
        Assessment = self.env["assessments.be"]
        with db_connect(self.env.cr.dbname).cursor() as lane:
            lane.execute("SELECT pg_try_advisory_lock(%s)",
                         [ADVISORY_LOCK_AUTOSCORE])
            if not lane.fetchone()[0]:
                self.skipTest("a real grading lane holds shard 0 right now")
            try:
                self.assertEqual(Assessment._running_cron_ids(shard0),
                                 {shard0.id}, "fixture guard: held and fresh")
                # The session has been silent since its last statement; with
                # no silence allowed at all that already counts as leaked.
                with patch.object(type(Assessment), "LANE_LOCK_SILENCE_LIMIT",
                                  timedelta(0)):
                    self.assertEqual(Assessment._running_cron_ids(shard0),
                                     set())
            finally:
                lane.execute("SELECT pg_advisory_unlock(%s)",
                             [ADVISORY_LOCK_AUTOSCORE])

    def test_the_check_takes_no_lock_a_cron_worker_could_trip_on(self):
        cron = self.env.ref("base.autovacuum_job")
        self.env["assessments.be"]._running_cron_ids(self._drainers() | cron)
        with db_connect(self.env.cr.dbname).cursor() as worker:
            worker.execute("SELECT id FROM ir_cron WHERE id = %s "
                           "FOR NO KEY UPDATE SKIP LOCKED", [cron.id])
            self.assertTrue(worker.fetchall(),
                            "a worker acquiring right after the check must "
                            "find the job free")

    def test_an_overdue_drainer_mid_run_is_not_stalled(self):
        self._candidate(llm_state="pending", requested=True)
        shard0 = self._drainers().filtered(
            lambda c: "shard=0" in (c.code or "").replace(" ", ""))
        shard0.write({"nextcall": fields.Datetime.now() - timedelta(minutes=40)})
        self.assessment.invalidate_recordset()
        self.assertEqual(self.assessment.scoring_phase, "stalled",
                         "fixture guard: overdue and idle is stalled")

        with patch.object(type(self.env["assessments.be"]),
                          "_running_cron_ids", return_value={shard0.id}):
            self.assessment.invalidate_recordset()
            self.assertEqual(self.assessment.scoring_phase, "queued")
            health = self.env["assessments.be"]._scoring_drainer_health()
            self.assertFalse(health["blocked"])
            self.assertEqual(health["overdue"], 0)


class TestAFinishedRunSaysWhenItFinished(_Base):
    """The console prints "Scored 630/630 candidates on Sep 21, 2026 at
    10:04pm" once a run is done: the count of submitted attempts graded, out of
    all submitted, and the latest time one of them finished."""

    def test_counts_and_the_last_finish_time(self):
        first = self._candidate(llm_state="scored", answer_scored=True)
        last = self._candidate(llm_state="scored", answer_scored=True)
        self._candidate(llm_state="pending", requested=False)
        self._candidate(llm_state="scored", submitted=False)
        early = fields.Datetime.now() - timedelta(hours=2)
        late = fields.Datetime.now() - timedelta(minutes=5)
        first.llm_scored_at = early
        last.llm_scored_at = late
        self.assessment.invalidate_recordset()

        self.assertEqual(self.assessment.scoring_phase, "idle")
        self.assertEqual(self.assessment.scoring_scored_count, 2)
        self.assertEqual(self.assessment.scoring_candidate_count, 3,
                         "an attempt that never submitted is not a candidate")
        self.assertEqual(self.assessment.scoring_finished_at, late)
        row = S.assessment_row(self.assessment)
        self.assertEqual((row["scoring_scored"], row["scoring_candidates"]),
                         (2, 3))
        self.assertTrue(row["scoring_finished_at"].endswith("Z"))

    def test_nothing_scored_reports_no_finish_time(self):
        self._candidate(llm_state="pending", requested=True)
        self.assessment.invalidate_recordset()
        self.assertEqual(self.assessment.scoring_scored_count, 0)
        self.assertFalse(self.assessment.scoring_finished_at)


class TestARunInFlightKeepsTheLastFinishedTally(_Base):
    """400 of 650 were graded, an operator presses Score All for the other
    250: the line keeps saying 400/650 at the time the last one finished, and
    moves to the new tally only when that run is over."""

    def test_the_tally_holds_during_the_run_and_moves_when_it_ends(self):
        done = self._candidate(llm_state="scored", answer_scored=True)
        early = fields.Datetime.now() - timedelta(hours=3)
        done.llm_scored_at = early
        rest = self._candidate(llm_state="pending", requested=False)
        self.assessment.invalidate_recordset()
        self.assertEqual(
            (self.assessment.scoring_scored_count,
             self.assessment.scoring_candidate_count,
             self.assessment.scoring_finished_at), (1, 2, early),
            "fixture guard: an idle paper reports its live tally")

        self.assessment.action_llm_score_all()
        self.assessment.invalidate_recordset()
        self.assertEqual(self.assessment.scoring_phase, "queued")
        self.assertEqual(
            (self.assessment.scoring_scored_count,
             self.assessment.scoring_candidate_count,
             self.assessment.scoring_finished_at), (1, 2, early),
            "while the run is live the last finished tally stays")

        late = fields.Datetime.now()
        rest.response_ids.write({"llm_state": "scored", "llm_raw_100": 80.0})
        rest.write({"llm_state": "scored", "scoring_requested": False,
                    "llm_scored_at": late})
        self.assessment.invalidate_recordset()
        self.assertEqual(self.assessment.scoring_phase, "idle")
        self.assertEqual(
            (self.assessment.scoring_scored_count,
             self.assessment.scoring_candidate_count,
             self.assessment.scoring_finished_at), (2, 2, late),
            "once the run is over the line moves to the new tally")

    def test_a_request_during_a_live_run_keeps_the_tally_from_before_it(self):
        done = self._candidate(llm_state="scored", answer_scored=True)
        done.llm_scored_at = fields.Datetime.now() - timedelta(hours=3)
        self._candidate(llm_state="pending", requested=False)
        extra = self._candidate(llm_state="pending", requested=False)
        self.assessment.invalidate_recordset()
        self.assessment.action_llm_score_all()

        # A second request mid-run must not overwrite the saved tally with
        # numbers from the run itself.
        self.assessment.scoring_last_scored = 1
        extra.action_queue_llm_score()
        self.assertEqual(self.assessment.scoring_last_scored, 1)
        self.assertEqual(self.assessment.scoring_last_candidates, 3)
