# -*- coding: utf-8 -*-
"""The views added by D1 and D3 render, not merely load.

A view that PARSES is not a view that WORKS. Odoo validates the XML at install
and resolves fields at render, so a widget that does not exist, a field on the
wrong model or an `invisible=` naming an unloaded field all install cleanly and
throw the first time somebody opens the record. Every defect in this area found
so far was found by opening a screen, which is exactly the loop this replaces.

`get_view` is the same call the web client makes, so it exercises arch
post-processing, field resolution and widget lookup - the three things that
fail at render.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestTheNewViewsRender(TransactionCase):

    def _render(self, model, xmlid, view_type):
        view = self.env.ref("assessments_be_v2.%s" % xmlid)
        arch = self.env[model].get_view(view.id, view_type)
        self.assertTrue(
            arch.get("arch"),
            "%s rendered an empty arch" % xmlid)
        return arch

    # ── D1: the manual flag ────────────────────────────────────────────────

    def test_the_evaluator_list_renders_with_the_flag_column(self):
        arch = self._render("assessments.be.evaluator",
                            "assessments_be_evaluator_tree", "list")
        self.assertIn("manual_flagged", arch["arch"])

    def test_the_evaluator_search_renders_with_the_flag_filter(self):
        arch = self._render("assessments.be.evaluator",
                            "assessments_be_evaluator_search", "search")
        self.assertIn("manually_flagged", arch["arch"])

    def test_the_evaluator_form_renders_the_flag_banner_and_editor(self):
        """The banner and the ONE editing surface, in the same arch.

        The attempt form is now the only place the flag is written in Odoo, so
        a field that fails to resolve here does not merely hide a banner - it
        removes the operator's only way to raise or clear the flag outside the
        API.
        """
        arch = self._render("assessments.be.evaluator",
                            "assessments_be_evaluator_form", "form")
        for field in ("manual_flagged", "manual_remark",
                      "manual_flagged_by_id", "manual_flagged_at"):
            self.assertIn(field, arch["arch"], "%s missing from the form" % field)

    def test_the_assessment_form_renders_its_embedded_rosters(self):
        """The Roster, Candidates and Leaderboard sub-views all live inside
        this one arch, so one render covers all three."""
        arch = self._render("assessments.be", "assessments_be_form", "form")
        self.assertIn("manual_flagged", arch["arch"])
        self.assertIn("action_llm_score_failed", arch["arch"],
                      "the D3 cohort re-score button must be on the header")

    def test_the_candidate_dashboard_carries_the_flag_per_attempt_only(self):
        """NO person-level banner, and a per-attempt column that renders.

        Both halves are asserted, because dropping the banner and dropping the
        column would look identical to a test that only checked the banner had
        gone - and the column is the surface that makes the per-sitting design
        legible: the same person can show flagged on one row and clean on the
        next.
        """
        arch = self._render("hr.applicant",
                            "etp_hr_applicant_candidate_dashboard_form", "form")
        self.assertNotIn(
            "be_flag", arch["arch"],
            "the person-level flag is gone; nothing on the applicant may "
            "still name it")
        self.assertIn("manual_flagged", arch["arch"],
                      "the inline assessment-history list carries it per row")

    # ── D3: task templates, which had no views at all ──────────────────────

    def test_the_task_template_list_renders(self):
        arch = self._render("assessments.be.task.template",
                            "assessments_be_task_template_tree", "list")
        self.assertIn("has_shape_warnings", arch["arch"])

    def test_the_task_template_form_renders(self):
        """Including the `json` widget on `structure_json`, which is the one
        widget in this file that is not used anywhere else in the addon."""
        arch = self._render("assessments.be.task.template",
                            "assessments_be_task_template_form", "form")
        self.assertIn("structure_json", arch["arch"])

    def test_the_task_template_search_renders(self):
        self._render("assessments.be.task.template",
                     "assessments_be_task_template_search", "search")

    def test_the_task_template_action_and_menu_exist(self):
        """A view nobody can navigate to is the gap this closed - the model
        had full CRUD rights and no way in."""
        action = self.env.ref(
            "assessments_be_v2.action_assessments_be_task_template")
        self.assertEqual(action.res_model, "assessments.be.task.template")
        menu = self.env.ref("assessments_be_v2.menu_assessments_be_task_templates")
        self.assertEqual(menu.action, action,
                         "the menu must point at that action")

    # ── D3: Studio forms, which also had no views at all ───────────────────

    def test_the_studio_form_list_renders(self):
        arch = self._render("etp.studio.form", "etp_studio_form_tree", "list")
        self.assertIn("published", arch["arch"])

    def test_the_studio_form_form_renders_with_its_publish_button(self):
        arch = self._render("etp.studio.form", "etp_studio_form_form", "form")
        self.assertIn("action_publish", arch["arch"],
                      "publishing was reachable only through the API")
        self.assertIn("structure_json", arch["arch"])

    def test_the_studio_form_form_renders_the_item_editor(self):
        """THE ONLY WAY TO AUTHOR A FORM IN ODOO, and a widget name that does
        not resolve is not a load error - the web client silently falls back to
        rendering the field raw. On this page that fallback is a JSON blob where
        the editor should be, and the operator's only conclusion is that the
        editor was never built.

        BOTH NODES ARE ASSERTED. `structure_json` appears twice on purpose: the
        editor on the Structure tab and the read-only JSON on the Raw JSON tab,
        which is the escape hatch that existed before the editor did. Dropping
        either would look identical to a test that only counted the field once.
        """
        arch = self._render("etp.studio.form", "etp_studio_form_form", "form")
        self.assertIn(
            "be_form_item_editor", arch["arch"],
            "the form item editor is the surface that closed the last two "
            "parity rows; nothing else on this model can edit an item")
        self.assertIn(
            'widget="json"', arch["arch"],
            "the raw document keeps its own read-only page - an operator who "
            "read the spec there must not lose it")
        self.assertEqual(
            arch["arch"].count('name="structure_json"'), 2,
            "the editor and the raw JSON escape hatch are both bound to the "
            "field")

    def test_the_item_editor_assets_are_declared(self):
        """A widget whose files are not in `web.assets_backend` never loads.

        The arch would still name it, the registry would not have it, and the
        field would render RAW - a JSON blob where the editor should be, which
        is indistinguishable from the editor being broken. Odoo only logs a
        bundle warning for a missing asset path, so nothing else catches it.
        """
        import os

        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(os.path.join(here, "__manifest__.py"), "r",
                  encoding="utf-8") as fh:
            declared = fh.read()
        for ext in ("scss", "js", "xml"):
            path = ("assessments_be_v2/static/src/fields/form_item_editor/"
                    "form_item_editor.%s" % ext)
            self.assertIn(path, declared,
                          "%s is not in web.assets_backend" % path)
            on_disk = os.path.join(here, path.split("/", 1)[1])
            self.assertTrue(os.path.exists(on_disk),
                            "%s is declared but missing on disk" % path)

    def test_the_studio_form_search_renders(self):
        self._render("etp.studio.form", "etp_studio_form_search", "search")

    def test_the_studio_form_is_reachable_from_the_menu(self):
        action = self.env.ref("assessments_be_v2.action_etp_studio_form")
        self.assertEqual(action.res_model, "etp.studio.form")
        menu = self.env.ref("assessments_be_v2.menu_assessments_be_forms")
        self.assertEqual(menu.action, action)

    def test_the_publish_button_refuses_an_unpublishable_form(self):
        """It must RAISE, not return problems.

        The API route answers `{"problems": [...]}` with a 422; a view button
        that returned the same dict would let Odoo commit the transaction and
        show a success toast over a form that was refused.
        """
        from odoo.exceptions import UserError
        form = self.env["etp.studio.form"].create({
            "client_uid": "uid_%s" % uuid4().hex[:8],
            "title": "Empty form",
            "structure_json": [],
        })
        with self.assertRaises(UserError):
            form.action_publish()

    def test_the_responses_search_renders_with_the_combined_box(self):
        arch = self._render("assessments.be.response",
                            "assessments_be_response_search", "search")
        self.assertIn("evaluator_id", arch["arch"])

    # ── the annotation editor, mounted on the question form ────────────────

    def test_the_question_form_renders_the_annotation_editor(self):
        """THE ONE THING A MISSING WIDGET FILE LOOKS LIKE.

        `be_annotation_editor` is a JS field widget, and a widget name that does
        not resolve is not a load error - Odoo installs the arch happily and the
        web client falls back to rendering the bound field RAW. On this form that
        means an operator opening a labelling question to move a box gets a
        textarea full of `solution_json` instead, i.e. exactly the state this
        feature exists to replace, with nothing in the log to say so.

        `get_view` is the call the web client makes, so it exercises arch
        post-processing and field resolution: `solution_json` must exist on the
        model, and the `invisible` expression must name a field the view loads
        (`question_type`). The widget's own registration is asserted from the
        manifest side by
        `test_the_annotation_editor_assets_are_declared` below.
        """
        arch = self._render("assessments.be.question",
                            "assessments_be_question_form", "form")
        self.assertIn(
            'widget="be_annotation_editor"', arch["arch"],
            "the graphical box editor must be on the question form")
        self.assertIn(
            "solution_json", arch["arch"],
            "the editor is bound to solution_json - the golden-answer map it "
            "authors - so the field has to survive post-processing")
        self.assertIn(
            "subjective_rubric_json", arch["arch"],
            "the raw answer key was MOVED under Advanced, never removed: "
            "decoys / mandatory_elements / penalty_rules / scoring_guide are "
            "editable nowhere else")

    def test_the_annotation_editor_assets_are_declared(self):
        """The three widget files exist AND are in `web.assets_backend`.

        Nothing else checks this. `tools/verify.sh` existence-checks the `data`
        key only, and Odoo logs a bundle warning for a missing asset path rather
        than refusing to start - so a typo'd path (or a file added to the folder
        and forgotten in the manifest) ships a view whose widget silently never
        registers, which is indistinguishable from the widget being broken.
        """
        import os

        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        expected = [
            "assessments_be_v2/static/src/fields/annotation_editor/"
            "annotation_editor.%s" % ext
            for ext in ("scss", "js", "xml")
        ]
        with open(os.path.join(here, "__manifest__.py"), "r",
                  encoding="utf-8") as fh:
            declared = fh.read()
        for path in expected:
            self.assertIn(path, declared,
                          "%s is not in web.assets_backend" % path)
            on_disk = os.path.join(here, path.split("/", 1)[1])
            self.assertTrue(os.path.exists(on_disk),
                            "%s is declared but missing on disk" % path)
