# -*- coding: utf-8 -*-
"""Archive is a SUSPEND, delete is two steps, and the LLM ledger outlives
both.

WHY THIS FILE EXISTS.

Archiving used to be pure visibility: the row left the list and, in the words
of the route's own docstring, "nothing else moves". It moved money. Three crons
select their work from `assessments.be.evaluator`, which carries no `active`
column of its own - the only `active = fields.Boolean` on this side of the
module is on `assessments.be` - so Odoo's `active_test` could not reach them
and an archived assessment went on being graded by Vertex, went on emailing
invitations and went on auto-submitting people's sittings. An operator filing a
finished cohort away to tidy the list was still paying for it.

The fix is one predicate per cron, and NOT a snapshot. The crons read live
columns (`scoring_requested`, `llm_state`, `invite_state`), so skipping an
archived assessment neither does the work nor destroys it: the queue sits
exactly as it was and an unarchive resumes from it. The untouched rows ARE the
saved state. A snapshot field would be a second copy of the same fact, free to
drift from it, and there would be nothing to compare it against when it did.

WHAT EACH CLASS PINS, and every one of them has a silent failure mode:

  * `TestArchiveSuspendsTheQueueAndUnarchiveResumesIt` - the round trip. A
    cohort mid-scoring must come back scoring the SAME candidates, with every
    `llm_state` and `scoring_requested` byte-identical. The failure mode is an
    archive that settles the queue to `cancelled`: terminal and lossy, so a
    restored cohort quietly comes back short and nothing reports it.
  * `TestTheOtherCronsStopAndResumeToo` - invitations and the exam clock. A
    retired paper that keeps mailing people is visible to the candidates and to
    nobody else.
  * `TestThePiiPurgeDoesNotPause` - the DELIBERATE exception. Retention is a
    legal duty; archiving must never become a way to park personal data past
    the date we promised to erase it. This test exists so the inconsistency is
    not "fixed".
  * `TestArchivingALivePaperNeedsConfirmation` - archiving a live sitting stops
    those clocks, and is almost always the wrong row.
  * `TestDeleteIsTwoStepsAndKeepsTheSpend` - the destructive path, and the one
    requirement that matters most: `assessments.be.llm.usage` rows survive a
    delete so the budget still counts the spend. That works today only because
    `evaluator_id` is `ondelete="set null"` rather than `cascade`; a future
    `cascade` there would start erasing spend history and nothing else in the
    suite would notice.

TransactionCase throughout, matching `test_assessment_archive` and
`test_llm_ledger_and_kill_switch`: what is under test is the domain each cron
searches and the write each route makes, not the transport. The two crons that
commit per item are driven with `cr.commit` patched to a no-op, exactly as
`test_a_silent_no_send_is_never_marked_sent` documents - Odoo replaces `commit`
on the cursor INSTANCE, so the instance is the patch target.
"""
from datetime import datetime, timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..services import evidence, vertex


