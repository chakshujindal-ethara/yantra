"""An examiner's axis wording reaches the candidate as WRITTEN.

THE DEFECT. `ab_normalize_dim_key` returns an upper-cased code for an unknown
dimension, and the display label followed it. That is right for a real code
(`OP`, `LAIG`) but a task template's axis is a whole sentence, so a live
generation run produced dimensions reading "WAS THE INSTRUCTION APPLIED?" -
the exam shouting at the candidate.
"""
from odoo.tests.common import TransactionCase

from ..constants import ab_normalize_dim_key, ab_dimension_display_label


class TestAxisWordingCasing(TransactionCase):

    def test_a_sentence_axis_keeps_its_casing(self):
        code, label = ab_normalize_dim_key("Was the instruction applied?")

        self.assertEqual(label, "Was the instruction applied?")
        self.assertNotEqual(label, label.upper())

    def test_the_code_is_still_a_code(self):
        """Upper-casing the CODE is correct - it is the lookup key."""
        code, _label = ab_normalize_dim_key("Was the instruction applied?")

        self.assertEqual(code, "WAS THE INSTRUCTION APPLIED?")

    def test_a_short_code_is_still_humanized(self):
        """The existing behaviour for real codes must not regress."""
        _code, label = ab_normalize_dim_key("edge_fidelity")

        self.assertEqual(label, "Edge Fidelity")

    def test_known_codes_are_untouched(self):
        for raw, expected in (("OP", "Overall Choice"),
                              ("LAIG", "Less AI Generated")):
            _code, label = ab_normalize_dim_key(raw)
            self.assertEqual(label, expected)

    def test_display_label_prefers_the_examiners_wording(self):
        self.assertEqual(
            ab_dimension_display_label("WAS THE INSTRUCTION APPLIED?",
                                       "Was the instruction applied?"),
            "Was the instruction applied?")
