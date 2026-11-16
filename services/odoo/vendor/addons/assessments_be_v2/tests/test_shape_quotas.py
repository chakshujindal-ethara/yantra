"""Shape quotas: "how many of what", for types AND task templates.

WHY ONE MECHANISM. The admin can now say `MCQ x 2, Subjective x 3` and also
`this saved task x 2`. Those look like two features and are deliberately one: a
quota maps a SHAPE (a question type, or `template:<id>`) to a wanted count, and
the existing type-coverage stage becomes the special case where wanted is 1.
Built separately, the second would have rewritten the first.

Everything here is pure, so it is cheap to pin exhaustively - which matters
because the expensive path (a real generation run) is the one place these bugs
would otherwise surface.
"""
from odoo.tests.common import TransactionCase

from ..constants import (
    effective_generation_count,
    is_template_shape,
    parse_shape_quotas,
    quota_shortfall,
    quota_total,
    template_id_of_shape,
)


class TestShapeQuotas(TransactionCase):

    ALLOWED = ("mcq", "subjective_rubric", "image_ab")

    # ------------------------------------------------------------- parsing

    def test_a_plain_quota_survives(self):
        q = parse_shape_quotas({"mcq": 2, "subjective_rubric": 3}, self.ALLOWED)

        self.assertEqual(q, {"mcq": 2, "subjective_rubric": 3})
        self.assertEqual(quota_total(q), 5)

    def test_stored_json_is_accepted(self):
        """The field round-trips through JSON, so parsing must accept the string."""
        q = parse_shape_quotas('{"mcq": 2}', self.ALLOWED)

        self.assertEqual(q, {"mcq": 2})

    def test_malformed_input_degrades_to_no_quota(self):
        """Today's behaviour is the fallback; a bad quota must not lose a run."""
        for bad in ("{not json", "", None, "[]", '"mcq"', 42, [("mcq", 2)]):
            self.assertEqual(parse_shape_quotas(bad, self.ALLOWED), {},
                             "%r should degrade to no quota" % (bad,))

    def test_a_quota_for_an_unselected_type_is_dropped(self):
        """Contradictory: the allow-list would discard those items anyway."""
        q = parse_shape_quotas({"mcq": 2, "video_prompt": 4}, self.ALLOWED)

        self.assertEqual(q, {"mcq": 2})

    def test_auto_mode_drops_a_stale_type_quota(self):
        """An empty allow-list means AUTO - the model picks the types.

        THE DEFECT. The unselected-type guard only ran when the allow-list was
        non-empty, so clearing the type picker left any type quota from an
        earlier session alive: invisible in the picker (which now reads "Any
        type"), but still counted on the Generate button AND still sent to the
        model as a directive. Live example - generator 178 read "3 questions -
        1 Rubric, 2 MCQ" with nothing selected and one draft to show for it.

        A TYPE quota is an instruction about the allow-list, so with no
        allow-list it has no meaning and must not survive.
        """
        self.assertEqual(
            parse_shape_quotas({"mcq": 2, "subjective_rubric": 1}, ()), {})

    def test_auto_mode_keeps_a_template_quota(self):
        """A TEMPLATE shape names its own question type, so Auto is no
        contradiction - this is the whole point of picking a task."""
        self.assertEqual(
            parse_shape_quotas({"template:6": 2}, ()), {"template:6": 2})

    def test_auto_mode_keeps_templates_and_drops_types_together(self):
        self.assertEqual(
            parse_shape_quotas({"mcq": 3, "template:6": 2}, ()),
            {"template:6": 2})

    def test_non_positive_and_non_numeric_counts_are_dropped(self):
        q = parse_shape_quotas(
            {"mcq": 0, "subjective_rubric": -1, "image_ab": "two"},
            self.ALLOWED)

        self.assertEqual(q, {})

    def test_true_is_not_a_count_of_one(self):
        """bool is an int subclass; a stray True must not become a quota."""
        self.assertEqual(parse_shape_quotas({"mcq": True}, self.ALLOWED), {})

    def test_a_float_count_is_truncated_not_refused(self):
        """JSON has no ints; 2.0 off the wire is a legitimate 2."""
        self.assertEqual(parse_shape_quotas({"mcq": 2.0}, self.ALLOWED),
                         {"mcq": 2})

    def test_quota_order_is_preserved(self):
        """Top-ups run in the admin's order, so a squeeze keeps their priority."""
        q = parse_shape_quotas(
            {"subjective_rubric": 1, "mcq": 1, "image_ab": 1}, self.ALLOWED)

        self.assertEqual(list(q), ["subjective_rubric", "mcq", "image_ab"])

    # ------------------------------------------------------ template shapes

    def test_a_template_shape_needs_no_allow_list_entry(self):
        """A template is not a question type; the allow-list does not name it."""
        q = parse_shape_quotas({"template:7": 2}, self.ALLOWED)

        self.assertEqual(q, {"template:7": 2})
        self.assertTrue(is_template_shape("template:7"))
        self.assertEqual(template_id_of_shape("template:7"), 7)

    def test_a_malformed_template_shape_is_dropped(self):
        for bad in ("template:", "template:0", "template:-3", "template:abc"):
            self.assertEqual(parse_shape_quotas({bad: 2}), {},
                             "%r is not an addressable template" % bad)
            self.assertIsNone(template_id_of_shape(bad))

    def test_a_type_is_not_mistaken_for_a_template(self):
        self.assertFalse(is_template_shape("mcq"))
        self.assertIsNone(template_id_of_shape("mcq"))

    def test_types_and_templates_mix_in_one_quota(self):
        """The point of a single mechanism."""
        q = parse_shape_quotas({"mcq": 2, "template:7": 3}, self.ALLOWED)

        self.assertEqual(quota_total(q), 5)

    # --------------------------------------------------- the effective count

    def test_quotas_raise_a_total_that_is_too_small(self):
        """Asking for 3 while requesting 5 explicitly would drop the admin's ask.

        The trim would then have to pick a victim among choices the admin made
        deliberately, which is exactly the silent-disagreement bug class.
        """
        self.assertEqual(
            effective_generation_count(3, {"mcq": 2, "subjective_rubric": 3}),
            5)

    def test_a_larger_total_is_kept_so_free_choice_remains(self):
        """8 total with 5 quota'd leaves 3 for the model to choose."""
        self.assertEqual(
            effective_generation_count(8, {"mcq": 2, "subjective_rubric": 3}),
            8)

    def test_auto_plus_a_quota_becomes_concrete(self):
        """count=0 means the model decides; a quota makes that a real floor."""
        self.assertEqual(effective_generation_count(0, {"mcq": 2}), 2)

    def test_no_quota_leaves_the_count_exactly_as_it_was(self):
        """THE NO-REGRESSION CASE for every existing generator."""
        self.assertEqual(effective_generation_count(6, {}), 6)
        self.assertEqual(effective_generation_count(0, {}), 0)

    # --------------------------------------------- the "any" coverage floor

    def test_a_ticked_type_with_no_quota_is_worth_one(self):
        """Its chip reads "any", and the UI has always promised that "a type
        with no explicit count still gets at least one item".

        The floor was built from the quotas alone, so "any" was worth nothing:
        a run of `MSQ x3` plus `Rubric x any` asked the model for three when
        the operator had asked for at least four.
        """
        self.assertEqual(
            effective_generation_count(
                0, {"msq": 3}, allowed=("msq", "subjective_rubric")),
            4)

    def test_a_type_carrying_a_quota_is_never_counted_twice(self):
        """`msq` appears in both arguments and is worth its quota, not 3 + 1."""
        self.assertEqual(
            effective_generation_count(0, {"msq": 3}, allowed=("msq",)), 3)

    def test_ticking_another_type_moves_the_total(self):
        """THE reported symptom: adding a type changed nothing on screen, then
        changed the run."""
        before = effective_generation_count(
            0, {"msq": 3, "image_ab": 1}, allowed=("msq", "image_ab"))
        after = effective_generation_count(
            0, {"msq": 3, "image_ab": 1},
            allowed=("msq", "image_ab", "subjective_rubric"))

        self.assertEqual(before, 4)
        self.assertEqual(after, before + 1)

    def test_types_alone_are_a_floor_with_no_quota_at_all(self):
        """Three ticked types and nothing else is a request for three."""
        self.assertEqual(
            effective_generation_count(
                0, {}, allowed=("mcq", "msq", "subjective_rubric")),
            3)

    def test_a_bigger_pinned_total_still_wins(self):
        """"20 across these three types" stays expressible - the floor raises a
        total that is too small, it never caps one that is large enough."""
        self.assertEqual(
            effective_generation_count(
                20, {}, allowed=("mcq", "msq", "subjective_rubric")),
            20)

    def test_omitting_allowed_is_the_old_behaviour(self):
        """Every caller that has not been taught about types is unchanged."""
        self.assertEqual(effective_generation_count(3, {"mcq": 2}), 3)
        self.assertEqual(effective_generation_count(0, {"mcq": 2}), 2)

    def test_a_template_quota_is_not_double_charged(self):
        """A template implies its own question type, and `generate_questions`
        widens `allowed` to include it so the quota is usable at all.

        The count is taken from the types the operator TICKED, before that
        widening - otherwise every template quota would silently add one more
        item than was asked for. Pinned here as the contract the caller relies
        on: a shape not in `allowed` contributes only its quota.
        """
        self.assertEqual(
            effective_generation_count(
                0, {"template:5": 2}, allowed=()),
            2)

    # ------------------------------------------------------------ shortfall

    def test_shortfall_reports_what_is_still_missing(self):
        short = quota_shortfall({"mcq": 2, "subjective_rubric": 3},
                                {"mcq": 1, "subjective_rubric": 3})

        self.assertEqual(short, {"mcq": 1})

    def test_nothing_missing_is_an_empty_shortfall(self):
        self.assertEqual(
            quota_shortfall({"mcq": 2}, {"mcq": 2}), {})
        self.assertEqual(
            quota_shortfall({"mcq": 2}, {"mcq": 5}), {},
            "overshoot is not a shortfall")

    def test_an_unmet_shape_with_no_items_reports_its_whole_quota(self):
        self.assertEqual(quota_shortfall({"template:7": 3}, {}),
                         {"template:7": 3})

    def test_no_quota_means_no_shortfall(self):
        self.assertEqual(quota_shortfall({}, {"mcq": 4}), {})