class _Base(TransactionCase):
    """A cohort whose candidates are queued for subjective grading."""

    def setUp(self):
        super().setUp()
        # erase purges snapshots; keep tests off the bucket
        purge = patch.object(evidence, "purge_evidence")
        purge.start()
        self.addCleanup(purge.stop)
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Question = self.env["assessments.be.question"]
        self.Applicant = self.env["hr.applicant"]
        self.Usage = self.env["assessments.be.llm.usage"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Suspend fixture %s" % uuid4().hex[:6]})
        # Every route under test is Admin-gated; without the group the
        # assertions below would be exercising the gate, not the flow.
        self.env.user.group_ids = [
            (4, self.env.ref(
                "assessments_be_v2.group_assessment_manager").id)]

    # ── fixtures ──────────────────────────────────────────────────────

    def _assessment(self, **vals):
        values = {
            "name": "Suspend %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "duration_minutes": 30,
        }
        values.update(vals)
        return self.Assessment.create(values)

    def _candidate(self, assessment, llm_state="pending", requested=True,
                   state="submitted"):
        """One candidate on the paper, with a subjective answer to grade.

        The response is what makes the row real: `_scoring_shard_evaluators`
        selects on the EVALUATOR's columns, but a candidate with no subjective
        answer is not a cohort this test could ever claim to be scoring.
        """
        applicant = self.Applicant.create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:8],
        })
        ev = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        question = self.Question.create({
            "name": "Q %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric",
            "prompt": "Describe the procedure.",
            "generator_id": self.generator.id,
            "assessment_ids": [(4, assessment.id)],
        })
        self.Response.create({
            "assessment_evaluator_id": ev.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "assessment_id": assessment.id,
            "state": "submitted",
            "justification": "An answer.",
            "llm_state": "pending",
        })
        ev.write({"state": state, "scoring_requested": requested,
                  "llm_state": llm_state})
        return ev

    def _queued(self, assessment):
        """The drainer's own selection, restricted to this paper.

        The route under test is the DOMAIN, so the real selector is called
        rather than a paraphrase of it - a test that rebuilt the domain here
        would keep passing after somebody edited the cron's copy.
        """
        picked = self.Assessment._scoring_shard_evaluators(0, 1, limit=1000)
        return picked.filtered(lambda e: e.assessment_id == assessment)

    @staticmethod
    def _snapshot(evaluators):
        return {ev.id: (ev.llm_state, ev.scoring_requested)
                for ev in evaluators}


