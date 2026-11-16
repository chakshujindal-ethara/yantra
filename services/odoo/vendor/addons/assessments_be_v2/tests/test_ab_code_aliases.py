"""Our own vocabulary must not reject the model's correct answer key.

THE LIVE INCIDENT. Generator 175 ran against a "Text to Image Compare" SOP
whose axes are named "Instruction Following", "Visual Quality", "Less
AI-Generated" and "Overall Preference". The generation directive tells the
model to key construction_keys "by its short code", so it did exactly that and
returned, for all four items:

    {"IF": "Response A", "VQ": "Both Good",
     "LAIG": "Response A", "OP": "Response A"}

A complete, internally consistent answer key. `validate_flaw_plan` rejected
every one of them for "construction_keys must include an Overall Choice (OC)
dimension", because the alias table knew the PHRASE "overall preference" but
not the CODE `OP` the model derived from it - nor `LAIG` for `LAI`.

Four well-formed items were flagged unkeyed, and the report told the operator
the model had failed. It had not. This is the same class as the earlier
LAG/LAI mismatch: the platform's own vocabulary rejecting the platform's own
output.
"""
from odoo.tests.common import TransactionCase

from ..constants import (
    AB_OVERALL_CODE,
    ab_dimensions_from_keys,
    ab_normalize_dim_key,
)


class TestAbCodeAliases(TransactionCase):

    # ---- the exact payload from the live run -------------------------
    LIVE_KEYS = {"IF": "Response A", "VQ": "Both Good",
                 "LAIG": "Response A", "OP": "Response A"}

    def test_the_live_payload_resolves_an_overall_choice(self):
        codes = {code for code, _label in ab_dimensions_from_keys(self.LIVE_KEYS)}

        self.assertIn(
            AB_OVERALL_CODE, codes,
            "the model's own 'OP' (Overall Preference) is the decided "
            "preference; refusing to recognise it rejected four correct items")

    def test_the_live_payload_keeps_all_four_dimensions(self):
        dims = ab_dimensions_from_keys(self.LIVE_KEYS)

        self.assertEqual(
            len(dims), 4,
            "IF, VQ, LAI and OC - collapsing or dropping one would silently "
            "lose an axis the SOP asked to be rated")

    def test_the_live_payload_has_a_rating_dimension_besides_overall(self):
        """`validate_flaw_plan` also requires one NON-OC rating dimension."""
        codes = {code for code, _label in ab_dimensions_from_keys(self.LIVE_KEYS)}

        self.assertTrue(
            codes - {AB_OVERALL_CODE},
            "OC alone is not a gradeable plan")

    # ---- the individual aliases --------------------------------------
    def test_op_is_the_overall_choice(self):
        code, _label = ab_normalize_dim_key("OP")
        self.assertEqual(code, AB_OVERALL_CODE)

    def test_laig_is_less_ai_generated(self):
        code, _label = ab_normalize_dim_key("LAIG")
        self.assertEqual(code, "LAI")

    def test_aliases_are_case_insensitive(self):
        self.assertEqual(ab_normalize_dim_key("op")[0], AB_OVERALL_CODE)
        self.assertEqual(ab_normalize_dim_key("laig")[0], "LAI")

    # ---- no regression on what already worked ------------------------
    def test_the_canonical_codes_still_resolve_to_themselves(self):
        for code in ("IF", "VQ", "LAI", "OC", "IDP", "CP"):
            self.assertEqual(
                ab_normalize_dim_key(code)[0], code,
                "adding aliases must not disturb the canonical codes")

    def test_the_spelled_out_phrase_still_resolves(self):
        """The earlier fix mapped the PHRASE; it must keep working."""
        self.assertEqual(
            ab_normalize_dim_key("Overall Preference")[0], AB_OVERALL_CODE)

    def test_an_unknown_sop_dimension_is_still_kept_not_dropped(self):
        """Self-extending: a genuinely new axis survives and is humanized."""
        code, label = ab_normalize_dim_key("Brand Safety")

        self.assertTrue(code, "an unknown SOP dimension must not vanish")
        self.assertTrue(label, "and it must carry a readable label")
