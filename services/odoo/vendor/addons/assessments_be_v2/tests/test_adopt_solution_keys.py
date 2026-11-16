"""An answer key filed in the wrong field is recovered, not thrown away.

THE LIVE INCIDENT. A run against the T2I template returned two image_ab items
whose `solution` carried a complete, coherent key - IF/VQ/LAIG/OP plus a
justification naming the exact planted flaws ("a sixth finger", "a misspelled
title") - while `flaw_plan` came back with no `construction_keys` at all.
`validate_flaw_plan` rejected both, the whole key was discarded, and the drafts
landed unkeyed and ungradeable with "construction_keys must include an Overall
Choice (OC) dimension".

The model had done the work. We threw it away over which field it landed in.

This pins the repair AND its limits: it must never invent a key that is absent
everywhere, and must never adopt free text as a dimension.
"""
from odoo.tests.common import TransactionCase

from ..constants import validate_flaw_plan
from ..services.vertex import _adopt_solution_keys

# Draft 136's real solution, verbatim from the run.
LIVE_SOLUTION = {
    "IF": "Both Bad",
    "VQ": "Response A",
    "LAIG": "Response A",
    "OP": "Response A",
    "justification": (
        "Both images have issues, but Response A is preferred because the "
        "anatomical error in Response B (a sixth finger) is a much more "
        "significant and distracting flaw than the misspelled title."),
}


def _item(solution=None, keys=None, plan=True):
    # `IF: Both Bad` makes this a BOTH-flawed plan, so the validator rightly
    # wants planted flaws on both sides - mirror the live payload, which had
    # them, or the fixture fails for a reason unrelated to key recovery.
    plan_obj = {} if not plan else {
        "flawed_side": "both",
        "worker_prompt": "A person holding an open book.",
        "render_prompts": {"a": "...", "b": "..."},
        "planted": {"a": ["A misspelled title on the book cover."],
                    "b": ["A sixth finger on the visible hand."]},
    }
    if plan and keys is not None:
        plan_obj["construction_keys"] = keys
    it = {"prompt": "Compare the two images.",
          "image_specs": {"flaw_plan": plan_obj} if plan else {}}
    if solution is not None:
        it["solution"] = solution
    return it


class TestAdoptSolutionKeys(TransactionCase):

    # ---- the recovery -------------------------------------------------
    def test_the_key_is_recovered_from_solution(self):
        it = _item(solution=LIVE_SOLUTION)

        self.assertTrue(_adopt_solution_keys(it))

        keys = it["image_specs"]["flaw_plan"]["construction_keys"]
        self.assertEqual(keys.get("IF"), "Both Bad")
        self.assertEqual(keys.get("VQ"), "Response A")

    def test_the_models_own_codes_are_normalised(self):
        """LAIG -> LAI and OP -> OC, through the shared registry."""
        it = _item(solution=LIVE_SOLUTION)
        _adopt_solution_keys(it)
        keys = it["image_specs"]["flaw_plan"]["construction_keys"]

        self.assertIn("LAI", keys, "LAIG must normalise to the canonical LAI")
        self.assertIn("OC", keys, "OP must normalise to the canonical OC")
        self.assertNotIn("LAIG", keys)
        self.assertNotIn("OP", keys)

    def test_the_recovered_plan_now_passes_validation(self):
        """The whole point: the draft becomes gradeable."""
        it = _item(solution=LIVE_SOLUTION)
        plan = it["image_specs"]["flaw_plan"]
        self.assertTrue(validate_flaw_plan(plan),
                        "precondition: the plan is rejected without keys")

        _adopt_solution_keys(it)

        self.assertFalse(
            validate_flaw_plan(it["image_specs"]["flaw_plan"]),
            "with the key recovered the plan must be accepted")

    def test_free_text_is_never_adopted_as_a_dimension(self):
        it = _item(solution=LIVE_SOLUTION)
        _adopt_solution_keys(it)
        keys = it["image_specs"]["flaw_plan"]["construction_keys"]

        self.assertNotIn("JUSTIFICATION", keys)
        for verdict in keys.values():
            self.assertLess(len(verdict), 40,
                            "a dimension verdict, not a paragraph")

    # ---- the limits ---------------------------------------------------
    def test_an_existing_key_is_never_overwritten(self):
        it = _item(solution=LIVE_SOLUTION, keys={"IF": "Response B"})

        self.assertFalse(_adopt_solution_keys(it))
        self.assertEqual(
            it["image_specs"]["flaw_plan"]["construction_keys"],
            {"IF": "Response B"})

    def test_nothing_is_invented_when_there_is_no_solution(self):
        it = _item(solution=None)

        self.assertFalse(_adopt_solution_keys(it))
        self.assertNotIn("construction_keys", it["image_specs"]["flaw_plan"])

    def test_a_solution_with_no_verdicts_recovers_nothing(self):
        it = _item(solution={"justification": "Some prose.", "notes": "More."})

        self.assertFalse(_adopt_solution_keys(it))

    def test_no_plan_means_no_repair(self):
        """A key is only meaningful alongside a plan that plants the flaws."""
        it = _item(solution=LIVE_SOLUTION, plan=False)

        self.assertFalse(_adopt_solution_keys(it))