@tagged("-at_install", "post_install")
class TestArchiveSuspendsTheQueueAndUnarchiveResumesIt(_Base):
    """THE HEADLINE INVARIANT: a round trip loses nothing."""

    def test_the_fixture_really_is_queued_for_grading(self):
        """GUARD THE GUARD. If the cohort were not selected to begin with,
        every assertion below would pass for the wrong reason - nothing to
        stop, nothing to lose."""
        paper = self._assessment()
        wanted = self.Evaluator.browse()
        for state in ("pending", "partial", "failed"):
            wanted |= self._candidate(paper, llm_state=state)

        self.assertEqual(
            self._queued(paper), wanted,
            "the drainer must select every queued candidate before the "
            "archive")

    def test_archiving_takes_the_whole_cohort_off_the_scoring_cron(self):
        """The money. An archived paper must cost nothing on the next tick."""
        paper = self._assessment()
        for state in ("pending", "partial", "failed"):
            self._candidate(paper, llm_state=state)

        paper.write({"active": False})
        self.Evaluator.invalidate_model()

        self.assertFalse(
            self._queued(paper),
            "the scoring drainer must select NOTHING for an archived "
            "assessment - it was still grading, and still spending")

    def test_a_round_trip_loses_no_llm_state_and_no_scoring_request(self):
        """THE ONE THAT MATTERS. Archive is a suspend, so restoring must give
        back the same queue, candidate for candidate.

        Asserted as a byte-for-byte comparison of `(llm_state,
        scoring_requested)` rather than a count, because the lossy failure -
        settling the queue to `cancelled` - keeps the row count and destroys
        the distinction between a candidate who was `pending` and one who had
        `failed`. A count would not see it.
        """
        paper = self._assessment()
        cohort = self.Evaluator.browse()
        for state in ("pending", "partial", "failed", "scoring"):
            cohort |= self._candidate(paper, llm_state=state)
        # One candidate who was deliberately NOT queued, so the restore cannot
        # pass by simply re-arming everything it finds.
        idle = self._candidate(paper, llm_state="scored", requested=False)
        before = self._snapshot(cohort | idle)

        paper.write({"active": False})
        paper.write({"active": True})
        (cohort | idle).invalidate_recordset()

        self.assertEqual(
            self._snapshot(cohort | idle), before,
            "archive -> unarchive must leave every llm_state and every "
            "scoring_requested exactly as it found them")
        self.assertEqual(
            self._queued(paper), cohort,
            "and the drainer must be scoring the same candidates again")

    def test_archiving_raises_the_cancel_flag_and_restoring_lowers_it(self):
        """The one thing a domain cannot stop: a lane already mid-Vertex-call.

        Archive reuses the existing cooperative handshake rather than growing
        an interrupt of its own - the flag is read back by the grading lane on
        a fresh cursor before its next billable call. It must NOT be cleared in
        the same transaction that raises it; `action_kill_scoring` records the
        bug where doing so let the in-flight lane carry on spending.
        """
        paper = self._assessment()
        self._candidate(paper, llm_state="scoring")

        paper.write({"active": False})
        self.assertTrue(
            paper.scoring_cancel_requested,
            "archiving must raise the cancel flag so an in-flight lane "
            "refuses its next call")
        self.assertTrue(paper.scoring_cancelled_at)

        paper.write({"active": True})
        self.assertFalse(
            paper.scoring_cancel_requested,
            "restoring must lower it, or the paper could never be scored "
            "again - every run would refuse at its first checkpoint")

    def test_an_archive_never_parks_a_candidate_in_cancelled(self):
        """`cancelled` is terminal and lossy, and is the kill's park, not the
        archive's. A row in it cannot be resumed as the `pending` or `failed`
        it actually was."""
        paper = self._assessment()
        for state in ("pending", "partial", "failed", "scoring"):
            self._candidate(paper, llm_state=state)

        paper.write({"active": False})

        self.assertFalse(
            paper.assessment_evaluator_ids.filtered(
                lambda e: e.llm_state == "cancelled"),
            "archiving must not settle anything to 'cancelled' - that is the "
            "kill's park, and it is not reversible")

    def test_the_in_flight_candidate_comes_back_re_queued_not_cancelled(self):
        """The single row the predicate cannot reach.

        A worker holding this candidate finds the flag raised, refuses its next
        call and lands in `_action_llm_score`'s cancel branch. On a KILL that
        branch parks `cancelled`; on an ARCHIVE it must park somewhere the
        drainer picks up again, or the restored cohort silently comes back one
        candidate short.
        """
        paper = self._assessment()
        ev = self._candidate(paper, llm_state="scoring")
        paper.write({"active": False})

        # Drive the lane's own handler: the grading call refuses because the
        # flag is up, which is exactly what `_check_scoring_cancelled` raises.
        with patch("odoo.addons.assessments_be_v2.services.scoring."
                   "score_evaluator",
                   side_effect=vertex.VertexCancelledError("archived")):
            ev._action_llm_score()

        self.assertEqual(
            (ev.llm_state, ev.scoring_requested), ("pending", True),
            "a candidate interrupted mid-call by an ARCHIVE must come back "
            "queued, not parked in the kill's terminal 'cancelled'")

        paper.write({"active": True})
        self.Evaluator.invalidate_model()
        self.assertIn(
            ev, self._queued(paper),
            "and the drainer must pick them up on the first tick after the "
            "restore")

    def test_a_kill_still_parks_in_cancelled_on_a_live_paper(self):
        """The counterweight. Teaching the lane about archives must not make
        the deliberate, terminal kill reversible too."""
        paper = self._assessment()
        ev = self._candidate(paper, llm_state="scoring")
        paper.action_kill_scoring()

        with patch("odoo.addons.assessments_be_v2.services.scoring."
                   "score_evaluator",
                   side_effect=vertex.VertexCancelledError("killed")):
            ev._action_llm_score()

        self.assertEqual(
            (ev.llm_state, ev.scoring_requested), ("cancelled", False),
            "a kill on a live assessment must still be terminal")


