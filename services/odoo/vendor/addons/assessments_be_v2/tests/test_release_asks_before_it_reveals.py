# -*- coding: utf-8 -*-
"""pm-ux-admin-2: Release Results asks first, and says how many.

Release is irreversible: nothing in this module un-releases. So the header's
"Release Results" opens a counted dialog - how many are released, and how many
still have written answers with the grader - and the write
(`action_confirm_release`) lives behind it. A static `confirm=` cannot state a
count, so the count is a field rendered inside the button; the console runs
its own sheet and calls the write directly.
"""
from uuid import uuid4

from lxml import etree

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestReleaseAsksBeforeItReveals(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]

    def _applicant(self, name):
        return self.env["hr.applicant"].create({
            "partner_name": name,
            "email_from": "%s_%s@example.com" % (
                name.lower().replace(" ", "_"), uuid4().hex[:8]),
        })

    def _question(self):
        return self.env["assessments.be.question"].create({
            "name": "Written %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Explain your reasoning.",
        })

    def _cohort(self, submitted=3, still_grading=0):
        assessment = self.Assessment.create({"name": "Rel %s" % uuid4().hex[:6]})
        question = self._question()
        for i in range(submitted):
            ev = self.Evaluator.create({
                "assessment_id": assessment.id,
                "applicant_id": self._applicant("Cand %d" % i).id,
                "state": "submitted",
            })
            if i < still_grading:
                self.Response.create({
                    "assessment_id": assessment.id,
                    "assessment_evaluator_id": ev.id,
                    "evaluator_id": ev.applicant_id.id,
                    "question_id": question.id,
                    "state": "submitted",
                    "justification": "some prose",
                    "llm_state": "pending",
                })
        assessment.invalidate_recordset()
        return assessment

    # ── the button asks ────────────────────────────────────────────────────

    def test_the_button_opens_a_dialog_instead_of_releasing(self):
        a = self._cohort(submitted=3)
        action = a.action_release_all_results()
        self.assertEqual(action["type"], "ir.actions.act_window")
        self.assertEqual(action["res_model"], "assessments.be.release.wizard")
        self.assertEqual(action["target"], "new")
        self.assertFalse(
            any(a.assessment_evaluator_ids.mapped("results_released")),
            "pressing the button must not release anything by itself")

    def test_the_dialog_names_how_many_and_how_many_are_still_grading(self):
        a = self._cohort(submitted=4, still_grading=2)
        wizard = self.env["assessments.be.release.wizard"].browse(
            a.action_release_all_results()["res_id"])
        self.assertEqual(wizard.submitted_count, 4)
        self.assertEqual(wizard.releasable_count, 4)
        self.assertEqual(wizard.still_grading_count, 2)
        self.assertIn("Cand 0", wizard.still_grading_names,
                      "the candidates still being graded are NAMED, not "
                      "merely counted")
        self.assertEqual(wizard.release_label, "Release 4 result(s)")

    def test_confirming_the_dialog_is_what_releases(self):
        a = self._cohort(submitted=3)
        wizard = self.env["assessments.be.release.wizard"].browse(
            a.action_release_all_results()["res_id"])
        wizard.action_release()
        self.assertTrue(
            all(a.assessment_evaluator_ids.mapped("results_released")))

    def test_the_count_is_on_the_button_label(self):
        a = self._cohort(submitted=7)
        self.assertEqual(a.release_label, "Release 7 result(s)")
        a.assessment_evaluator_ids.write({"results_released": True})
        a.invalidate_recordset()
        self.assertEqual(a.release_label, "Release Results",
                         "no count to state when there is nothing to release")

    def test_the_header_button_renders_the_counted_label(self):
        """A `string=` cannot carry a number, so the label has to be a field
        rendered inside the button. If the field is dropped, the button goes
        back to having no text at all - which a render test catches and a
        string comparison would not."""
        view = self.env.ref("assessments_be_v2.assessments_be_form")
        arch = etree.fromstring(
            self.env["assessments.be"].get_view(view.id, "form")["arch"])
        button = arch.xpath(
            "//button[@name='action_release_all_results']")[0]
        self.assertTrue(
            button.xpath(".//field[@name='release_label']"),
            "the release button must render the counted label")

    def test_the_release_write_is_still_reachable_for_the_api(self):
        """The console runs its own sheet, so the route must not be sent
        through Odoo's dialog."""
        a = self._cohort(submitted=2)
        a.action_confirm_release()
        self.assertTrue(
            all(a.assessment_evaluator_ids.mapped("results_released")))
