"""What the generation directive says TODAY, pinned before quotas exist.

WHY THIS FILE COMES FIRST. Generation is the most expensive path in the product:
every real run costs money and takes minutes, so a prompt regression is
discovered by a paid run rather than a free test. The quota work generalises the
type-coverage stage, which means it edits the exact functions that decide what
the model is asked for. These tests capture the CURRENT contract so that
generalisation cannot quietly change it.

They are deliberately about wording and structure, not quality: the claim is
"the directive still asks for the same things", not "the directive is good".
"""
from odoo.tests.common import TransactionCase

from ..services.vertex import (
    _allowed_types_directive,
    _forced_type_directive,
    _missing_allowed_types,
    _trim_preserving_type_coverage,
)


class TestGenerationDirectiveToday(TransactionCase):

    THREE = ("mcq", "subjective_rubric", "image_ab")

    # -------------------------------------------------------- the directive

    def test_a_multi_type_directive_asks_for_the_total_and_one_each(self):
        """Today's contract: an approximate TOTAL plus a one-per-type floor.

        There is no per-type count anywhere in this string - that absence is
        exactly what the quota work adds, so pin it now.
        """
        d = _allowed_types_directive(self.THREE, 6)

        self.assertIn("approximately 6 question(s)", d)
        self.assertIn("AT LEAST ONE item for EVERY", d)
        for qtype in self.THREE:
            self.assertIn('"%s"' % qtype, d)

    def test_a_single_allowed_type_uses_the_forced_directive(self):
        """One selected type takes a different path; keep both intact."""
        single = _allowed_types_directive(("mcq",), 4)
        forced = _forced_type_directive("mcq", 4)

        self.assertEqual(single, forced,
                         "one allowed type must delegate to the forced form")

    def test_a_zero_count_omits_the_count_clause(self):
        """`auto` mode: the model decides how many, so no number is stated."""
        d = _allowed_types_directive(self.THREE, 0)

        self.assertNotIn("approximately", d)
        self.assertIn("AT LEAST ONE item for EVERY", d)

    def test_the_directive_forbids_types_outside_the_allow_list(self):
        d = _allowed_types_directive(self.THREE, 6)

        self.assertIn("DISCARDED", d)
        self.assertIn("Return ONLY a JSON array", d)

    # ------------------------------------------------------ coverage helpers
    #
    # Coverage is measured on items that would actually PERSIST: an item counts
    # for its type only if it resolves in-list AND passes that type's validator.
    # A bare {"question_type": "mcq"} therefore does NOT count - it has no
    # options and would be dropped at create. That is deliberate (a malformed
    # image_ab must not mask the image_ab gap), so these fixtures are VALID
    # items, not stubs.

    @staticmethod
    def _mcq(name="m"):
        return {"question_type": "mcq", "name": name, "prompt": name,
                "options": ["Yes", "No"], "correct_answer": "Yes"}

    @staticmethod
    def _rubric(name="s"):
        # The validator's own words: subjective_rubric needs
        # rubric {checklist, constraints, pass_condition}. Asked it directly
        # rather than inferring the contract from the validator source.
        return {"question_type": "subjective_rubric", "name": name,
                "prompt": name,
                "rubric": {"checklist": ["names the defect"],
                           "constraints": ["one paragraph"],
                           "pass_condition": "names both defects"}}

    def test_missing_types_are_reported_in_allow_list_order(self):
        missing = _missing_allowed_types(self.THREE, [self._mcq()])

        self.assertEqual(missing, ["subjective_rubric", "image_ab"],
                         "order is the admin's allow-list order")

    def test_an_item_that_would_be_dropped_does_not_mask_its_gap(self):
        """A malformed mcq must still leave mcq reported as missing.

        Without this the coverage fill would never fire for a type whose only
        representative is invalid - the gap would look closed while the batch
        shipped without that type.
        """
        missing = _missing_allowed_types(("mcq",), [{"question_type": "mcq"}])

        self.assertEqual(missing, ["mcq"])

    def test_nothing_is_missing_once_every_valid_type_appears(self):
        items = [self._mcq(), self._rubric()]

        self.assertEqual(
            _missing_allowed_types(("mcq", "subjective_rubric"), items), [])

    # ----------------------------------------------------------- the trim

    def test_the_trim_keeps_one_of_every_type_when_capping(self):
        """The property the quota trim must generalise, not break.

        Seven items where five are mcq: a naive items[:3] would drop both other
        types and silently re-open the coverage gap the self-heal just closed.
        """
        items = ([self._mcq("m%d" % i) for i in range(5)]
                 + [self._rubric("s"), self._mcq("m-last")])
        allowed = ("mcq", "subjective_rubric")

        kept = _trim_preserving_type_coverage(items, 2, allowed)

        self.assertEqual(len(kept), 2)
        self.assertEqual({it["question_type"] for it in kept}, set(allowed),
                         "each selected type keeps a representative")

    def test_the_trim_is_a_no_op_below_the_cap(self):
        items = [self._mcq()]

        self.assertEqual(_trim_preserving_type_coverage(items, 5, self.THREE),
                         items)

    def test_the_trim_preserves_each_items_answer_key(self):
        """Solutions ride on the item dict; a trim must not strip them."""
        items = [dict(self._mcq("m"), _solution={"correct_answer": "A"}),
                 dict(self._rubric("s"), _solution={"ideal_answer": "B"})]

        kept = _trim_preserving_type_coverage(
            items, 2, ("mcq", "subjective_rubric"))

        for it in kept:
            self.assertIn("_solution", it)