@tagged("-at_install", "post_install")
class TestTheOtherCronsStopAndResumeToo(_Base):
    """Invitations and the exam clock stop with the paper, and resume with
    it."""

    def _drain_invites(self, rows):
        # Odoo replaces `commit` on the cursor INSTANCE, so the class is the
        # wrong target - see `test_a_silent_no_send_is_never_marked_sent`.
        with patch.object(self.env.cr, "commit", lambda: None):
            rows._cron_send_pending_invitations(batch=200)
        rows.invalidate_recordset()

    def test_an_archived_paper_does_not_mail_its_candidates(self):
        # Running, so archiving is the only reason left not to send.
        paper = self._assessment(state="in_progress")
        ev = self._candidate(paper, state="pending")
        ev.write({"invite_state": "queued", "invite_error": False})

        paper.write({"active": False})
        # `_deliver_invitation` returns a refusal reason or a falsy "sent".
        # Patched so nothing is actually mailed and the state written is the
        # only thing under test.
        with patch.object(
                type(ev), "_deliver_invitation", lambda self: False):
            self._drain_invites(ev)

        self.assertEqual(
            ev.invite_state, "queued",
            "a retired paper must not mail people - and the invitation must "
            "stay QUEUED, because archiving defers it rather than cancelling "
            "it")

    def test_restoring_the_paper_sends_the_deferred_invitation(self):
        paper = self._assessment(state="in_progress")
        ev = self._candidate(paper, state="pending")
        ev.write({"invite_state": "queued", "invite_error": False})

        paper.write({"active": False})
        paper.write({"active": True})
        with patch.object(
                type(ev), "_deliver_invitation", lambda self: False):
            self._drain_invites(ev)

        self.assertEqual(
            ev.invite_state, "sent",
            "the invitation the archive held back must go out on the first "
            "tick after the restore")

    def _expire(self, evaluators):
        """Run the expiry cron, recording who it would auto-submit.

        `_auto_submit_expired` is patched out: what is under test is the
        DOMAIN - who the cron selects - and settling a real attempt would drag
        in scoring, rollups and the cohort close pass.
        """
        seen = []
        with patch.object(self.env.cr, "commit", lambda: None), \
                patch.object(type(evaluators), "_auto_submit_expired",
                             lambda self, **kw: seen.append(self.id)):
            evaluators._cron_expire_stale_attempts(limit=500)
        return seen

    def _overdue(self, paper):
        ev = self._candidate(paper, state="in_progress")
        # `deadline_datetime` is a stored compute over `started_at` + the
        # paper's duration, so the clock is moved by the start time rather than
        # by writing the deadline directly (which the next recompute wins
        # back).
        ev.started_at = datetime.utcnow() - timedelta(hours=4)
        ev.flush_recordset()
        self.assertTrue(
            ev.deadline_datetime
            and ev.deadline_datetime < datetime.utcnow(),
            "the fixture must really be overdue, or this test measures "
            "nothing")
        return ev

    def test_the_exam_clock_stops_while_the_paper_is_archived(self):
        paper = self._assessment()
        ev = self._overdue(paper)

        paper.write({"active": False})

        self.assertNotIn(
            ev.id, self._expire(ev),
            "an archived paper's overdue attempt must not be auto-submitted - "
            "archiving stops the clock")

    def test_the_backlog_auto_submits_once_the_paper_is_restored(self):
        """DECIDED, and this test is where the decision lives: no deadline
        arithmetic. A paper restored days later hands the cron a backlog of
        long-overdue attempts and they settle normally. Shifting every deadline
        forward by the archived duration was the alternative; it buys a rare
        case a second, drifting source of truth for when a sitting ends - and
        archiving a paper people are sitting already needs an explicit
        confirmation for exactly that reason.
        """
        paper = self._assessment()
        ev = self._overdue(paper)

        paper.write({"active": False})
        paper.write({"active": True})

        self.assertIn(
            ev.id, self._expire(ev),
            "a restored paper's overdue attempts must settle on the next tick")


