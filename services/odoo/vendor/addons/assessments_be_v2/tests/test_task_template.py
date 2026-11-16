"""A task template must produce the SAME specs the Form Studio designer does.

The whole design rests on reuse: a template stores the designer's own
`structure_json` and borrows `studio_form._item_spec` to turn it into question
specs. If those two ever diverge, a template silently authors a different shape
than the designer previewed - so this pins the reuse rather than trusting it.

Rollback-only: every test runs inside the test transaction.
"""
from odoo.exceptions import ValidationError
from odoo.tests.common import TransactionCase

from ..constants import TASK_PRIMITIVE_TO_QUESTION_TYPE


# One MCQ item, in the shape the designer writes. The answer-key flag is
# `correct` (not `is_correct`): `studio_form._options_of` reads `o.get("correct")`
# and emits `{"name", "is_correct"}`, so the input and output keys differ.
MCQ_STRUCTURE = [{
    "id": "sec-1",
    "title": "Judgment",
    "items": [{
        "id": "item-1",
        "kind": "multipleChoice",
        "title": "Does the image follow the prompt?",
        "options": [
            {"id": "o1", "label": "Yes", "correct": True},
            {"id": "o2", "label": "No", "correct": False},
        ],
    }],
}]


class TestTaskTemplate(TransactionCase):

    def _template(self, **kw):
        vals = {
            "name": "Judge prompt adherence",
            "structure_json": MCQ_STRUCTURE,
            "response": "single_choice",
        }
        vals.update(kw)
        return self.env["assessments.be.task.template"].create(vals)

    # ------------------------------------------------------------- the basics

    def test_a_template_saves_and_counts_its_items(self):
        tpl = self._template()

        self.assertEqual(tpl.item_count, 1)
        self.assertEqual(tpl.authored_by, "manual",
                         "hand-written is the default; an LLM draft is only "
                         "saved after a human edits it")

    def test_the_primitive_picks_the_question_type(self):
        """The admin picks a primitive; the type is derived, never chosen."""
        tpl = self._template(response="compare_two")

        self.assertEqual(tpl.question_type, "image_ab")
        self.assertEqual(
            self._template(response="free_text").question_type,
            "subjective_rubric")

    def test_every_primitive_is_selectable_and_maps(self):
        """A primitive offered in the UI that maps to nothing would break generation."""
        field = self.env["assessments.be.task.template"]._fields["response"]
        offered = [code for code, _label in field.selection]

        for code in offered:
            self.assertIn(code, TASK_PRIMITIVE_TO_QUESTION_TYPE)

    # ------------------------------------------------------------ the reuse

    def test_a_template_produces_the_studios_own_specs(self):
        """THE REUSE CLAIM. Same structure through both paths, same spec out."""
        tpl = self._template()
        specs, problems, _warnings = tpl.to_question_specs()

        self.assertEqual(problems, [], "a keyed MCQ is publishable as-is")
        self.assertEqual(len(specs), 1)
        self.assertEqual(specs[0]["question_type"], "mcq")
        self.assertEqual(specs[0]["name"], "Does the image follow the prompt?")
        options = specs[0]["dims"][0]["options"]
        self.assertEqual([o["name"] for o in options], ["Yes", "No"])
        self.assertTrue(options[0]["is_correct"])

    def test_an_unkeyed_item_is_reported_not_silently_accepted(self):
        """The designer refuses an MCQ with no correct option; so must a template."""
        broken = [{
            "id": "s", "title": "S",
            "items": [{
                "id": "i", "kind": "multipleChoice", "title": "No key",
                "options": [{"id": "a", "label": "Yes"},
                            {"id": "b", "label": "No"}],
            }],
        }]
        tpl = self._template(structure_json=broken)
        specs, problems, _warnings = tpl.to_question_specs()

        self.assertEqual(specs, [])
        self.assertTrue(problems, "an unkeyed question must be surfaced")

    # -------------------------------------------------------- answer contract

    def test_a_template_reads_as_an_answer_contract(self):
        """A template and an extracted SOP task must be interchangeable.

        That is what keeps the quota mechanism single-pathed: the generator does
        not care which one it was handed.
        """
        tpl = self._template(instructions="Pick the adherent image.")
        contract = tpl.answer_contract()

        self.assertEqual(contract["response"], "single_choice")
        self.assertEqual(contract["dimensions"][0]["options"], ["Yes", "No"])
        self.assertEqual(contract["solution_shape"], "Pick the adherent image.")

    def test_a_template_reads_as_a_task(self):
        tpl = self._template()
        task = tpl.as_task()

        self.assertEqual(task["key"], "template:%d" % tpl.id)
        self.assertEqual(task["display"], "Judge prompt adherence")
        self.assertIn("answer_contract", task)

    # ------------------------------------------------------------- lifecycle

    def test_a_template_outlives_its_origin_generator(self):
        """NULLABLE FK ON PURPOSE. A library must survive a tidy-up.

        A non-null FK would either block deleting a generator or cascade the
        admin's templates away with it.
        """
        gen = self.env["assessments.be.prompt"].create({"name": "SOP gen"})
        tpl = self._template(origin_prompt_id=gen.id)

        gen.unlink()

        self.assertTrue(tpl.exists(), "the template must survive")
        self.assertFalse(tpl.origin_prompt_id,
                         "its origin is forgotten, not fatal")

    def test_archiving_hides_without_destroying(self):
        """A launched assessment may cite a template; its questions are frozen."""
        tpl = self._template()
        tpl.active = False

        self.assertTrue(tpl.exists())
        self.assertNotIn(
            tpl.id,
            self.env["assessments.be.task.template"].search([]).ids,
            "an archived template leaves the default picker")

    # ------------------------------------------------------------- validation

    def test_a_non_list_structure_is_refused(self):
        with self.assertRaises(ValidationError):
            self._template(structure_json={"not": "a list"})

    def test_an_empty_structure_is_allowed_while_authoring(self):
        """A template is saved mid-authoring; empty is not yet an error."""
        tpl = self._template(structure_json=[])

        self.assertEqual(tpl.item_count, 0)
