# -*- coding: utf-8 -*-
"""W11: Question Templates on the generator, in Odoo.

What the app has under Generators -> generator -> Skills & Templates ->
Question Templates, and on the Generation tab's "Allowed question types":

  * Draft from SOP is one paid call that SAVES NOTHING - it opens an unsaved
    form - and a non-Admin is refused before any call is made. (Its Odoo
    button is hidden for now, S8; the method is kept and tested.)
  * Archiving a template removes `template:<id>` from every generator's counts;
    un-archiving does not put them back.
  * Golden examples are text only, refused with the API's own message.
  * An Admin's save in Odoo clears the answer-key fields the response does not
    use; the API route and plain writes are unchanged.
  * "Fix before generating" is reported, never enforced.
  * The views render with the editor, the counts widget and the new page.

No test here reaches Vertex: the draft call is patched, as in
`test_task_template_api.py`.
"""
import json
import os
from unittest.mock import patch
from uuid import uuid4

from lxml import etree

from odoo.exceptions import AccessError, UserError
from odoo.tests.common import TransactionCase, tagged

from ..services import vertex

_RESTRICTED = "assessments_be_v2.group_assessment_manager_restricted"
_HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_DRAFT = {
    "name": "Judge the edit",
    "instructions": "Two images, one planted flaw.",
    "response": "compare_two",
    "media_brief": "A cup on a table.",
    "structure": [{"id": "s1", "title": "Questions", "items": [
        {"id": "i1", "kind": "multipleChoice", "title": "Which is better?",
         "options": [{"label": "A"}, {"label": "B"}]}]}],
    "item_count": 1,
    "warnings": [],
}


def _choice(title="Which is better?", options=("A", "B")):
    return {"kind": "multipleChoice", "title": title,
            "options": [{"label": o} for o in options]}