@tagged("-at_install", "post_install")
class TestThePiiPurgeDoesNotPause(_Base):
    """THE DELIBERATE EXCEPTION. Do not "fix" this into consistency.

    Retention is a legal duty with its own clock. Pausing the purge for an
    archived assessment would make Archive a one-click way to park personal
    data past the date we promised to erase it - the opposite of what a
    storage-limitation control is for. So this cron alone stays blind to
    `active`, and this test is the reason a future reader will not align it
    with the other three.
    """

    def test_an_archived_attempt_is_still_anonymized_on_schedule(self):
        paper = self._assessment()
        ev = self._candidate(paper, llm_state="scored", requested=False)
        ev.write({
            "submitted_at": datetime.utcnow() - timedelta(days=400),
            "pii_anonymized": False,
        })
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.pii_retention_days", "30")

        paper.write({"active": False})
        with patch.object(self.env.cr, "commit", lambda: None):
            ev._cron_purge_expired_pii(limit=500)
        ev.invalidate_recordset()

        self.assertTrue(
            ev.pii_anonymized,
            "the PII retention sweep must NOT skip archived assessments - "
            "archiving may not park personal data past its retention date")


@tagged("-at_install", "post_install")
class TestArchivingALivePaperNeedsConfirmation(_Base):
    """Archiving a live sitting stops those candidates' clocks, and is almost
    always the wrong row: the count in the refusal is what tells the operator
    so."""

    def setUp(self):
        super().setUp()
        self.controller = _write_controller()

    def test_a_live_paper_is_refused_without_confirmation(self):
        paper = self._assessment()
        for _i in range(2):
            self._candidate(paper, state="in_progress")

        answer = _call(self, "assessment_archive", assessment_id=paper.id)

        self.assertFalse(answer.get("ok"))
        self.assertEqual(answer["error"]["code"], "live_attempts")
        self.assertEqual(
            answer["live_attempt_count"], 2,
            "the refusal must SAY how many people are sitting the paper - "
            "that number is what identifies the mistake")
        self.assertIn("2", answer["error"]["message"])
        self.assertTrue(
            paper.active, "a refused archive must not have archived anything")

    def test_the_same_call_succeeds_once_it_is_confirmed(self):
        paper = self._assessment()
        self._candidate(paper, state="in_progress")

        answer = _call(self, "assessment_archive", assessment_id=paper.id,
                       confirm_live_attempts=True)

        self.assertTrue(answer.get("ok"), answer)
        self.assertFalse(paper.active)

    def test_a_paper_nobody_is_sitting_needs_no_confirmation(self):
        paper = self._assessment()
        self._candidate(paper, state="submitted")

        answer = _call(self, "assessment_archive", assessment_id=paper.id)

        self.assertTrue(answer.get("ok"), answer)
        self.assertFalse(paper.active)

    def test_restoring_is_never_gated_on_it(self):
        """The confirmation guards INTERRUPTING an exam. Putting people back in
        one needs no warning, and gating it would be the 404 trap's cousin: a
        paper that could be archived and then not restored."""
        paper = self._assessment()
        self._candidate(paper, state="in_progress")
        paper.write({"active": False})

        answer = _call(self, "assessment_archive", assessment_id=paper.id,
                       archive=False)

        self.assertTrue(answer.get("ok"), answer)
        self.assertTrue(paper.active)


