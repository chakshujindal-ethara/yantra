"""Every primitive hands the generator ITS OWN answer-key data.

THE DEFECT THIS PINS. `answer_contract()` used to emit axes+options and
nothing else - exactly what an A/B item needs and almost nothing of what the
other primitives need. So a written answer's rubric, an annotation task's
target list and a generated stimulus's brief were all invented by the model,
per item, with no examiner input: not provable by construction, and nothing
for a quality pass to tune. Worse, an examiner whose task had no
overall-preference axis had their OWN axes rejected, because only a plan
carrying `dimension_options` is exempt from the mandatory Overall Choice and a
template never emitted that field.
"""
from odoo.tests.common import TransactionCase

from ..constants import TASK_PRIMITIVE_TO_QUESTION_TYPE, validate_flaw_plan


def _choice(title, options):
    return {"kind": "multipleChoice", "title": title,
            "options": [{"label": o} for o in options]}


class TestTemplateContractPerPrimitive(TransactionCase):

    def _mk(self, response, items=(), **extra):
        return self.env["assessments.be.task.template"].create(dict({
            "name": "T", "response": response,
            "structure_json": [{"title": "S", "items": list(items)}],
        }, **extra))

    # ---- the non-A/B unblock -------------------------------------------
    def test_axes_emit_per_axis_options(self):
        """Without this map a non-A/B task cannot be stated at all."""
        tpl = self._mk("compare_two", [
            _choice("Was the edit applied?", ["Yes", "No"]),
            _choice("Is identity preserved?", ["Yes", "No"]),
        ])

        contract = tpl.answer_contract()

        self.assertEqual(contract["dimension_options"], {
            "Was the edit applied?": ["Yes", "No"],
            "Is identity preserved?": ["Yes", "No"],
        })

    def test_a_task_with_no_overall_axis_is_accepted(self):
        """The examiner's own axes must not be refused for a missing OC."""
        tpl = self._mk("compare_two", [
            _choice("Was the edit applied?", ["Yes", "No"]),
            _choice("Is identity preserved?", ["Yes", "No"]),
        ])
        contract = tpl.answer_contract()
        plan = {
            "worker_prompt": "Edit the photo.",
            "render_prompts": {"a": "before", "b": "after"},
            "construction_keys": {"Was the edit applied?": "Yes",
                                  "Is identity preserved?": "No"},
            "dimension_options": contract["dimension_options"],
        }

        self.assertFalse(
            validate_flaw_plan(plan),
            "a plan carrying the template's own options needs no Overall Choice")

    def test_a_plain_ab_template_still_carries_its_axes(self):
        """The A/B path that already worked must not regress."""
        tpl = self._mk("compare_two", [
            _choice("Which image follows the prompt?",
                    ["Response A", "Response B", "Both Good", "Both Bad"]),
            _choice("Which do you prefer overall?",
                    ["Response A", "Response B"]),
        ])

        contract = tpl.answer_contract()

        labels = [d["label"] for d in contract["dimensions"]]
        self.assertIn("Which image follows the prompt?", labels)
        self.assertEqual(
            len(contract["dimension_options"]["Which do you prefer overall?"]),
            2, "asymmetric option counts survive")

    # ---- rubric ---------------------------------------------------------
    def test_a_written_answer_carries_the_examiners_rubric(self):
        tpl = self._mk(
            "free_text", [{"kind": "paragraph", "title": "Explain."}],
            rubric_criteria="Identifies the flaw\nExplains the impact",
            rubric_pass_condition="Names the flaw AND proposes a fix",
            rubric_constraints="Under 150 words")

        rubric = tpl.answer_contract()["rubric"]

        self.assertEqual(rubric["checklist"],
                         ["Identifies the flaw", "Explains the impact"])
        self.assertEqual(rubric["pass_condition"],
                         "Names the flaw AND proposes a fix")
        self.assertEqual(rubric["constraints"], "Under 150 words")

    def test_blank_rubric_lines_are_not_criteria(self):
        tpl = self._mk(
            "free_text", [{"kind": "paragraph", "title": "Explain."}],
            rubric_criteria="One\n\n   \nTwo\n")

        self.assertEqual(tpl.answer_contract()["rubric"]["checklist"],
                         ["One", "Two"])

    def test_no_rubric_authored_means_no_rubric_key(self):
        """Absent, not empty: an empty rubric would fail the type's contract."""
        tpl = self._mk("free_text",
                       [{"kind": "paragraph", "title": "Explain."}])

        self.assertNotIn("rubric", tpl.answer_contract())

    # ---- annotation -----------------------------------------------------
    def test_annotation_targets_and_derived_count(self):
        tpl = self._mk(
            "annotate_image", [{"kind": "shortText", "title": "Mark them."}],
            annotation_targets="Extra finger\nMisspelled sign\nMelted edge")

        contract = tpl.answer_contract()

        self.assertEqual(contract["annotation_targets"],
                         ["Extra finger", "Misspelled sign", "Melted edge"])
        self.assertEqual(contract["annotation_expected_count"], 3,
                         "count derives from the list when not stated")

    def test_an_explicit_count_wins_over_the_list_length(self):
        """'any three of these five' is a real task shape."""
        tpl = self._mk(
            "annotate_image", [{"kind": "shortText", "title": "Mark them."}],
            annotation_targets="A\nB\nC\nD\nE",
            annotation_expected_count=3)

        self.assertEqual(
            tpl.answer_contract()["annotation_expected_count"], 3)

    # ---- media brief ----------------------------------------------------
    def test_media_brief_reaches_the_contract(self):
        tpl = self._mk(
            "author_video_prompt",
            [{"kind": "paragraph", "title": "Write the prompt."}],
            media_brief="A 5s clip of a cat leaping onto a windowsill")

        self.assertEqual(tpl.answer_contract()["media_brief"],
                         "A 5s clip of a cat leaping onto a windowsill")

    # ---- the video primitive -------------------------------------------
    def test_the_video_primitive_routes_to_video_prompt(self):
        """video_prompt was a stored type NO primitive could ever reach."""
        self.assertEqual(
            TASK_PRIMITIVE_TO_QUESTION_TYPE["author_video_prompt"],
            "video_prompt")

        tpl = self._mk("author_video_prompt",
                       [{"kind": "paragraph", "title": "Write the prompt."}])

        self.assertEqual(tpl.question_type, "video_prompt")
        self.assertEqual(tpl.usable_count, 1)

    def test_every_primitive_maps_to_a_question_type(self):
        """A primitive with no type would author unservable items."""
        Template = self.env["assessments.be.task.template"]
        for code, _label in Template._fields["response"].selection:
            self.assertIn(code, TASK_PRIMITIVE_TO_QUESTION_TYPE,
                          "primitive %r has no question type" % code)
