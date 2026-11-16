# -*- coding: utf-8 -*-
"""W9: imports in Odoo sit where the app has them, and imported questions wait
for review.

  * Generators: ONE Import, in the Generators list's gear menu. The
    Configuration menu entry and the list button (which imported QUESTIONS)
    are gone; Odoo's generic "Import records" is hidden there and on Tags.
  * Questions: Import on the Question Bank and Pending Approvals lists, not on
    the generator list or form.
  * Every imported question - CSV too - lands as a DRAFT in Pending Approvals.
    The one exception is a native export, which restores questions already
    approved here straight into the bank.
  * The wizard and the API route turn the same rows into the same drafts, the
    dialogs close on success, and a non-Admin is refused.
"""
import base64
from uuid import uuid4

from lxml import etree

from odoo.exceptions import AccessError
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import write as write_api
from ..models import bank_import_wizard as wizard_module
from ._paging_harness import call_route, status_of

_RESTRICTED = "assessments_be_v2.group_assessment_manager_restricted"

_CSV = (
    "title,question_type,prompt,options,correct_answer,difficulty\n"
    "Capital,mcq,Which city is the capital of France?,Paris|London,Paris,easy\n"
    "Primes,msq,Select every prime.,2|3|4,2|3,medium\n"
)

#: The draft fields an import writes. Compared across the two surfaces.
_DRAFT_FIELDS = ("name", "question_prompt", "question_type", "difficulty",
                 "dimensions_json", "images_json", "rubric_json", "state")


def _b64(text):
    return base64.b64encode(text.encode("utf-8")).decode()