@tagged("-at_install", "post_install")
class TestDeleteIsTwoStepsAndKeepsTheSpend(_Base):
    """The destructive path: archive first, confirm by name, and the ledger
    survives."""

    def setUp(self):
        super().setUp()
        self.controller = _write_controller()

    def _paper_with_spend(self, cost=4.25):
        paper = self._assessment()
        ev = self._candidate(paper, llm_state="scored", requested=False)
        usage = self.Usage.create({
            "operation": "score_subjective",
            "model": "gemini-3-pro",
            "tokens_in": 1000,
            "tokens_out": 200,
            "cost_usd": cost,
            "evaluator_id": ev.id,
        })
        return paper, ev, usage

    @staticmethod
    def _day_start():
        return datetime.utcnow().strftime("%Y-%m-%d 00:00:00")

    def _spent_today(self):
        # The budget gate's OWN reader, so this measures the number that
        # actually enforces the daily cap rather than a lookalike sum.
        return vertex._spend_since(
            self.env, [("create_date", ">=", self._day_start())])

    # ── step one ──────────────────────────────────────────────────────

    def test_an_unconfirmed_delete_archives_and_destroys_nothing(self):
        paper, ev, _usage = self._paper_with_spend()

        answer = _call(self, "assessment_delete", assessment_id=paper.id)

        self.assertFalse(answer.get("ok"))
        self.assertEqual(answer["error"]["code"], "confirm_required")
        self.assertTrue(
            paper.exists(), "an unconfirmed delete must destroy nothing")
        paper.invalidate_recordset()
        self.assertFalse(
            paper.active,
            "but it must ARCHIVE first - an interrupted delete has to leave a "
            "suspended assessment, not a live one the operator believes gone")
        self.assertTrue(ev.exists())

    def test_the_refusal_names_what_would_be_destroyed(self):
        paper, _ev, _usage = self._paper_with_spend()

        answer = _call(self, "assessment_delete", assessment_id=paper.id)

        self.assertEqual(answer["candidate_count"], 1)
        self.assertEqual(answer["response_count"], 1)
        self.assertEqual(answer["llm_usage_kept"], 1)

    def test_a_wrong_name_is_not_a_confirmation(self):
        paper, _ev, _usage = self._paper_with_spend()

        answer = _call(self, "assessment_delete", assessment_id=paper.id,
                       confirm_name="Some Other Paper")

        self.assertFalse(answer.get("ok"))
        self.assertTrue(
            paper.exists(),
            "echoing the wrong name must not destroy an assessment")

    # ── step two ──────────────────────────────────────────────────────

    def test_a_confirmed_delete_destroys_and_reports_what_it_took(self):
        paper, ev, _usage = self._paper_with_spend()
        paper_id, ev_id = paper.id, ev.id

        answer = _call(self, "assessment_delete", assessment_id=paper_id,
                       confirm_name=paper.name)

        self.assertTrue(answer.get("ok"), answer)
        self.assertEqual(answer["data"]["candidate_count"], 1)
        self.assertEqual(answer["data"]["response_count"], 1)
        self.assertFalse(
            self.Assessment.with_context(active_test=False)
            .browse(paper_id).exists())
        self.assertFalse(self.Evaluator.browse(ev_id).exists())

    def test_the_name_match_ignores_case_and_surrounding_space(self):
        """The confirmation is about intent, not about trailing whitespace -
        a pasted name must not be refused for the space that came with it."""
        paper, _ev, _usage = self._paper_with_spend()
        paper_id = paper.id

        answer = _call(self, "assessment_delete", assessment_id=paper_id,
                       confirm_name="  %s  " % paper.name.upper())

        self.assertTrue(answer.get("ok"), answer)
        self.assertFalse(
            self.Assessment.with_context(active_test=False)
            .browse(paper_id).exists())

    # ── the guard still stands ────────────────────────────────────────

    def test_an_ordinary_unlink_is_still_refused(self):
        """The guard is not removed, only taught to recognise ONE confirmed
        intent. Odoo's own Delete action, a script and a cascade all still
        hit the wall - which is the whole reason candidate results have never
        been wiped by accident."""
        from odoo.exceptions import UserError

        paper, _ev, _usage = self._paper_with_spend()

        with self.assertRaises(UserError):
            paper.unlink()
        self.assertTrue(paper.exists())

    def test_the_bypass_needs_the_key_and_not_merely_a_truthy_context(self):
        """A neighbouring context key must not disarm it. The exemption is one
        named key, set in one place, after a name has been echoed back."""
        paper, _ev, _usage = self._paper_with_spend()
        from odoo.exceptions import UserError

        with self.assertRaises(UserError):
            paper.with_context(force_delete=True, confirm=True).unlink()
        self.assertTrue(paper.exists())

    # ── the requirement that matters most ─────────────────────────────

    def test_the_llm_ledger_survives_a_confirmed_delete(self):
        """THE ONE THAT MATTERS. A deleted assessment must not buy back
        headroom under the daily cap.

        This works only because `assessments.be.llm.usage.evaluator_id` is
        `ondelete="set null"` and not `cascade`: the row outlives the cohort
        with a null evaluator, and the budget gate sums the ledger without ever
        filtering on it. Flipping that one keyword to `cascade` would start
        erasing spend history silently, and nothing else in this suite would
        fail - so this test is the only thing standing in front of it.
        """
        paper, _ev, usage = self._paper_with_spend(cost=4.25)
        usage_id = usage.id
        spent_before = self._spent_today()

        answer = _call(self, "assessment_delete", assessment_id=paper.id,
                       confirm_name=paper.name)
        self.assertTrue(answer.get("ok"), answer)

        row = self.Usage.browse(usage_id)
        self.assertTrue(
            row.exists(),
            "the usage ledger must outlive the assessment it was spent on")
        self.assertFalse(
            row.evaluator_id,
            "and it does so with a NULL evaluator - `ondelete=\"set null\"` "
            "is what makes the row survive at all")
        self.assertEqual(row.cost_usd, 4.25)
        self.assertAlmostEqual(
            self._spent_today(), spent_before, places=5,
            msg="the day's LLM spend must be unchanged by a delete - "
                "otherwise destroying an assessment is a way to buy back "
                "headroom under the daily cap")

    def test_the_ondelete_on_the_ledger_is_set_null_not_cascade(self):
        """The same guarantee, stated where a reviewer of a field change will
        see it. The behavioural test above is the proof; this one names the
        keyword so a diff that flips it fails with the reason attached.
        """
        for name in ("evaluator_id", "prompt_id"):
            with self.subTest(field=name):
                self.assertEqual(
                    self.Usage._fields[name].ondelete, "set null",
                    "assessments.be.llm.usage.%s must stay ondelete='set "
                    "null': on 'cascade' a deleted assessment would erase its "
                    "own spend history and the budget would silently gain "
                    "headroom" % name)


