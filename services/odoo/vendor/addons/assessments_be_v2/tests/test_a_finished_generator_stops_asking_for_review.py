# -*- coding: utf-8 -*-
"""pm-ux-admin-12, -8 and -7: three generator and Form Studio screens say
what is true.

* pm-ux-admin-12 - the green "Questions ready. Review them ..." banner is
  gated on the DRAFT count, so it goes once nothing awaits review. The tab
  under it lists only drafts (`draft_question_ids`), and Approve / Deny report
  what they did and what they skipped.
* pm-ux-admin-8 - "New Template" opens with no name. Odoo's `beforeUnload`
  urgent save has no dirty check and does not short-circuit for a NEW record,
  so a pre-filled name ("Untitled task") let leaving the page save a blank,
  active template into every generator's quota picker; a required, empty
  `name` cannot be saved.
* pm-ux-admin-7 - the Form Studio button is "Publish", as in the console: it
  sends nothing to candidates, it mints bank questions, a generator and a
  DRAFT assessment.
"""
from uuid import uuid4

from lxml import etree

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAFinishedGeneratorStopsAskingForReview(TransactionCase):

    def setUp(self):
        super().setUp()
        # The manager group, because `get_view` strips a `groups=` button the
        # reading user cannot press - and the whole point of this file is that
        # one of those buttons exists.
        self.env.user.group_ids |= self.env.ref(
            "assessments_be_v2.group_assessment_manager")
        self.Prompt = self.env["assessments.be.prompt"]
        self.Draft = self.env["assessments.be.prompt.question"]

    def _generator(self):
        return self.Prompt.create({"name": "Gen %s" % uuid4().hex[:6],
                                   "sop_gen_state": "done"})

    def _draft(self, generator, state="draft"):
        return self.Draft.create({
            "prompt_id": generator.id,
            "name": "Draft %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "question_prompt": "Explain your reasoning.",
            "state": state,
        })

    def _arch(self, xmlid, model, view_type="form"):
        view = self.env.ref("assessments_be_v2.%s" % xmlid)
        return etree.fromstring(
            self.env[model].get_view(view.id, view_type)["arch"])

    # ── the banner is about the work that is left ──────────────────────────

    def test_the_review_banner_counts_drafts_not_questions(self):
        gen = self._generator()
        self._draft(gen, state="approved")
        gen.invalidate_recordset()
        self.assertEqual(gen.question_count, 1)
        self.assertEqual(gen.draft_count, 0,
                         "an approved question is not work awaiting review")
        self._draft(gen)
        gen.invalidate_recordset()
        self.assertEqual(gen.draft_count, 1)

    def test_the_banner_is_gated_on_the_draft_count(self):
        arch = self._arch("assessments_be_prompt_form",
                          "assessments.be.prompt")
        banners = arch.xpath("//div[contains(@class, 'alert-success')]"
                             "[contains(@invisible, 'sop_gen_state')]")
        self.assertTrue(banners, "the review banner disappeared entirely")
        self.assertTrue(
            any("draft_count" in (b.get("invisible") or "") for b in banners),
            "the banner still asks for review of work that does not exist")

    # ── the tab lists drafts ───────────────────────────────────────────────

    def test_the_drafts_tab_lists_only_drafts(self):
        arch = self._arch("assessments_be_prompt_form",
                          "assessments.be.prompt")
        page = arch.xpath("//page[@string='Question Drafts']")[0]
        self.assertTrue(
            page.xpath(".//field[@name='draft_question_ids']"),
            "the tab called Drafts listed approved and denied rows too")

    def test_the_drafts_relation_excludes_decided_rows(self):
        gen = self._generator()
        self._draft(gen, state="approved")
        self._draft(gen, state="denied")
        pending = self._draft(gen)
        gen.invalidate_recordset()
        self.assertEqual(gen.draft_question_ids, pending)

    # ── the bulk buttons report ────────────────────────────────────────────

    def test_approving_reports_what_it_did(self):
        gen = self._generator()
        already = self._draft(gen, state="approved")
        result = already.action_approve()
        self.assertIsInstance(result, dict,
                              "the button used to return True and say nothing")
        self.assertEqual(result["tag"], "display_notification")
        self.assertIn("1", result["params"]["message"])
        self.assertEqual(result["params"]["type"], "warning")

    def test_denying_reports_what_it_skipped(self):
        gen = self._generator()
        rows = self._draft(gen) + self._draft(gen, state="approved")
        result = rows.action_deny()
        self.assertEqual(result["params"]["type"], "success")
        self.assertIn("Denied 1", result["params"]["message"])
        self.assertIn("1 were already", result["params"]["message"])

    # ── New Template leaves nothing behind ─────────────────────────────────

    def test_a_new_template_opens_with_no_name(self):
        """`name` is required, so a nameless form cannot be saved by Odoo's
        urgent save - which is what stopped "Untitled task" appearing in
        every generator's picker."""
        gen = self._generator()
        action = gen.action_new_task_template()
        self.assertIn("default_name", action["context"])
        self.assertFalse(action["context"]["default_name"])

    def test_a_drafted_template_still_arrives_named(self):
        """Draft from SOP supplies its own name and must be unaffected."""
        field = self.env["assessments.be.task.template"]._fields["name"]
        self.assertTrue(field.required)
        self.assertEqual(field.default(self.env["assessments.be.task.template"]),
                         "Untitled task")

    # ── Form Studio says what it does ──────────────────────────────────────

    def test_the_studio_button_is_called_publish(self):
        arch = self._arch("etp_studio_form_form", "etp.studio.form")
        button = arch.xpath("//button[@name='action_publish']")[0]
        self.assertEqual(button.get("string"), "Publish")
        confirm = button.get("confirm") or ""
        self.assertIn("Nothing reaches candidates until you launch it", confirm)
        self.assertIn("DRAFT", confirm)

    def test_the_studio_form_states_how_many_questions_it_becomes(self):
        arch = self._arch("etp_studio_form_form", "etp.studio.form")
        self.assertTrue(
            arch.xpath("//field[@name='publish_question_count']"),
            "the console's sheet leads with this number and Odoo's said "
            "nothing about it")

    def test_an_empty_form_publishes_no_questions(self):
        form = self.env["etp.studio.form"].create({
            "client_uid": uuid4().hex,
            "title": "Empty %s" % uuid4().hex[:6],
        })
        self.assertEqual(form.publish_question_count, 0)
