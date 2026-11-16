"""A hand-authored template's axis wording reaches the candidate.

THE DEFECT. The generation directive already tells the model that a task
template's axes "outrank anything you would infer from the SOP prose" - but
when the answer key was BUILT, `_infer_dimension_labels` did
`labels.update(sop_labels)` unconditionally. So an examiner who authored
"Which image better follows the prompt?" watched the SOP's short name
"Instruction Following" overwrite it, and the stored dimension - the one a
candidate reads and a grader marks against - said "Instruction Following (IF)".

Verified live: a run against the T2I template produced four correctly-keyed
dimensions, every one of them labelled with the SOP's short name rather than
the examiner's own question. The template was authored, saved, chosen, and
then silently stopped meaning anything at the last step.
"""
from odoo.tests.common import TransactionCase

from ..services.vertex import (
    _infer_dimension_labels,
    _template_dimension_labels,
)

# The T2I template's real axes, in its own order.
AXES = [
    "Which image do you prefer overall?",
    "Which image better follows the prompt?",
    "Which image has better visual quality?",
    "Which image looks less AI-generated?",
]

# What the model actually returned as construction_keys, using its own codes.
LIVE_KEYS = {"IF": "Response A", "VQ": "Response B",
             "LAIG": "Response B", "OP": "Response A"}


def _spec(axes=AXES):
    return {"task": {"answer_contract": {
        "dimensions": [{"label": a, "options": ["Image A", "Image B"]}
                       for a in axes]}}}


class TestTemplateLabelsWin(TransactionCase):

    # ---- pairing axes to codes ---------------------------------------
    def test_each_axis_is_paired_with_its_code(self):
        out = _template_dimension_labels(_spec(), LIVE_KEYS)

        self.assertEqual(out.get("IF"), "Which image better follows the prompt?")
        self.assertEqual(out.get("VQ"), "Which image has better visual quality?")
        self.assertEqual(out.get("LAI"), "Which image looks less AI-generated?")
        self.assertEqual(out.get("OC"), "Which image do you prefer overall?")

    def test_no_template_pairs_nothing(self):
        self.assertEqual(_template_dimension_labels(None, LIVE_KEYS), {})

    def test_no_keys_pairs_nothing(self):
        self.assertEqual(_template_dimension_labels(_spec(), {}), {})

    def test_an_axis_naming_no_known_code_is_left_alone(self):
        """NOT guessed at by position.

        The first version of this paired leftover axes against leftover codes
        positionally, which read as helpful and was actively dangerous: the
        T2I template orders its axes [Overall, IF, VQ, LAI] while the model
        returned keys [IF, VQ, LAIG, OP], so zipping produced a complete,
        confident, entirely mislabelled answer key - the overall-preference
        axis presented to the candidate as "Instruction Following".

        A missing label falls back to the canonical name, which is merely
        terse. A WRONG label is a lie about what the candidate was asked, so
        an axis that resolves to no known code contributes nothing.
        """
        out = _template_dimension_labels(
            _spec(["Brand safety of the output", "Which do you prefer overall?"]),
            {"BRANDSAFE": "Response A", "OP": "Response B"})

        self.assertEqual(
            out.get("OC"), "Which do you prefer overall?",
            "an axis whose wording names a known dimension is still matched")
        self.assertNotIn(
            "BRANDSAFE", out,
            "a SOP-specific axis with no recognised meaning must not be "
            "guessed onto whichever code happens to be left over")

    # ---- precedence ---------------------------------------------------
    def test_the_template_beats_the_models_own_label(self):
        labels = _infer_dimension_labels(
            self.env, {"IF": "Instruction Following"}, LIVE_KEYS,
            prompt_record=None,
            template_labels={"IF": "Which image better follows the prompt?"})

        self.assertEqual(
            labels["IF"], "Which image better follows the prompt?",
            "the examiner authored this by hand; it outranks a model guess")

    def test_without_a_template_nothing_changes(self):
        """No regression for every generator that uses no template."""
        labels = _infer_dimension_labels(
            self.env, {"IF": "Instruction Following"}, LIVE_KEYS,
            prompt_record=None, template_labels=None)

        self.assertEqual(labels["IF"], "Instruction Following")

    def test_an_axis_the_template_does_not_name_keeps_its_label(self):
        labels = _infer_dimension_labels(
            self.env,
            {"IF": "Instruction Following", "VQ": "Visual Quality"},
            LIVE_KEYS, prompt_record=None,
            template_labels={"IF": "Which image better follows the prompt?"})

        self.assertEqual(labels["IF"], "Which image better follows the prompt?")
        self.assertEqual(
            labels["VQ"], "Visual Quality",
            "a template that names only some axes must not blank the rest")
