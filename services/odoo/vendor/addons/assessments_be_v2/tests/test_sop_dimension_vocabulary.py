"""A SOP is allowed its own words for the dimensions it rates.

THE DEFECT. `validate_flaw_plan` requires an Overall Choice (OC) dimension, and
the generation directive orders the model to emit THIS SOP's dimension names
verbatim into `construction_keys`. A live SOP ("Text to Image Compare") calls its
final axis "Overall Preference" and offers "Image A / Image B / Tie", so the
model did as it was told, nothing resolved to OC, and every image_ab item was
rejected. The run reported "Done", created zero drafts, and charged for the call.
Five items out of five, deterministically - the platform's own vocabulary was
rejecting the platform's own output.

Nothing covered any of this: not `ab_normalize_dim_key`, not `validate_flaw_plan`,
not the rating-scheme normaliser. These tests pin the three joins where the two
vocabularies meet.
"""
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.constants import (
    ab_normalize_dim_key,
    ab_normalize_verdict,
    normalize_flaw_plan,
    validate_flaw_plan,
)
from odoo.addons.assessments_be_v2.services import vertex


def _plan(construction_keys):
    """A well-formed one-side-flawed plan, varying only the keys under test."""
    return {
        "faithful_side": "a",
        "worker_prompt": "A red bicycle leaning on a blue wall",
        "render_prompts": {
            "a": "A red bicycle leaning on a blue wall",
            "b": "A red bicycle with three wheels leaning on a blue wall",
        },
        "planted": {"a": [], "b": ["the bicycle has three wheels"]},
        "construction_keys": construction_keys,
    }


