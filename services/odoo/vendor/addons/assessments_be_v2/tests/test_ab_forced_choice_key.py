"""A forced-choice A/B dimension must not end up with an empty answer key.

WHAT WAS BROKEN. A SOP is free to narrow one dimension to two sides - "Which
image looks less AI-generated?" offers only Response A / Response B - while the
model deciding the answer key sees the DEFAULT four-way vocabulary and can answer
"Both Good". That verdict is unsayable on a two-option dimension, so
`ab_align_verdict_to_options` correctly found no equivalent and the dimension was
stored with `correct: []`.

The result reached the reviewer as "No correct option marked. This question would
score zero for every candidate", on a question whose ground truth was decided by
construction and was sitting in flaw_plan_json the whole time. Observed live: 3 of
6 image A/B drafts on generator 172, on that dimension only.

THE RULE. A forced choice between two sides has an answer available - the side
this sitting already decided on overall - so fall back to the Overall Choice pick
rather than discarding the key. A dimension that genuinely offers "Both Good"
keeps it, and if OC itself is unusable the empty key stands, because then there
really is nothing to infer.
"""
from odoo.tests.common import TransactionCase

from ..constants import ab_specs_from_construction_keys


def _by_label(specs):
    return {s["label"]: s for s in specs}


class TestAbForcedChoiceKey(TransactionCase):

    # Draft 79's real payload, copied off the wire.
    KEYS = {"IF": "Response A", "VQ": "Both Good",
            "LAG": "Both Good", "OC": "Response A"}
    OPTIONS = {
        "IF": ["Response A", "Response B", "Both Good", "Both Bad"],
        "VQ": ["Response A", "Response B", "Both Good", "Both Bad"],
        "LAG": ["Response A", "Response B"],
        "OP": ["Response A", "Response B"],
    }
    LABELS = {"LAG": "Which image looks less AI-generated?"}

    def test_a_both_verdict_on_a_two_option_dimension_takes_the_overall_pick(self):
        specs = _by_label(ab_specs_from_construction_keys(
            self.KEYS, self.OPTIONS, self.LABELS))
        lag = next(s for label, s in specs.items() if "less AI-generated" in label)

        self.assertEqual(
            lag["options"], ["Response A", "Response B"],
            "the SOP's own two-option vocabulary is kept")
        self.assertEqual(
            lag["correct"], ["Response A"],
            "unmarked before this fix; the Overall Choice pick is the answer a "
            "forced choice between the same two sides already has")

    def test_a_dimension_that_really_offers_both_good_keeps_it(self):
        """The fallback must not overwrite a verdict that was already sayable."""
        specs = _by_label(ab_specs_from_construction_keys(
            self.KEYS, self.OPTIONS, self.LABELS))

        self.assertEqual(specs["Visual Quality (VQ)"]["correct"], ["Both Good"])
        self.assertEqual(
            specs["Instruction Following (IF)"]["correct"], ["Response A"])

    def test_no_usable_overall_choice_leaves_the_key_empty(self):
        """Then there is genuinely nothing to infer, and the warning is right.

        Silently inventing a side here would be worse than the empty key: it
        would key the question to a guess while the UI reported all clear.
        """
        keys = {"LAG": "Both Good", "OC": "Both Bad"}
        specs = ab_specs_from_construction_keys(
            keys, {"LAG": ["Response A", "Response B"]}, self.LABELS)
        lag = next(s for s in specs if "less AI-generated" in s["label"])

        self.assertEqual(
            lag["correct"], [],
            "an Overall Choice that is itself not a side cannot resolve a "
            "forced choice")

    def test_tie_resolves_the_same_way_as_both_good(self):
        """"Tie" is the same refusal to pick wearing a different name."""
        keys = {"LAG": "Tie", "OC": "Response B"}
        specs = ab_specs_from_construction_keys(
            keys, {"LAG": ["Response A", "Response B"]}, self.LABELS)
        lag = next(s for s in specs if "less AI-generated" in s["label"])

        self.assertEqual(lag["correct"], ["Response B"])

    def test_every_dimension_of_the_live_draft_ends_up_keyed(self):
        """The whole point: no dimension left for the reviewer to fix by hand."""
        specs = ab_specs_from_construction_keys(
            self.KEYS, self.OPTIONS, self.LABELS)

        unkeyed = [s["label"] for s in specs if not s["correct"]]
        self.assertEqual(
            unkeyed, [],
            "a draft whose keys were all decided by construction must not "
            "reach review with an unmarked dimension")