class _WizardBase(_Base):
    """The back-office delete, driven through the wizard the cog menu opens."""

    def setUp(self):
        super().setUp()
        self.controller = _write_controller()

    def _wizard(self, paper):
        return self.env["assessments.be.delete.wizard"].with_context(
            active_id=paper.id, active_ids=paper.ids).create({})


@tagged("-at_install", "post_install")
class TestTheOdooDialogNamesALiveSitting(_WizardBase):
    """The back-office dialog has no second round trip to refuse in.

    The API refuses a live paper outright and makes the operator confirm
    interrupting the exam before anything is archived. The wizard is one
    screen with one button, so the same fact has to reach the operator as a
    number on the screen they are already reading. Without it the two UIs
    disagree on the only irreversible control in the module: Flutter stops and
    asks, Odoo destroys a paper people are sitting without a word.
    """

    def test_a_live_sitting_is_counted_on_the_dialog(self):
        paper = self._assessment()
        self._candidate(paper, state="in_progress")
        self._candidate(paper, state="in_progress")
        self._candidate(paper, state="submitted")

        self.assertEqual(
            self._wizard(paper).live_count, 2,
            "the delete dialog must count the candidates mid-sitting: it is "
            "the number that tells an operator they picked the wrong row")

    def test_a_paper_nobody_is_sitting_counts_none(self):
        paper = self._assessment()
        self._candidate(paper, state="submitted")

        self.assertEqual(
            self._wizard(paper).live_count, 0,
            "a finished cohort must not carry a live-sitting warning, or the "
            "warning stops meaning anything on the papers that need it")

    def test_the_count_agrees_with_the_api_refusal(self):
        """Both surfaces read the same state, so they must report the same
        number - a wizard that counted `state != 'submitted'` would warn on
        papers the API lets through, and the operator would learn to click
        past it."""
        paper = self._assessment()
        self._candidate(paper, state="in_progress")
        self._candidate(paper, state="submitted")

        answer = _call(self, "assessment_delete", assessment_id=paper.id,
                       confirm_name=paper.name)

        self.assertEqual(answer["error"]["code"], "live_attempts")
        self.assertEqual(answer["live_attempt_count"],
                         self._wizard(paper).live_count)