@tagged("-at_install", "post_install")
class TestSopDimensionVocabulary(TransactionCase):

    # The exact scheme extracted from the live "Text to Image Compare" SOP.
    LIVE_SOP_KEYS = {
        "INSTRUCTION FOLLOWING": "Response A",
        "VISUAL QUALITY": "Both Good",
        "LESS AI-GENERATED": "Response A",
        "OVERALL PREFERENCE": "Response A",
    }

    # ------------------------------------------------------------------
    # The dimension name
    # ------------------------------------------------------------------
    def test_the_sops_own_name_for_the_overall_axis_resolves_to_oc(self):
        for spelling in ("OVERALL PREFERENCE", "Overall Preference",
                         "overall_preference", "Overall Pick",
                         "Which response do you prefer overall?"):
            with self.subTest(spelling=spelling):
                code, _label = ab_normalize_dim_key(spelling)
                self.assertEqual(
                    code, "OC",
                    "the SOP is told to use its own dimension names and then "
                    "rejected for doing so")

    def test_an_unknown_sop_dimension_is_still_kept_not_forced(self):
        """The registry is self-extending, and must stay that way.

        A fix that mapped everything onto the six canonical codes would break
        the independent-questions SOPs, whose dimensions are Q1/Q2/Q3.
        """
        for spelling in ("Q1", "Edge Fidelity", "Colour Accuracy"):
            with self.subTest(spelling=spelling):
                code, label = ab_normalize_dim_key(spelling)
                self.assertNotEqual(code, "OC")
                self.assertTrue(code and label)

    # ------------------------------------------------------------------
    # The verdict words
    # ------------------------------------------------------------------
    def test_the_sops_verdict_words_map_onto_the_scoring_vocabulary(self):
        self.assertEqual(ab_normalize_verdict("Image A"), "Response A")
        self.assertEqual(ab_normalize_verdict("Image B"), "Response B")
        self.assertEqual(ab_normalize_verdict("Tie"), "Both Good")

    def test_a_custom_answer_set_is_never_rewritten(self):
        """YES/NO is not an A/B pick. Rewriting one moves an answer key."""
        for verdict in ("YES", "NO", "Pass", "Sharper edges"):
            with self.subTest(verdict=verdict):
                self.assertEqual(ab_normalize_verdict(verdict), verdict)

    # ------------------------------------------------------------------
    # The plan the generator actually emits
    # ------------------------------------------------------------------
    def test_the_live_sops_plan_now_validates(self):
        """The reported failure, end to end. This returned the OC error."""
        self.assertEqual(
            validate_flaw_plan(_plan(self.LIVE_SOP_KEYS)), [],
            "an image_ab item authored against this SOP was rejected for "
            "missing OC, which the SOP calls 'Overall Preference'")

    def test_sop_wording_and_canonical_codes_normalise_identically(self):
        """Two spellings of one answer key must not become two answer keys."""
        sop = normalize_flaw_plan(_plan(self.LIVE_SOP_KEYS))
        canonical = normalize_flaw_plan(_plan({
            "IF": "Response A", "VQ": "Both Good",
            "LAI": "Response A", "OC": "Response A"}))

        self.assertEqual(sop["construction_keys"],
                         canonical["construction_keys"])

    def test_the_sops_verdict_words_survive_the_whole_plan(self):
        """'Image A' verdicts used to be read as a CUSTOM-OPTIONS plan.

        That reclassification is the quiet half of this defect: a two-response
        A/B silently graded as an independent-questions eval, which skips both
        the OC requirement and the planted-flaw checks.
        """
        plan = _plan({
            "INSTRUCTION FOLLOWING": "Image A", "VISUAL QUALITY": "Tie",
            "LESS AI-GENERATED": "Image A", "OVERALL PREFERENCE": "Image A"})
        norm = normalize_flaw_plan(plan)

        self.assertEqual(norm["construction_keys"]["OC"], "Response A")
        self.assertEqual(norm["construction_keys"]["VQ"], "Both Good")
        self.assertFalse(
            norm["dimension_options"],
            "the SOP's A/B wording was mistaken for a custom answer set")
        self.assertEqual(validate_flaw_plan(plan), [])

    def test_a_genuinely_missing_overall_axis_is_still_rejected(self):
        """The requirement itself stands. An A/B with no pick has no answer."""
        errs = validate_flaw_plan(_plan({
            "INSTRUCTION FOLLOWING": "Response A",
            "VISUAL QUALITY": "Both Good"}))

        self.assertTrue(any("Overall Choice" in e for e in errs), errs)

    # ------------------------------------------------------------------
    # What gets stored, and therefore what the model is told next time
    # ------------------------------------------------------------------
    def test_the_stored_scheme_carries_canonical_codes(self):
        """The root cause: the extractor persisted the SOP's wording as the CODE,
        and `_rating_scheme_note` then orders the model to emit it verbatim."""
        scheme = vertex._normalize_rating_scheme({
            "kind": "preference_comparison",
            "dimensions": [
                {"code": "OVERALL PREFERENCE",
                 "label": "Which response do you prefer overall?",
                 "options": ["Image A", "Image B", "Tie"]},
            ],
        })
        dim = scheme["dimensions"][0]

        self.assertEqual(dim["code"], "OC")
        self.assertEqual(
            dim["label"], "Which response do you prefer overall?",
            "the SOP's own wording is what a reviewer reads; only the machine "
            "value is canonicalised")
        self.assertEqual(
            dim["options"], ["Response A", "Response B"],
            "the SOP lists 'Tie' against its overall axis, which normalises to "
            "Both Good - advertising that back to the model would invite an "
            "undecided Overall Choice, and an A/B with no pick has no key")

    def test_tie_is_never_offered_on_any_dimension(self):
        """A comparison task asks for a decision. Tie is the answer that avoids
        making one, so it is dropped from every advertised option list."""
        scheme = vertex._normalize_rating_scheme({
            "kind": "preference_comparison",
            "dimensions": [
                {"code": "LESS AI-GENERATED",
                 "label": "Which response looks less AI-generated?",
                 "options": ["Image A", "Image B", "Tie"]},
            ],
        })

        self.assertEqual(scheme["dimensions"][0]["code"], "LAI")
        self.assertEqual(scheme["dimensions"][0]["options"],
                         ["Response A", "Response B"])

    def test_a_sop_that_really_means_both_good_keeps_it(self):
        """Tie is dropped at the SOURCE, so the mapping cannot reintroduce it -
        but a SOP that names Both Good itself is saying something different."""
        scheme = vertex._normalize_rating_scheme({
            "kind": "preference_comparison",
            "dimensions": [
                {"code": "VISUAL QUALITY", "label": "Which looks better?",
                 "options": ["Image A", "Image B", "Both Good", "Both Bad"]},
            ],
        })

        self.assertEqual(
            scheme["dimensions"][0]["options"],
            ["Response A", "Response B", "Both Good", "Both Bad"])

    def test_a_stray_tie_verdict_still_resolves_rather_than_corrupting(self):
        """Dropping Tie from the OPTIONS is not the same as un-teaching it.

        An unrecognised verdict on a rating dimension makes the plan invent a
        custom answer set, which exempts the WHOLE plan from the Overall Choice
        requirement and the planted-flaw checks. A model that emits a tie anyway
        must not be able to do that.
        """
        plan = _plan({
            "INSTRUCTION FOLLOWING": "Image A", "VISUAL QUALITY": "Tie",
            "LESS AI-GENERATED": "Image A", "OVERALL PREFERENCE": "Image A"})
        norm = normalize_flaw_plan(plan)

        self.assertEqual(norm["construction_keys"]["VQ"], "Both Good")
        self.assertFalse(norm["dimension_options"])

    def test_an_independent_questions_scheme_keeps_its_answer_set(self):
        scheme = vertex._normalize_rating_scheme({
            "kind": "independent_questions",
            "dimensions": [
                {"code": "Q1", "label": "Do you know this Application?",
                 "options": ["Yes", "No"]},
            ],
        })

        self.assertEqual(scheme["dimensions"][0]["options"], ["Yes", "No"])
