# -*- coding: utf-8 -*-
"""Flutter-made Form Studio forms, used from Odoo (ETP_PLANS_AND_STRATEGY.md §4.6).

- Forms are read-only in Odoo: Flutter autosaves its whole copy every 0.9 s,
  so an Odoo edit would be silently overwritten.
- "Publish" stays after the first publish; each press is a new draft
  assessment and earlier ones are untouched.
- Publish warnings reach the user instead of vanishing into a context key.
- Archiving an assessment from Odoo is refused while somebody is mid-exam,
  as the API already refuses.
"""
from unittest.mock import patch
from uuid import uuid4

from lxml import etree

from odoo.exceptions import UserError
from odoo.tests.common import tagged

from odoo.addons.assessments_be_v2.tests.test_authored_question_marks import (
    _FormBase,
)


@tagged("-at_install", "post_install")
class TestAStudioFormIsSentFromOdoo(_FormBase):

    def _choice_form(self):
        return self._form(self._item(
            "multipleChoice", title="Pick one",
            options=self._opts(("Yes", True), ("No", False))))

    def _form_arch(self):
        view = self.env.ref("assessments_be_v2.etp_studio_form_form")
        return etree.fromstring(self.Form.get_view(view.id, "form")["arch"])

    # -- read-only in Odoo ------------------------------------------------

    def test_the_form_and_its_item_editor_are_read_only(self):
        arch = self._form_arch()
        self.assertIn(arch.get("edit"), ("0", "false"),
                      "the form view must not offer Edit")
        self.assertIn(arch.get("create"), ("0", "false"))
        editor = arch.xpath(
            "//field[@name='structure_json'][@widget='be_form_item_editor']")
        self.assertTrue(editor)
        self.assertEqual(editor[0].get("readonly"), "1")

    def test_access_rights_are_kept_for_the_flutter_save_route(self):
        """`/forms/save` runs as the user, so read-only is a VIEW decision."""
        manager = self.env.ref("assessments_be_v2.group_assessment_manager")
        self.env.user.group_ids = [(4, manager.id)]
        self.assertTrue(self.Form.has_access("write"))
        self.assertTrue(self.Form.has_access("create"))

    def test_a_form_is_named_by_its_title(self):
        # The breadcrumb after Publish read "etp.studio.form,6667".
        form = self._choice_form()
        form.title = "Onboarding check"
        self.assertEqual(form.display_name, "Onboarding check")

    # -- Publish, again --------------------------------------------------

    def test_send_stays_available_after_the_first_send(self):
        button = self._form_arch().xpath("//button[@name='action_publish']")
        self.assertTrue(button)
        self.assertFalse(button[0].get("invisible"),
                         "Send must not hide once the form is published")

    def test_each_send_makes_a_new_draft_and_leaves_the_last_alone(self):
        form = self._choice_form()
        first = self.env["assessments.be"].browse(
            form.action_publish()["res_id"])
        first.write({"name": "Cohort A", "duration_minutes": 45})
        first_questions = first.question_ids.ids

        second = self.env["assessments.be"].browse(
            form.action_publish()["res_id"])

        self.assertNotEqual(first, second)
        self.assertEqual(second.state, "draft")
        self.assertEqual(first.state, "draft")
        self.assertEqual(first.name, "Cohort A")
        self.assertEqual(first.duration_minutes, 45)
        self.assertEqual(first.question_ids.ids, first_questions)
        self.assertFalse(set(first_questions) & set(second.question_ids.ids),
                         "each send mints its own questions")

    # -- warnings reach the user -----------------------------------------

    def test_publish_warnings_are_shown_then_the_draft_opens(self):
        form = self._form(self._item(
            "imageBlock", title="What is wrong with this weld",
            media_url="https://example.test/weld.png", multi_select=False,
            options=self._opts(("Porosity", True), ("Clean", False))))
        warning = "Section one, item 1: image could not be downloaded"
        with patch.object(type(self.Form), "_fetch_media_b64",
                          lambda self, url: (False, warning)):
            action = form.action_publish()

        self.assertEqual(action["tag"], "display_notification")
        params = action["params"]
        self.assertIn(warning, params["message"])
        self.assertEqual(params["type"], "warning")
        self.assertEqual(params["title"], "Published, with 1 warning(s)")
        self.assertTrue(params["sticky"])
        self.assertEqual(params["next"]["res_model"], "assessments.be")
        self.assertTrue(
            self.env["assessments.be"].browse(params["next"]["res_id"]).exists())

    def test_a_clean_publish_goes_straight_to_the_draft(self):
        action = self._choice_form().action_publish()
        self.assertEqual(action["type"], "ir.actions.act_window")
        self.assertEqual(action["res_model"], "assessments.be")

    # -- archive refused mid-exam ----------------------------------------

    def _live_assessment(self):
        asm = self.env["assessments.be"].create({
            "name": "Live %s" % uuid4().hex[:6], "state": "in_progress"})
        sitting = self.env["assessments.be.evaluator"].create({
            "assessment_id": asm.id,
            "applicant_id": self.env["hr.applicant"].create(
                {"partner_name": "Mid Exam"}).id,
            "state": "in_progress",
        })
        return asm, sitting

    def test_archive_is_refused_while_a_candidate_is_mid_exam(self):
        asm, sitting = self._live_assessment()
        with self.assertRaises(UserError) as caught:
            asm.action_archive()
        self.assertIn("1 candidate(s)", str(caught.exception))
        self.assertTrue(asm.active)

        sitting.state = "submitted"
        asm.action_archive()
        self.assertFalse(asm.active)

    def test_the_apis_confirmed_archive_is_not_blocked(self):
        """The API asks `confirm_live_attempts` and then writes `active`
        directly; the Odoo guard must not take that path away."""
        asm, _sitting = self._live_assessment()
        asm.write({"active": False})
        self.assertFalse(asm.active)