@tagged("-at_install", "post_install")
class TestTheDestroyLeavesOnTheList(_WizardBase):
    """Where the operator ends up after the only irreversible button."""

    def test_the_destroy_leaves_on_the_list_and_not_on_the_dead_record(self):
        """The bug this pins was invisible to every earlier test.

        `act_window_close` destroyed the record correctly and then left the
        form mounted on it: the web client reloaded a dead id and said "the
        records with IDs N cannot be found", the breadcrumb still named the
        paper, and the next click raised Missing Record. The delete had
        worked; nothing on screen said so. An RPC assertion on the return
        value is the only place to catch it, because the destroy itself
        succeeds either way.
        """
        paper = self._assessment()
        self._candidate(paper)

        action = self._wizard(paper).action_destroy()

        self.assertFalse(
            paper.exists(), "the record must still be destroyed")
        self.assertEqual(
            action.get("type"), "ir.actions.act_window",
            "the destroy must answer with somewhere to go: "
            "act_window_close leaves the form on a record that is gone")
        self.assertEqual(
            action.get("res_model"), "assessments.be")
        self.assertEqual(
            action.get("target"), "main",
            "target='main' is what replaces the breadcrumb stack - a dialog "
            "or a pushed action would leave the dead form underneath")
        self.assertNotIn(
            "res_id", [k for k, v in action.items() if v],
            "the action must not land back on a specific record")

    def test_a_vanished_record_still_answers_with_the_list(self):
        """Two operators, one paper. The second press must not traceback."""
        paper = self._assessment()
        wizard = self._wizard(paper)
        paper.with_context(
            **{paper.CONFIRMED_DESTROY_CTX: True}).unlink()

        action = wizard.action_destroy()

        self.assertEqual(action.get("type"), "ir.actions.act_window")
        self.assertEqual(action.get("target"), "main")


# ── controller plumbing ───────────────────────────────────────────────
#
# Same shape as `test_an_archived_paper_is_out_of_the_cohort`: the routes are
# called directly with `request` faked, because what is under test is the
# refusal and the write, not the HTTP transport. `fail()` builds its envelope
# through `request.make_json_response`, so the fake has to provide it.

def _write_controller():
    import inspect

    from odoo import http

    from ..controllers.api import write as write_api
    for _name, obj in vars(write_api).items():
        if (inspect.isclass(obj) and issubclass(obj, http.Controller)
                and obj.__module__ == write_api.__name__
                and hasattr(obj, "assessment_archive")):
            return obj()
    raise AssertionError("the write controller was not found")


def _call(case, method, *, assessment_id, **body):
    from ..controllers.api import common as api_common
    from ..controllers.api import write as write_api

    class _Req:
        def __init__(self, env, params):
            self.env = env
            self.params = params

        def make_json_response(self, payload, headers=None, status=200):
            return {"__status": status, **payload}

    fake = _Req(case.env, dict(body, assessment_id=assessment_id))
    with patch.object(write_api, "request", fake), \
            patch.object(api_common, "request", fake):
        return getattr(case.controller, method)(assessment_id)