@tagged("-at_install", "post_install")
class TestImportsSitWhereTheAppHasThem(TransactionCase):

    def setUp(self):
        super().setUp()
        # An Assessment Admin, like the people who use these screens.
        self.env.user.group_ids = [
            (4, self.env.ref("assessments_be_v2.group_assessment_manager").id)]

    def _arch(self, xmlid, model, view_type="list", env=None):
        view = self.env.ref("assessments_be_v2.%s" % xmlid)
        arch = (env or self.env)[model].get_view(view.id, view_type)["arch"]
        return etree.fromstring(arch)

    def _restricted_user(self):
        return self.env["res.users"].create({
            "name": "Read-only %s" % uuid4().hex[:6],
            "login": "ro_%s@example.com" % uuid4().hex[:8],
            "group_ids": [(6, 0, [self.env.ref("base.group_user").id,
                                  self.env.ref(_RESTRICTED).id])],
        })

    # ── placement ────────────────────────────────────────────────────────

    def test_the_generator_list_has_no_import_button_and_no_generic_import(self):
        root = self._arch("assessments_be_prompt_tree", "assessments.be.prompt")
        self.assertIsNone(
            root.get("js_class"),
            "the list button imported QUESTIONS; generators import from the "
            "gear menu")
        self.assertEqual(root.get("import"), "0")

    def test_the_generator_import_lives_in_the_gear_menu_only(self):
        self.assertFalse(
            self.env.ref("assessments_be_v2.menu_assessments_be_generator_import",
                         raise_if_not_found=False),
            "the Configuration > Import Generators entry must be gone")
        action = self.env.ref(
            "assessments_be_v2.action_assessments_be_generator_import")
        self.assertEqual(action.res_model,
                         "assessments.be.generator.import.wizard")
        import os
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(os.path.join(here, "static/src/list/prompt_import_list.js"),
                  encoding="utf-8") as fh:
            js = fh.read()
        self.assertIn('registry.category("cogMenu")', js)
        self.assertIn("action_assessments_be_generator_import", js)
        self.assertIn('"assessments.be.prompt"', js)

    def test_questions_import_from_the_bank_and_pending_approvals(self):
        bank = self._arch("assessments_be_question_tree",
                          "assessments.be.question")
        pending = self._arch("assessments_be_prompt_question_tree",
                             "assessments.be.prompt.question")
        for root in (bank, pending):
            self.assertEqual(root.get("js_class"), "be_question_import_list")

        form = etree.tostring(self._arch(
            "assessments_be_prompt_form", "assessments.be.prompt", "form"),
            encoding="unicode")
        wizard_action = self.env.ref(
            "assessments_be_v2.action_assessments_be_bank_import")
        self.assertNotIn('name="%d"' % wizard_action.id, form,
                         "the generator form header still imports questions")

    def test_tags_keep_their_button_and_lose_the_generic_import(self):
        root = self._arch("assessments_be_tag_list", "assessments.be.tag")
        self.assertEqual(root.get("js_class"), "be_tag_import_list")
        self.assertEqual(root.get("import"), "0")

    def test_the_file_pickers_take_the_apps_extensions(self):
        for xmlid, model, exts in (
                ("assessments_be_bank_import_wizard_form",
                 "assessments.be.bank.import.wizard", ".csv,.json"),
                ("assessments_be_tag_import_wizard_form",
                 "assessments.be.tag.import.wizard", ".csv"),
                ("assessments_be_generator_import_wizard_form",
                 "assessments.be.generator.import.wizard", ".csv")):
            arch = etree.tostring(self._arch(xmlid, model, "form"),
                                  encoding="unicode")
            self.assertIn("'accepted_file_extensions': '%s'" % exts, arch,
                          xmlid)

    def test_a_read_only_manager_gets_no_import_button(self):
        """The button is drawn only where the list allows creating, and the
        server strips `create` for a role without create rights."""
        env = self.env(user=self._restricted_user())
        for xmlid, model in (
                ("assessments_be_question_tree", "assessments.be.question"),
                ("assessments_be_prompt_tree", "assessments.be.prompt")):
            root = self._arch(xmlid, model, env=env)
            self.assertEqual(root.get("create"), "False", xmlid)

    # ── drafts first ─────────────────────────────────────────────────────

    def _wizard(self, text=_CSV, env=None):
        return (env or self.env)["assessments.be.bank.import.wizard"].create({
            "data_file": _b64(text),
            "data_filename": "bank.csv",
            "generator_name": "Import %s" % uuid4().hex[:6],
        })

    def test_csv_rows_wait_in_pending_approvals(self):
        result = self._wizard().run_import()

        drafts = self.env["assessments.be.prompt.question"].search(
            [("prompt_id", "=", result["generator_id"])])
        self.assertEqual(len(drafts), 2)
        self.assertEqual(set(drafts.mapped("state")), {"draft"})
        self.assertFalse(
            self.env["assessments.be.question"].search(
                [("generator_id", "=", result["generator_id"])]),
            "a CSV row reached the bank without review")
        self.assertIn("draft", result["message"])
        self.assertIn("Pending Approvals", result["message"])

    def test_the_wizard_and_the_route_make_the_same_drafts(self):
        by_wizard = self._wizard().run_import()
        by_route = call_route(
            write_api, write_api.EtpAssessmentApiWrite(), "bank_import",
            self.env, content=_b64(_CSV), filename="bank.csv",
            generator_name="Route %s" % uuid4().hex[:6])
        self.assertEqual(status_of(by_route), 200, by_route)
        by_route = by_route["data"]

        def rows(generator_id):
            drafts = self.env["assessments.be.prompt.question"].search(
                [("prompt_id", "=", generator_id)], order="id")
            return [tuple(d[f] for f in _DRAFT_FIELDS) for d in drafts]

        self.assertEqual(by_wizard["format"], by_route["format"])
        self.assertEqual(rows(by_wizard["generator_id"]),
                         rows(by_route["generator_id"]))

    # ── the dialogs close ────────────────────────────────────────────────

    def test_every_import_dialog_closes_on_success(self):
        closes = {"type": "ir.actions.act_window_close"}
        bank = self._wizard().action_import()
        self.assertEqual(bank["tag"], "display_notification")
        self.assertEqual(bank["params"]["next"], closes)

        from ..models import simple_import
        tags = self.env["assessments.be.tag.import.wizard"].create({
            "data_file": _b64(self.env["assessments.be.simple.import"]
                              .tag_template_csv()),
        }).action_import()
        gens = self.env["assessments.be.generator.import.wizard"].create({
            "data_file": _b64(",".join(simple_import.GENERATOR_COLUMNS)
                              + "\nImported %s\n" % uuid4().hex[:6]),
        }).action_import()
        for action in (tags, gens):
            self.assertEqual(action["params"]["next"], closes)

    # ── who may import ───────────────────────────────────────────────────

    def test_a_non_admin_is_refused_on_both_surfaces(self):
        env = self.env(user=self._restricted_user())
        with self.assertRaises(AccessError):
            self._wizard(env=env)

        refused = call_route(
            write_api, write_api.EtpAssessmentApiWrite(), "bank_import", env,
            content=_b64(_CSV), filename="bank.csv")
        self.assertEqual(status_of(refused), 403)

    def test_the_template_still_round_trips_through_review(self):
        """The downloadable template imports as drafts, and approving them
        still produces keyed bank questions."""
        result = self._wizard(wizard_module.build_template_csv()).run_import()
        generator = self.env["assessments.be.prompt"].browse(
            result["generator_id"])
        self.assertFalse(generator.question_ids.filtered(
            lambda d: d.state != "draft"))
        generator.question_ids.action_approve()
        questions = self.env["assessments.be.question"].search(
            [("generator_id", "=", generator.id)])
        self.assertTrue(questions.question_dimension_ids.option_line_ids
                        .filtered("is_correct"))
