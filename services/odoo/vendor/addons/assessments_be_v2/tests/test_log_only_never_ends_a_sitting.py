# -*- coding: utf-8 -*-
"""Log only means log only: proctoring may never end THAT sitting.

WHY THIS FILE EXISTS. `violation_action` and `max_violations` answer two
different questions - the action says WHETHER proctoring may end a sitting, the
cap says WHEN - and the decision has to be derived from both together. The
branch in `_record_violation` read "any cap that is set fires, whatever the
action says" for a while, so an assessment saved with "On Violation = Log only"
AND a non-zero limit auto-submitted anyway: the operator chose the one option
whose whole promise is "record it, do not act on it" and a candidate's sitting
was ended under them, mid-paper, with time still on the clock.

The client half of this pairing is already pinned (proctoring_contract_test,
config_tab_violation_policy_test and four more on the Dart side). The SERVER
half had no test at all - and the server is the half that enforces it. A
candidate's browser can be reloaded, throttled or closed; `/exam/<token>/violation`
is what actually writes the counter and calls `_auto_submit_expired`, so a
regression here ends real sittings no matter what the client believes.

WHY IT DRIVES THE ROUTE'S OWN METHOD. Re-implementing the three-line branch in
the test would assert that a copy of the logic behaves like itself: it would
pass with the real code arbitrarily broken. `_record_violation` needs
`request.env.cr` for its atomic UPDATE, so a minimal request stub is bound for
the duration - the code under test is the shipped method, unmodified.

A LIMIT IS STILL MEANINGFUL UNDER LOG ONLY, which is why the count is asserted
to keep rising rather than to stop at the cap: the operator reads the tally
afterwards, and suppressing the count would lose the integrity record that is
the entire point of Log only.

THE OWNER'S RULE (A-074, clarified 2026-09-24): "Log violations captures
violations, lists them but never end the paper. Auto-submit ends the paper upon
breaching number of violations." Final (24 Sep): a reached limit shows the
LABEL `violation_limit_breached` in both modes - decided once on the evaluator
and sent to both consoles - and Auto-submit alone ends the paper there. New
papers start at Log only with a limit of 5.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests import Form
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import candidate as C
from odoo.addons.assessments_be_v2.controllers.api import serializers as S
from odoo.addons.assessments_be_v2.controllers.api import write as W

from ._paging_harness import call_route


@tagged("-at_install", "post_install")
class TestLogOnlyNeverEndsASitting(TransactionCase):

    def setUp(self):
        super().setUp()
        generator = self.env["assessments.be.prompt"].create({"name": "Gen"})
        self.assessment = self.env["assessments.be"].create({
            "name": "Proctoring policy probe",
            "generator_id": generator.id,
            "duration_minutes": 30,
        })
        # Two questions so a settled attempt has something to stamp blanks on;
        # an attempt with no questions can end for reasons unrelated to policy.
        for i in (1, 2):
            self.env["assessments.be.question"].create({
                "name": "Q%d" % i,
                "question_type": "subjective_rubric",
                "prompt": "Describe hazard %d" % i,
                "generator_id": generator.id,
                "assessment_ids": [(4, self.assessment.id)],
            })
        self.applicant = self.env["hr.applicant"].create({
            "partner_name": "Policy Probe Candidate",
            "email_from": "probe_%s@example.com" % uuid4().hex[:8],
        })
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": self.applicant.id,
        })
        self.controller = C.EtpAssessmentApiCandidate()

    # ------------------------------------------------------------------
    # Harness
    # ------------------------------------------------------------------
    def _reopen(self):
        """Put the sitting back mid-exam.

        `is_locked` is cleared explicitly. It is a plain stored Boolean set to
        True when an attempt is settled, and the exam gate reads it BEFORE
        `state` - so an attempt whose state was reset but whose lock was left
        standing still reports itself complete.
        """
        self.evaluator.write({
            "state": "in_progress",
            "is_locked": False,
            "is_violated": False,
            "violation_count": 0,
            "violation_reason": False,
            "violation_datetime": False,
            "auto_submit_reason": False,
            "submitted_at": False,
            "started_at": self.env["assessments.be.evaluator"]._fields[
                "started_at"].convert_to_write(
                    self.env.cr.now(), self.evaluator),
        })
        self.env.cr.flush()

    def _fire(self, action, cap, shots):
        """Report `shots` violations and say when (if ever) the sitting ended.

        Each reason is DISTINCT. `_record_violation` folds a repeat of the same
        reason inside 1.2s into the previous one - correct, because one physical
        tab-switch fires several client events - and a test reusing one string
        would measure the dedup instead of the policy.

        Returns (final_count, ended_after_n_violations_or_None).
        """
        self.assessment.write({
            "violation_action": action, "max_violations": cap})
        self._reopen()
        ended_at = None
        with patch.object(C, "request", self._request()):
            for i in range(shots):
                self.controller._record_violation(
                    self.evaluator, "distinct probe reason %d" % i)
                self.evaluator.invalidate_recordset(
                    ["violation_count", "is_locked", "state"])
                if ended_at is None and (
                        self.evaluator.is_locked
                        or self.evaluator.state == "submitted"):
                    ended_at = i + 1
        return self.evaluator.violation_count, ended_at

    def _request(self):
        """The one attribute `_record_violation` needs off `request`: `env`.

        It runs `cr.execute` for the atomic counter bump rather than a
        read-modify-write, so two beacons arriving microseconds apart cannot
        lose an increment. That is the behaviour under test, so it is kept.
        """
        class _Req:
            env = self.env
        return _Req()

    # ------------------------------------------------------------------
    # The promise
    # ------------------------------------------------------------------
    def test_log_only_never_ends_a_sitting_at_any_cap(self):
        """THE HEADLINE. Not one cap, every cap - including caps far below the
        number of violations fired, which is exactly the pairing that broke."""
        broken = []
        for cap in (0, 1, 2, 3, 5):
            count, ended = self._fire("log_only", cap, 6)
            self.assertEqual(
                count, 6,
                "cap=%s: Log only must keep COUNTING - the tally is the "
                "integrity record the operator reads afterwards" % cap)
            if ended is not None:
                broken.append((cap, ended))
        self.assertFalse(
            broken,
            "Log only promises the exam is never ended automatically, but a "
            "sitting was ended at (cap, violation#): %s" % broken)

    def test_log_only_still_records_the_reason_and_the_flag(self):
        """Log only is not "ignore": the record has to survive for review."""
        self._fire("log_only", 2, 3)
        self.assertTrue(self.evaluator.is_violated)
        self.assertEqual(
            self.evaluator.violation_reason, "distinct probe reason 2",
            "the most recent reason is what the reviewer needs")
        self.assertTrue(self.evaluator.violation_datetime)

    def test_log_only_leaves_no_auto_submit_reason(self):
        """The field an operator reads to answer an appeal. Under Log only
        nothing auto-submitted, so it must be empty rather than say 'violation'.
        """
        self._fire("log_only", 1, 4)
        self.assertFalse(self.evaluator.auto_submit_reason)
        self.assertFalse(self.evaluator.submitted_at)

    # ------------------------------------------------------------------
    # The other half, so the test above cannot pass by doing nothing
    # ------------------------------------------------------------------
    def test_auto_submit_DOES_end_the_sitting_and_the_cap_says_when(self):
        """The negative control.

        Without this, every assertion above would still pass if
        `_record_violation` had been gutted to never end anything - and the
        real defect (a sitting ending when it should not) would be replaced by
        the opposite one (proctoring that never fires) with a green suite.
        """
        for cap, expected in ((1, 1), (2, 2), (3, 3)):
            count, ended = self._fire("auto_submit", cap, 5)
            self.assertEqual(
                ended, expected,
                "auto_submit with cap=%s must end the sitting on violation %s"
                % (cap, expected))

    def test_auto_submit_with_no_cap_ends_on_the_first_violation(self):
        """Cap 0 + auto_submit is the strictest setting and the one the
        candidate gate discloses as "ends as soon as one violation is
        recorded". It is a real configuration, so it is pinned."""
        _count, ended = self._fire("auto_submit", 0, 3)
        self.assertEqual(ended, 1)

    def test_auto_submit_names_proctoring_as_the_cause(self):
        """An ended sitting has to say WHY it ended, or an appeal cannot be
        answered: proctoring ends a paper with time still on the clock, which
        must not be reported as an expiry."""
        self._fire("auto_submit", 1, 1)
        self.assertEqual(self.evaluator.auto_submit_reason, "violation")

    def test_owners_case_log_only_cap_20_never_ends(self):
        """The owner's exact configuration (24 Sep): Log only, cap 20."""
        count, ended = self._fire("log_only", 20, 25)
        self.assertEqual(count, 25)
        self.assertIsNone(ended, "Log only + cap 20 ended the paper")
        self.assertFalse(self.evaluator.auto_submit_reason)

    # ------------------------------------------------------------------
    # The breach label: "the violation limit was reached", either mode
    # ------------------------------------------------------------------
    def _breached(self):
        """The flag, read on the model and off every payload that carries
        it, which must all agree because the model decides it once."""
        self.evaluator.invalidate_recordset()
        flags = {
            "model": self.evaluator.violation_limit_breached,
            "admin_row": S.evaluator_admin_row(self.evaluator)["flags"]
            ["violation_limit_breached"],
            "exam_attempt": S.exam_state_envelope(
                C.GATE_QUESTION, self.evaluator)["attempt"]
            ["violation_limit_breached"],
            "my_assessments": S.attempt(self.evaluator)["proctoring"]
            ["violation_limit_breached"],
        }
        self.assertEqual(len(set(flags.values())), 1, flags)
        return flags["model"]

    def test_log_only_labels_the_breach_and_goes_on(self):
        _count, ended = self._fire("log_only", 3, 2)
        self.assertFalse(self._breached(), "below the limit")
        _count, ended = self._fire("log_only", 3, 3)
        self.assertTrue(self._breached(), "at the limit")
        self.assertIsNone(ended, "a breached Log only paper was ended")
        self._fire("log_only", 0, 4)
        self.assertFalse(self._breached(), "no limit, nothing to breach")

    def test_auto_submit_shows_the_breach_label_at_the_cap(self):
        """Auto-submit ends the paper at the cap and the label says why."""
        _count, ended = self._fire("auto_submit", 2, 1)
        self.assertIsNone(ended)
        self.assertFalse(self._breached(), "below the cap")
        _count, ended = self._fire("auto_submit", 2, 2)
        self.assertEqual(ended, 2)
        self.assertTrue(self._breached(), "auto-submitted at the cap")

    def test_cap_0_labels_auto_submit_on_the_first_violation(self):
        self._fire("auto_submit", 0, 0)
        self.assertFalse(self._breached(), "no violation yet")
        _count, ended = self._fire("auto_submit", 0, 1)
        self.assertEqual(ended, 1)
        self.assertTrue(self._breached(), "cap 0 + Auto-submit: first one")

    def test_cap_0_never_labels_log_only(self):
        count, ended = self._fire("log_only", 0, 6)
        self.assertEqual(count, 6)
        self.assertIsNone(ended)
        self.assertFalse(self._breached(), "cap 0 + Log only has no limit")

    def test_a_new_paper_starts_at_log_only_and_5(self):
        """ORM, API and the Odoo form all start a paper at Log only + 5."""
        self.env.user.group_ids = [(4, self.env.ref(
            "assessments_be_v2.group_assessment_manager").id)]
        self.assertEqual(
            (self.assessment.violation_action, self.assessment.max_violations),
            ("log_only", 5), "ORM create")
        Paper = self.env["assessments.be"]
        for sent in ({}, {"max_violations": None, "violation_action": None},
                     {"max_violations": "", "violation_action": ""}):
            typed = "Cap %s" % uuid4().hex[:6]
            made = call_route(W, W.EtpAssessmentApiWrite(),
                              "assessment_create", self.env,
                              name=typed, **sent)
            paper = Paper.browse(made["data"]["id"])
            self.assertEqual(
                (paper.violation_action, paper.max_violations),
                ("log_only", 5), sent)
            # The defaults loop once reused `name` and saved every paper as
            # "violation_action".
            self.assertEqual(paper.name, typed, sent)
            self.assertEqual(made["data"]["violation_action"], "log_only")
            self.assertEqual(made["data"]["max_violations"], 5, sent)
        form = Form(Paper)
        self.assertEqual((form.violation_action, form.max_violations),
                         ("log_only", 5), "Odoo form")
        form.name = "Form default"
        form.generator_id = self.assessment.generator_id
        paper = form.save()
        self.assertEqual((paper.violation_action, paper.max_violations),
                         ("log_only", 5), "Odoo form, saved")
        made = call_route(W, W.EtpAssessmentApiWrite(), "assessment_create",
                          self.env, name="Explicit", violation_action=
                          "auto_submit")
        self.assertEqual(Paper.browse(made["data"]["id"]).violation_action,
                         "auto_submit", "an explicit action is kept")
        made = call_route(W, W.EtpAssessmentApiWrite(), "assessment_create",
                          self.env, name="Cap zero", max_violations=0)
        self.assertEqual(made["data"]["max_violations"], 0,
                         "an explicit 0 is still the admin's choice")
