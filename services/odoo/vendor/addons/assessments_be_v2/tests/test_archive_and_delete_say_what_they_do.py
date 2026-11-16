# -*- coding: utf-8 -*-
"""The three destructive confirmations must describe what actually happens.

Each of these is a sentence or a number an operator reads and then acts on,
and each one was wrong in a different direction.

  1. "ARCHIVING STOPS THEIR CLOCK" WAS FALSE. `deadline_datetime` is
     `started_at + duration_minutes`, an absolute wall-clock instant, and no
     candidate route gates on `active` - so an archived paper is still fully
     sittable and `/api/v1/exam/<token>/answer` still auto-submits every
     candidate at their ORIGINAL deadline. All archiving suspends is
     `_cron_expire_stale_attempts`, the safety net for a closed tab. An
     operator who read the refusal as a pause, confirmed, and restored the
     paper ten minutes later gave nobody any time back.

  2. AN ARCHIVED PAPER'S LIVE SITTINGS WERE INVISIBLE TO THE API. The delete
     route only consults `_live_attempt_refusal` inside `if record.active:`,
     and archiving leaves every candidate in `in_progress` - so on the one
     branch where the refusal never runs, nothing in the 409 or the receipt
     mentioned them. The Odoo wizard has no such gate and reported them, so
     the two surfaces disagreed about the same cohort.

  3. MULTI-SELECT DELETE NARROWED TO ONE ROW, SILENTLY. `default_get` read
     `active_ids` and then overwrote it from `active_id`, which the web
     client's cog menu sets on EVERY invocation - so `len(ids) > 1` was
     unreachable, the author's "one at a time" guard never fired, and ticking
     five papers destroyed the first while the dialog named only that one.

TransactionCase, with the routes driven directly: what is under test is the
refusal text, the counts and the guard, not the transport.
"""
from datetime import datetime, timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import write as write_api
from ..services import evidence
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        # a confirmed delete purges snapshots; keep tests off the bucket
        purge = patch.object(evidence, "purge_evidence")
        purge.start()
        self.addCleanup(purge.stop)
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.controller = write_api.EtpAssessmentApiWrite()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})

    def _assessment(self):
        return self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "duration_minutes": 30,
        })

    def _sitting(self, assessment):
        """One candidate mid-paper, with a real deadline on the clock."""
        applicant = self.env["hr.applicant"].with_context(
            tracking_disable=True, mail_create_nolog=True,
            mail_notrack=True).create({
                "partner_name": "Cand %s" % uuid4().hex[:6],
                "email_from": "cand.%s@example.com" % uuid4().hex[:8],
            })
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        evaluator.write({
            "state": "in_progress",
            "started_at": datetime.now() - timedelta(minutes=5),
        })
        return evaluator

    def _call(self, method, assessment, **body):
        return call_route(
            write_api, self.controller, method, self.env,
            path={"assessment_id": assessment.id}, **body)


@tagged("-at_install", "post_install")
class TestTheArchiveRefusalDescribesArchiving(_Base):

    def test_the_refusal_does_not_claim_to_pause_the_exam(self):
        """The sentence is the entire content of the decision."""
        paper = self._assessment()
        self._sitting(paper)

        response = self._call("assessment_archive", paper)

        self.assertEqual(status_of(response), 409, response)
        self.assertEqual(response["error"]["code"], "live_attempts")
        message = response["error"]["message"]
        self.assertNotIn("stops their clock", message)
        self.assertIn("does not pause", message)
        self.assertIn("1 candidate(s)", message)

    def test_the_refusal_is_true_the_deadline_really_does_not_move(self):
        """The behaviour the sentence now describes. Asserted so the copy
        cannot be "fixed" back by making the claim instead of the change."""
        paper = self._assessment()
        sitting = self._sitting(paper)
        before = sitting.deadline_datetime

        response = self._call(
            "assessment_archive", paper, confirm_live_attempts=True)

        self.assertEqual(status_of(response), 200, response)
        sitting.invalidate_recordset()
        self.assertFalse(paper.with_context(active_test=False).active)
        self.assertEqual(
            sitting.deadline_datetime, before,
            "archiving moved no deadline, which is exactly why the refusal "
            "may not promise that it does")
        self.assertEqual(
            sitting.state, "in_progress",
            "and nobody was frozen, paused or submitted")

    def test_confirming_is_still_what_lets_it_through(self):
        """THE CONTROL: the refusal is still a refusal."""
        paper = self._assessment()
        self._sitting(paper)

        self.assertEqual(
            status_of(self._call("assessment_archive", paper)), 409)

    def test_a_paper_with_nobody_sitting_archives_without_a_question(self):
        paper = self._assessment()

        self.assertEqual(
            status_of(self._call("assessment_archive", paper)), 200)


@tagged("-at_install", "post_install")
class TestTheDeleteReceiptCountsLiveSittingsOnEitherBranch(_Base):

    def test_an_archived_paper_still_reports_its_live_sittings(self):
        """The branch where `_live_attempt_refusal` never runs."""
        paper = self._assessment()
        self._sitting(paper)
        paper.write({"active": False})

        response = self._call("assessment_delete", paper)

        self.assertEqual(status_of(response), 409, response)
        self.assertEqual(response["error"]["code"], "confirm_required")
        self.assertEqual(
            response.get("live_attempt_count"), 1,
            "an archived paper carries live sittings, and this is the one "
            "screen that could have said so")

    def test_the_receipt_reports_it_too(self):
        paper = self._assessment()
        self._sitting(paper)
        paper.write({"active": False})

        response = self._call(
            "assessment_delete", paper, confirm_name=paper.name)

        self.assertEqual(status_of(response), 200, response)
        self.assertEqual(response["data"]["live_attempt_count"], 1)

    def test_the_api_and_the_wizard_agree_about_an_archived_paper(self):
        """The two surfaces are read by the same person about the same
        cohort, so the only acceptable relationship between them is equality."""
        paper = self._assessment()
        self._sitting(paper)
        self._sitting(paper)
        paper.write({"active": False})

        api = self._call("assessment_delete", paper).get("live_attempt_count")
        wizard = self.env["assessments.be.delete.wizard"].with_context(
            active_ids=paper.ids).default_get(["live_count"])["live_count"]

        self.assertEqual((api, wizard), (2, 2))


@tagged("-at_install", "post_install")
class TestTheDeleteWizardRefusesAMultiSelect(_Base):

    def _default_get(self, **context):
        return self.env["assessments.be.delete.wizard"].with_context(
            **context).default_get(
                ["assessment_id", "name", "live_count"])

    def test_two_selected_papers_raise_instead_of_narrowing_to_one(self):
        """The guard the author wrote, now reachable. The cog menu sets BOTH
        keys, which is why `active_id` may not win."""
        first, second = self._assessment(), self._assessment()

        with self.assertRaises(UserError):
            self._default_get(active_ids=[first.id, second.id],
                              active_id=first.id)

    def test_one_selected_paper_still_opens_the_dialog(self):
        """THE CONTROL. A guard that refused the ordinary case would be the
        same defect pointing the other way."""
        paper = self._assessment()

        values = self._default_get(active_ids=[paper.id], active_id=paper.id)

        self.assertEqual(values["assessment_id"], paper.id)
        self.assertEqual(values["name"], paper.name)

    def test_the_form_button_path_still_works(self):
        """Opened from the form view, where there is only an `active_id`."""
        paper = self._assessment()

        values = self._default_get(active_id=paper.id)

        self.assertEqual(values["assessment_id"], paper.id)
