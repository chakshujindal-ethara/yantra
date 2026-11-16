"""A template must state whether the generator can reproduce its shape.

WHAT "USABLE" MEANS HERE - AND THE ASSUMPTION THAT WAS WRONG. An earlier
version of this file asserted that a choice question with NO CORRECT OPTION
MARKED was "not usable", because `usable_count` ran the template through Form
Studio's PUBLISH validator. That was the wrong instrument, and the tests below
originally encoded the mistake:

A REUSABLE TEMPLATE DELIBERATELY HAS NO ANSWER KEY. It describes a SHAPE - the
axes and their options - and the key belongs to each GENERATED INSTANCE, which
is generation's job to supply. Judging a template by the publish rules
reported four of six live templates as broken when the only thing "wrong" with
them was being templates, and it dropped every axis out of `answer_contract()`
so the model was told nothing about them and wrote generic items instead.

What genuinely cannot be generated from is an item with NO SHAPE: a choice
question with fewer than two options, or an item with no title. That - and
only that - is what `usable_count` counts out.
"""
from odoo.tests.common import TransactionCase


def _choice_item(item_id, title, correct_index=None, options=2):
    """One multipleChoice item; `correct_index=None` leaves it UNKEYED, which
    is the NORMAL state for a template."""
    return {
        "id": item_id,
        "kind": "multipleChoice",
        "title": title,
        "options": [
            {"id": "%s-%d" % (item_id, i), "label": "Option %d" % (i + 1),
             "correct": correct_index == i}
            for i in range(options)
        ],
    }


def _para(item_id, title):
    return {"id": item_id, "kind": "paragraph", "title": title}


class TestTemplateUsableCount(TransactionCase):

    def _template(self, items, **kw):
        return self.env["assessments.be.task.template"].create(dict({
            "name": "T",
            "response": "single_choice",
            "structure_json": [{"id": "s1", "title": "Questions",
                                "items": items}],
        }, **kw))

    # ------------------------------------------------------------------
    def test_an_unkeyed_template_is_fully_usable(self):
        """THE CORRECTED EXPECTATION. No answer key is the normal, correct
        state of a template - supplying one per instance is generation's job.
        Counting these as broken is what made four of six live templates
        report as unusable."""
        tpl = self._template([
            _choice_item("q1", "Which image better follows the prompt?"),
            _choice_item("q2", "Which image has better visual quality?"),
            _para("q3", "Justification"),
        ])

        self.assertEqual(tpl.item_count, 3)
        self.assertEqual(
            tpl.usable_count, 3,
            "every item has a title and a real shape; none needs a key here")

    def test_a_keyed_template_is_also_fully_usable(self):
        """An examiner MAY key a template; it must not change the count."""
        tpl = self._template([
            _choice_item("q1", "Which follows the prompt?", correct_index=0),
            _choice_item("q2", "Which looks better?", correct_index=1),
        ])

        self.assertEqual(tpl.usable_count, 2)

    def test_a_choice_question_with_one_option_is_not_usable(self):
        """A single-option choice has no shape to reproduce."""
        tpl = self._template([
            _choice_item("q1", "Which is better?", options=1),
            _choice_item("q2", "Which follows the prompt?", options=3),
        ])

        self.assertEqual(tpl.item_count, 2)
        self.assertEqual(
            tpl.usable_count, 1,
            "an axis offering one choice is not an axis")

    def test_an_untitled_item_is_not_usable(self):
        """The title IS the axis name the generator is told to reproduce."""
        tpl = self._template([
            _choice_item("q1", ""),
            _choice_item("q2", "Which follows the prompt?"),
        ])

        self.assertEqual(tpl.usable_count, 1)

    def test_the_count_follows_an_edit(self):
        tpl = self._template([_choice_item("q1", "Which is better?", options=1)])
        self.assertEqual(tpl.usable_count, 0)

        tpl.structure_json = [{
            "id": "s1", "title": "Questions",
            "items": [_choice_item("q1", "Which is better?", options=4)],
        }]

        self.assertEqual(
            tpl.usable_count, 1,
            "usable_count depends on structure_json and must recompute")

    def test_an_empty_template_is_not_reported_as_broken(self):
        tpl = self._template([])

        self.assertEqual(tpl.item_count, 0)
        self.assertEqual(tpl.usable_count, 0)

    # ---- the contract the generator is actually handed ----------------
    def test_the_contract_carries_the_authored_axis_NAMES(self):
        """THE DEFECT THIS PINS. `_item_spec` names every choice dimension
        "Answer", so a template's four distinct axes reached the model as four
        axes all called "Answer" - option lists with no idea which was
        Instruction Following and which was Visual Quality."""
        tpl = self._template([
            _choice_item("q1", "Which image better follows the prompt?"),
            _choice_item("q2", "Which image has better visual quality?"),
        ])

        dims = tpl.answer_contract().get("dimensions") or []

        self.assertEqual(len(dims), 2)
        self.assertEqual(
            [d["label"] for d in dims],
            ["Which image better follows the prompt?",
             "Which image has better visual quality?"],
            "the examiner's own wording is the axis name")

    def test_the_contract_keeps_each_axis_OWN_options(self):
        """Asymmetric option sets are the whole point - normalising them to a
        common list recreates the generic-scale bug this feature removes."""
        tpl = self._template([
            _choice_item("q1", "Follows the prompt?", options=4),
            _choice_item("q2", "Less AI-generated?", options=3),
        ])

        dims = tpl.answer_contract()["dimensions"]

        self.assertEqual(len(dims[0]["options"]), 4)
        self.assertEqual(len(dims[1]["options"]), 3)

    def test_a_free_text_item_is_not_an_axis(self):
        """A justification is part of the response, not a dimension to rate."""
        tpl = self._template([
            _para("q0", "Justification"),
            _choice_item("q1", "Which image follows the prompt?"),
        ])

        dims = tpl.answer_contract()["dimensions"]

        self.assertEqual(len(dims), 1)
        self.assertEqual(dims[0]["label"], "Which image follows the prompt?")

    def test_the_summary_names_the_JUDGED_question(self):
        tpl = self._template([
            _para("q0", "Justification"),
            _choice_item("q1", "Which image follows the prompt?"),
        ])

        summary = tpl.shape_summary()

        self.assertIn("Which image follows the prompt?", summary)
        self.assertNotIn(
            "Justification", summary,
            "the justification is boilerplate every A/B template shares")
