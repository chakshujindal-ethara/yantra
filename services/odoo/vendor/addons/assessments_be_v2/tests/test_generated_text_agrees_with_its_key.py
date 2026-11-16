"""Every piece of text a generated comparison carries agrees with its answer key.

Three defects from the 2026-09-29 production run of "Video Caption Labeling":

  * 1167 / 1178. The builder puts the flawed image on a random slot and flips
    the key and the official reasoning with it, but the model's own rationale
    (and the justification in its solution) still named the pre-swap sides:
    the key said Response B, the rationale praised A and faulted B.
  * 1165. Yes/No checks on a reference image were given the Response A/B
    "correct by construction ... wins Overall Choice" sentence - a question the
    candidate was never asked - and the justification judge grades against it.
  * 1165. The template's axis "Is this reference a {type}?" reached the
    candidate with the raw placeholder, because nothing ever filled the slot.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.services import vertex

FLAW_1167 = ("The left hand is performing the action instead of the right "
             "hand, violating the instruction.")
RATIONALE_1167 = (
    "Response A correctly follows the instruction to use the right hand. "
    "Response B is flawed because it depicts the left hand performing the "
    "action, violating the explicit hand phrasing in the prompt.")
FLAW_1165 = ("The reference image shows multiple different items on a rack, "
             "meaning the target entity is not single and isolated.")
AXES_1165 = {
    "1. Is this reference a {type}?": ["Yes", "No", "Nothing meaningful shown"],
    "2. Same exact {type} as tagged?": ["Yes", "No"],
    "3. Different source than the video?": ["Yes", "No"],
    "4. Single, isolated {type} on its own?": ["Yes", "No"],
}
KEY_1165 = {"1. Is this reference a {type}?": "Yes",
            "2. Same exact {type} as tagged?": "Yes",
            "3. Different source than the video?": "Yes",
            "4. Single, isolated {type} on its own?": "No"}


@tagged("-at_install", "post_install")
class TestGeneratedTextAgreesWithItsKey(TransactionCase):

    def setUp(self):
        super().setUp()
        self.gen = self.env["assessments.be.prompt"].create({
            "name": "Video Caption Labeling %s" % uuid4().hex[:6],
            "source_text": "Label egocentric video clips.",
        })

    def _generate(self, item, solution, slot, quotas=None):
        """One model reply through the real draft writer.

        `slot` is what `random.choice` returns, so the builder's swap is
        decided by the test: the flawed image lands on `slot`.
        """
        raw = json.dumps({"questions": [item], "solutions": [solution]})
        with patch.object(vertex, "_call_vertex", return_value=raw) as call, \
                patch.object(vertex, "_selfheal_generation",
                             side_effect=lambda env, pr, items, *a, **k: items), \
                patch("random.choice", return_value=slot):
            ids = vertex.generate_questions_from_sop(
                self.env, self.gen, shape_quotas=quotas, report={})
        self.assertEqual(len(ids), 1)
        return self.env["assessments.be.prompt.question"].browse(ids), call

    # -- B: the rationale follows the swap -------------------------------

    def _item_1167(self):
        name = "Evaluate AI-generated L3 action draft"
        item = {
            "name": name, "question_type": "image_ab",
            "prompt": "place the red cup on the top shelf with the right hand",
            "image_specs": {"flaw_plan": {
                "faithful_side": "a",
                "worker_prompt": "place the red cup on the top shelf with "
                                 "the right hand",
                "render_prompts": {"a": "the right hand places a red cup",
                                   "b": "the left hand places a red cup"},
                "planted": {"a": [], "b": [FLAW_1167]},
                "construction_keys": {"IF": "Response A", "VQ": "Both Good",
                                      "LAI": "Both Good", "OC": "Response A"},
            }},
        }
        solution = {"question_ref": name, "rationale": RATIONALE_1167,
                    "answers": {"justification": "Response A keeps the right "
                                                 "hand; Response B does not."}}
        return item, solution

    def test_a_swapped_comparison_swaps_its_rationale_too(self):
        draft, _call = self._generate(*self._item_1167(), slot="a")

        self.assertTrue(draft.official_reasoning.startswith(
            "Response B is correct by construction"), "the swap happened")
        self.assertEqual(json.loads(draft.solution_json)["overall_preference"],
                         "Response B")
        self.assertEqual(
            draft.solution_rationale,
            "Response B correctly follows the instruction to use the right "
            "hand. Response A is flawed because it depicts the left hand "
            "performing the action, violating the explicit hand phrasing in "
            "the prompt.")
        self.assertEqual(
            json.loads(draft.solution_json)["justification"],
            "Response B keeps the right hand; Response A does not.")

    def test_an_unswapped_comparison_keeps_its_rationale(self):
        draft, _call = self._generate(*self._item_1167(), slot="b")

        self.assertTrue(draft.official_reasoning.startswith(
            "Response A is correct by construction"))
        self.assertEqual(draft.solution_rationale, RATIONALE_1167)

    # -- C and D: a Yes/No template with a {type} slot -------------------

    def _template(self):
        items = [{"id": "i%d" % n, "kind": "multipleChoice", "title": title,
                  "options": [{"id": "i%d-%d" % (n, m), "label": o}
                              for m, o in enumerate(options)]}
                 for n, (title, options) in enumerate(AXES_1165.items())]
        return self.env["assessments.be.task.template"].create({
            "name": "Verify Video Entities %s" % uuid4().hex[:6],
            "origin_prompt_id": self.gen.id,
            "response": "compare_two",
            "question_type": "image_ab",
            "structure_json": [{"id": "s", "title": "Checks", "items": items}],
        })

    def _item_1165(self, values=None):
        name = "Task: Verify Video Entities"
        item = {
            "name": name, "question_type": "image_ab",
            "prompt": "A tagged video frame on the left and a reference image "
                      "on the right. Verify the {type}.",
            "image_specs": {"flaw_plan": {
                "faithful_side": "a",
                "worker_prompt": "Verify the tagged entity.",
                "render_prompts": {"a": "a video frame of a red floral dress",
                                   "b": "the dress on a rack of clothes"},
                "planted": {"a": [], "b": [FLAW_1165]},
                "construction_keys": dict(KEY_1165),
                "dimension_options": dict(AXES_1165),
                "dimension_labels": {k: k for k in KEY_1165},
            }},
        }
        if values is not None:
            item["template_values"] = values
        solution = {"question_ref": name,
                    "rationale": "The reference shows the {type} on a rack.",
                    "answers": {k: v for k, v in KEY_1165.items()}}
        return item, solution

    def _generate_1165(self, values=None):
        tpl = self._template()
        draft, call = self._generate(
            *self._item_1165(values), slot="a",
            quotas={"template:%d" % tpl.id: 1})
        self.assertEqual(draft.source_template_id, tpl)
        return draft, call

    def test_yes_no_checks_are_reasoned_on_their_own_key(self):
        draft, _call = self._generate_1165({"type": "dress"})

        self.assertEqual(
            draft.official_reasoning,
            "The correct ratings are: 1. Is this reference a dress?: Yes; "
            "2. Same exact dress as tagged?: Yes; 3. Different source than "
            "the video?: Yes; 4. Single, isolated dress on its own?: No. "
            + FLAW_1165)
        self.assertNotIn("Response", draft.official_reasoning)
        self.assertNotIn("Overall Choice", draft.official_reasoning)

    def test_yes_no_checks_keep_the_images_where_the_prompt_puts_them(self):
        """No side on any axis: nothing to randomise, so no swap - even when
        `random.choice` would have asked for one."""
        draft, _call = self._generate_1165({"type": "dress"})

        plan = json.loads(draft.flaw_plan_json)
        self.assertEqual(plan["render_prompts"]["a"],
                         "a video frame of a red floral dress")
        self.assertEqual(plan["planted"]["b"], [FLAW_1165])

    def test_the_template_slot_is_filled_everywhere(self):
        draft, call = self._generate_1165({"type": "dress"})

        directive = call.call_args_list[0].kwargs["user_parts"][-1]["text"]
        self.assertIn('"template_values": {"type": "<value>"}', directive)
        labels = draft.answer_dimension_ids.mapped("label")
        self.assertEqual(labels[0], "1. Is this reference a dress?")
        for field in ("name", "question_prompt", "solution_json",
                      "solution_rationale", "official_reasoning",
                      "flaw_plan_json", "dimensions_json"):
            self.assertNotIn("{type}", (draft[field] or "").lower(), field)
        self.assertNotIn("{type}", " ".join(labels).lower())

    def test_an_unnamed_slot_falls_back_to_a_neutral_word(self):
        draft, _call = self._generate_1165()

        self.assertEqual(draft.answer_dimension_ids[0].label,
                         "1. Is this reference an item?")

    def test_a_filled_draft_approves_without_key_drift(self):
        """The label and the flaw_plan code are filled alike, so the guard
        that maps one onto the other still finds every axis."""
        draft, _call = self._generate_1165({"type": "dress"})
        question = self.env["assessments.be.question"].create({
            "name": draft.name, "question_type": "image_ab",
            "prompt": draft.question_prompt,
            "flaw_plan_json": draft.flaw_plan_json,
        })
        draft._materialize_dimensions(question)

        draft._assert_no_key_drift(question)
        names = question.question_dimension_ids.mapped("name")
        self.assertEqual(len(names), 4)
        self.assertNotIn("{", " ".join(names), "a candidate reads these")