@tagged("-at_install", "post_install")
class TestQuestionTemplatesOnTheGenerator(TransactionCase):

    def setUp(self):
        super().setUp()
        # An Assessment Admin, like the people who use these screens.
        self.env.user.group_ids = [
            (4, self.env.ref("assessments_be_v2.group_assessment_manager").id)]
        self.Prompt = self.env["assessments.be.prompt"]
        self.Template = self.env["assessments.be.task.template"]
        self.gen = self.Prompt.create({"name": "Gen %s" % uuid4().hex[:6]})

    def _template(self, **vals):
        vals.setdefault("name", "Tpl %s" % uuid4().hex[:6])
        vals.setdefault("structure_json",
                        [{"title": "S", "items": [_choice()]}])
        return self.Template.create(vals)

    def _restricted_env(self):
        user = self.env["res.users"].create({
            "name": "Read-only %s" % uuid4().hex[:6],
            "login": "ro_%s@example.com" % uuid4().hex[:8],
            "group_ids": [(6, 0, [self.env.ref("base.group_user").id,
                                  self.env.ref(_RESTRICTED).id])],
        })
        return self.env(user=user)

    # ── Draft from SOP ───────────────────────────────────────────────────

    def test_draft_from_sop_opens_an_unsaved_form_and_saves_nothing(self):
        before = self.Template.with_context(active_test=False).search_count([])
        with patch.object(vertex, "draft_task_template_from_sop",
                          return_value=dict(_DRAFT)) as drafted:
            action = self.gen.action_draft_task_template()

        self.assertEqual(drafted.call_count, 1)
        self.assertEqual(
            self.Template.with_context(active_test=False).search_count([]),
            before, "Draft from SOP saved a template before Save")
        self.assertEqual(action["res_model"], "assessments.be.task.template")
        self.assertFalse(action.get("res_id"), "the draft must open unsaved")
        ctx = action["context"]
        self.assertEqual(ctx["default_origin_prompt_id"], self.gen.id)
        self.assertEqual(ctx["default_authored_by"], "llm_edited")
        self.assertEqual(ctx["default_structure_json"], _DRAFT["structure"])
        self.assertEqual(ctx["default_name"], _DRAFT["name"])

        # What Save would create from those defaults - the draft, as drafted.
        saved = self.Template.with_context(**ctx).create({})
        self.assertEqual(saved.origin_prompt_id, self.gen)
        self.assertEqual(saved.response, "compare_two")
        self.assertEqual(saved.item_count, 1)

    def test_draft_from_sop_refuses_a_non_admin_before_the_call(self):
        env = self._restricted_env()
        with patch.object(vertex, "draft_task_template_from_sop") as drafted:
            with self.assertRaises(AccessError):
                self.gen.with_env(env).action_draft_task_template()
            with self.assertRaises(AccessError):
                self.gen.with_env(env).action_new_task_template()
        drafted.assert_not_called()

    def test_a_model_refusal_is_said_not_crashed(self):
        with patch.object(vertex, "draft_task_template_from_sop",
                          side_effect=vertex.LLMRefusalError("upload a SOP")):
            with self.assertRaises(UserError) as caught:
                self.gen.action_draft_task_template()
        self.assertIn("upload a SOP", str(caught.exception))

    def test_new_template_is_attributed_to_the_generator(self):
        action = self.gen.action_new_task_template()
        self.assertFalse(action.get("res_id"))
        self.assertEqual(action["context"]["default_origin_prompt_id"],
                         self.gen.id)

    # ── archive clears counts ────────────────────────────────────────────

    def test_archiving_removes_the_template_from_every_generators_counts(self):
        dead = self._template()
        live = self._template()
        # An id sharing a prefix with `dead` must not be touched.
        other_key = "template:%d9" % dead.id
        quotas = {"template:%d" % dead.id: 2, "template:%d" % live.id: 3,
                  other_key: 1}
        self.gen.write({"shape_quota_json": json.dumps(quotas),
                        "sop_question_count": 6})
        archived_gen = self.Prompt.create({
            "name": "Old gen %s" % uuid4().hex[:6],
            "shape_quota_json": json.dumps({"template:%d" % dead.id: 1}),
            "sop_question_count": 1,
        })
        archived_gen.active = False

        dead.action_archive()

        self.assertEqual(json.loads(self.gen.shape_quota_json),
                         {"template:%d" % live.id: 3, other_key: 1})
        self.assertEqual(self.gen.sop_question_count, 4,
                         "the pinned count follows the remaining picks")
        self.assertFalse(archived_gen.shape_quota_json,
                         "an archived generator's counts are swept too")

        dead.action_unarchive()
        self.assertNotIn("template:%d" % dead.id,
                         json.loads(self.gen.shape_quota_json),
                         "un-archiving does not restore the count")

    def test_editing_a_template_leaves_counts_alone(self):
        tpl = self._template()
        self.gen.shape_quota_json = json.dumps({"template:%d" % tpl.id: 2})
        tpl.write({"name": "Renamed"})
        self.assertEqual(json.loads(self.gen.shape_quota_json),
                         {"template:%d" % tpl.id: 2})

    # Golden examples are sample questions now, any file type:
    # test_golden_questions_are_sample_questions.

    # ── the template form's save ─────────────────────────────────────────

    def test_an_admin_save_clears_the_fields_the_response_does_not_use(self):
        tpl = self._template(
            response="free_text", rubric_criteria="Names the flaw",
            annotation_targets="Extra finger", annotation_expected_count=2,
            media_brief="A cup")

        tpl.web_save({"response": "compare_two"}, {})

        self.assertFalse(tpl.rubric_criteria)
        self.assertFalse(tpl.annotation_targets)
        self.assertEqual(tpl.annotation_expected_count, 0)
        self.assertEqual(tpl.media_brief, "A cup",
                         "compare_two uses the media brief")

    def test_a_plain_write_and_the_api_keep_todays_behaviour(self):
        tpl = self._template(response="single_choice",
                             rubric_criteria="Stale but untouched")
        tpl.write({"name": "Renamed"})
        tpl.action_archive()
        self.assertEqual(tpl.rubric_criteria, "Stale but untouched")

    def test_fix_before_generating_is_reported_and_never_blocks_a_save(self):
        tpl = self._template(structure_json=[{"title": "S", "items": [
            _choice(title="Lonely", options=("Only one",)),
            {"kind": "choiceGrid", "title": "Grid", "rows": [], "columns": []},
        ]}])
        self.assertIn('"Lonely" needs at least two options.',
                      tpl.generate_problems)
        self.assertIn('"Grid" needs at least one row and one column.',
                      tpl.generate_problems)
        tpl.web_save({"name": "Still saves"}, {})
        self.assertEqual(tpl.name, "Still saves")

        clean = self._template()
        self.assertFalse(clean.generate_problems)

    def test_the_rows_carry_the_apps_badges(self):
        broken = self._template(
            authored_by="llm_edited", origin_prompt_id=self.gen.id,
            structure_json=[{"title": "S", "items": [
                _choice(title="Lonely", options=("One",))]}])
        self.gen.shape_quota_json = json.dumps(
            {"template:%d" % broken.id: 2})
        broken.invalidate_recordset()

        self.assertEqual(broken.draft_badge, "Model draft, edited")
        self.assertEqual(broken.usable_badge, "Generates nothing")
        self.assertEqual(broken.run_badge, "× 2 this run")
        self.assertIn(broken, self.gen.task_template_ids)

        healthy = self._template(origin_prompt_id=self.gen.id)
        self.assertFalse(healthy.draft_badge or healthy.usable_badge
                         or healthy.run_badge)

    def test_the_response_labels_are_the_apps(self):
        labels = dict(self.Template._fields["response"]._description_selection(
            self.env))
        self.assertEqual(labels["single_choice"], "Pick one option")
        self.assertEqual(labels["annotate_image"], "Mark points on an image")
        self.assertEqual(labels["describe_media"], "Describe an image or clip")

    # ── views ────────────────────────────────────────────────────────────

    def _arch(self, xmlid, model):
        view = self.env.ref("assessments_be_v2.%s" % xmlid)
        return etree.fromstring(self.env[model].get_view(view.id, "form")["arch"])

    def test_the_generator_form_carries_the_page_and_the_counts(self):
        root = self._arch("assessments_be_prompt_form", "assessments.be.prompt")
        page = root.find(".//page[@name='skills_templates']")
        self.assertIsNotNone(page)
        self.assertIsNotNone(page.find(".//field[@name='task_template_ids']"))
        self.assertIsNotNone(page.find(".//field[@name='upload_golden_file']"))
        draft = page.find(".//button[@name='action_draft_task_template']")
        self.assertIsNotNone(draft)
        self.assertTrue(draft.get("confirm"), "a paid call confirms first")
        self.assertEqual(draft.get("invisible"), "True",
                         "hidden for this push (Q10)")

        quotas = root.find(".//field[@name='shape_quota_json']")
        self.assertEqual(quotas.get("widget"), "be_template_quotas")
        self.assertIn("generating", quotas.get("readonly"))
        types = root.find(".//field[@name='allowed_question_type_ids']")
        self.assertFalse(
            [a for a in types.iterancestors() if a.tag == "details"],
            "Allowed question types is still folded into Advanced options")

    def test_the_template_form_uses_the_form_studio_editor_without_publish(self):
        root = self._arch("assessments_be_task_template_form",
                          "assessments.be.task.template")
        editor = root.find(".//field[@name='structure_json']")
        self.assertEqual(editor.get("widget"), "be_form_item_editor")
        self.assertIn("skip_publish_check", editor.get("options"))

        studio = self._arch("etp_studio_form_form", "etp.studio.form")
        for node in studio.findall(".//field[@name='structure_json']"):
            self.assertNotIn("skip_publish_check", node.get("options") or "",
                             "Form Studio must keep its publish check")

    def test_the_editor_option_is_off_unless_asked_for(self):
        path = os.path.join(_HERE, "static/src/fields/form_item_editor/"
                                   "form_item_editor.js")
        with open(path, encoding="utf-8") as fh:
            js = fh.read()
        self.assertIn("skipPublishCheck: Boolean(options.skip_publish_check)",
                      js)
        validate = js.split("async validate() {", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("if (this.props.skipPublishCheck)", validate)

    def test_the_counts_widget_is_declared_and_on_disk(self):
        with open(os.path.join(_HERE, "__manifest__.py"), encoding="utf-8") as fh:
            manifest = fh.read()
        for ext in ("js", "xml"):
            path = ("assessments_be_v2/static/src/fields/template_quotas/"
                    "template_quotas.%s" % ext)
            self.assertIn(path, manifest)
            self.assertTrue(os.path.exists(
                os.path.join(_HERE, path.split("/", 1)[1])))
