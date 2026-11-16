"""A scale, a rating and a grid must reach the generator as axes.

Form Studio does not write these kinds as an `options` array: a scale carries
scale_min/scale_max, a rating carries rating_max, and a grid's shared choices
live in `columns` (see form_models.dart toJson). Reading only `options` sent
all four to the generator as ZERO axes, so a 1-5 rating drawn in the designer
silently vanished from the contract.

These use the REAL wire format the frontend emits, not a hand-written shape.
"""
from odoo.tests.common import TransactionCase


class TestFormStudioWireFormatAxes(TransactionCase):

    def _tpl(self, item):
        return self.env["assessments.be.task.template"].create({
            "name": "wire format probe",
            "structure_json": [{"id": "s", "items": [item]}],
        })

    def test_linear_scale_becomes_an_axis(self):
        t = self._tpl({"id": "i", "kind": "linearScale", "title": "Confidence",
                       "scale_min": 1, "scale_max": 5,
                       "scale_min_label": "Unsure", "scale_max_label": "Certain"})
        axes = t._axes()
        self.assertEqual(len(axes), 1)
        self.assertEqual(axes[0]["options"], ["1", "2", "3", "4", "5"])
        self.assertEqual(axes[0]["kind"], "linearScale")

    def test_rating_becomes_an_axis(self):
        t = self._tpl({"id": "i", "kind": "rating", "title": "Quality",
                       "rating_max": 5})
        axes = t._axes()
        self.assertEqual(len(axes), 1)
        self.assertEqual(axes[0]["options"], ["1", "2", "3", "4", "5"])

    def test_choice_grid_yields_one_axis_per_row(self):
        t = self._tpl({"id": "i", "kind": "choiceGrid", "title": "Regions",
                       "rows": ["Foreground", "Background"],
                       "columns": ["Clean", "Suspect"]})
        axes = t._axes()
        self.assertEqual(len(axes), 2)
        for a in axes:
            self.assertEqual(a["options"], ["Clean", "Suspect"])
        self.assertIn("Foreground", axes[0]["label"])

    def test_checkbox_grid_yields_one_axis_per_row(self):
        t = self._tpl({"id": "i", "kind": "checkboxGrid", "title": "Tells",
                       "rows": ["Hands", "Signage"],
                       "columns": ["Present", "Ambiguous"]})
        self.assertEqual(len(t._axes()), 2)

    def test_explicit_options_still_win(self):
        """A kind that DOES carry options keeps using them."""
        t = self._tpl({"id": "i", "kind": "multipleChoice", "title": "Tell?",
                       "options": [{"id": "y", "label": "Yes"},
                                   {"id": "n", "label": "No"}]})
        self.assertEqual(t._axes()[0]["options"], ["Yes", "No"])

    def test_free_text_is_never_an_axis(self):
        t = self._tpl({"id": "i", "kind": "paragraph", "title": "Explain"})
        self.assertEqual(t._axes(), [])

    def test_an_absurd_scale_is_refused(self):
        """A scale nobody could answer is not silently turned into 500 axes."""
        t = self._tpl({"id": "i", "kind": "linearScale", "title": "Huge",
                       "scale_min": 1, "scale_max": 5000})
        self.assertEqual(t._axes(), [])

    def test_a_whole_form_keeps_every_authored_kind(self):
        items = [
            {"id": "a", "kind": "multipleChoice", "title": "Tell?",
             "options": [{"id": "y", "label": "Yes"}, {"id": "n", "label": "No"}]},
            {"id": "b", "kind": "linearScale", "title": "Confidence",
             "scale_min": 1, "scale_max": 5},
            {"id": "c", "kind": "rating", "title": "Quality", "rating_max": 5},
            {"id": "d", "kind": "choiceGrid", "title": "Regions",
             "rows": ["Fore", "Back"], "columns": ["Clean", "Suspect"]},
        ]
        t = self.env["assessments.be.task.template"].create({
            "name": "whole form",
            "structure_json": [{"id": "s", "items": items}],
        })
        kinds = {a["kind"] for a in t._axes()}
        self.assertEqual(
            kinds, {"multipleChoice", "linearScale", "rating", "choiceGrid"},
            "a kind the designer drew never reached the generator")
