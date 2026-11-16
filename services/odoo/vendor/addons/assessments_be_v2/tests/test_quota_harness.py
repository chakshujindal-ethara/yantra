"""The quota stage inside the harness: directive, counting, trim.

These exercise the code that decides what the model is ASKED for and which items
SURVIVE - the two places a quota bug would cost a paid generation run to find.

The pure quota arithmetic lives in test_shape_quotas.py; this is the harness
integration, including the no-regression case (no quotas -> today's behaviour).
"""
from odoo.tests.common import TransactionCase

from ..services.vertex import (
    _count_items_by_shape,
    _quota_directive,
    _template_shapes_note,
    _trim_preserving_quotas,
    _trim_preserving_type_coverage,
)


def _mcq(name="m", **kw):
    return dict({"question_type": "mcq", "name": name, "prompt": name,
                 "options": ["Yes", "No"], "correct_answer": "Yes"}, **kw)


def _rubric(name="s", **kw):
    return dict({"question_type": "subjective_rubric", "name": name,
                 "prompt": name,
                 "rubric": {"checklist": ["names it"],
                            "constraints": ["one para"],
                            "pass_condition": "names both"}}, **kw)


class TestQuotaHarness(TransactionCase):

    ALLOWED = ("mcq", "subjective_rubric")

    # ------------------------------------------------------- the directive

    def test_the_directive_states_each_explicit_count(self):
        """`MCQ x 2, Subjective x 3` was previously unsayable to the model."""
        d = _quota_directive({"mcq": 2, "subjective_rubric": 3})

        self.assertIn('EXACTLY 2 item(s) of question_type "mcq"', d)
        self.assertIn('EXACTLY 3 item(s) of question_type "subjective_rubric"', d)

    def test_the_directive_forbids_padding_with_another_shape(self):
        """A short run must report the gap, not fake the number."""
        d = _quota_directive({"mcq": 2})

        self.assertIn("do NOT substitute a different shape to pad", d)

    def test_a_template_shape_is_named_not_shown_as_an_id(self):
        """The model needs the task's name; `template:7` means nothing to it."""
        d = _quota_directive(
            {"template:7": 2},
            {"template:7": {"name": "Forklift defect check"}})

        self.assertIn('reproducing the task "Forklift defect check"', d)
        self.assertNotIn("template:7\"", d)

    def test_no_quota_produces_no_directive_text(self):
        """THE NO-REGRESSION CASE: every existing generator's prompt is unchanged."""
        self.assertEqual(_quota_directive({}), "")
        self.assertEqual(_quota_directive(None), "")

    def test_a_template_note_carries_the_examiners_own_axes(self):
        note = _template_shapes_note({"template:7": {
            "name": "Judge adherence",
            "question_type": "mcq",
            "instructions": "Ask about one SOP rule.",
            "task": {"answer_contract": {"dimensions": [
                {"label": "Follows the rule?", "options": ["Yes", "No"]}]}},
        }})

        self.assertIn("Judge adherence", note)
        self.assertIn("author these as question_type: mcq", note)
        self.assertIn("axis: Follows the rule? | options: Yes, No", note)
        self.assertIn("outrank anything you would infer from the SOP", note)

    def test_the_note_keeps_the_types_own_answer_key_contract(self):
        """A template says what is ASKED; it does not waive the key's shape.

        Found by a real run: the model returned two well-formed A/B template
        items and BOTH were refused for "construction_keys must include an
        Overall Choice (OC) dimension". The template's axes are named in the
        SOP's words ("Overall Preference"), not the OC code the validator wants,
        so the note has to say both apply or the quota can never close.
        """
        note = _template_shapes_note({"template:7": {
            "name": "A/B", "question_type": "image_ab",
            "task": {"answer_contract": {"dimensions": []}},
        }})

        self.assertIn("Overall Choice / OC", note)
        self.assertIn("construction_keys", note)

    def test_no_templates_produce_no_note(self):
        self.assertEqual(_template_shapes_note({}), "")

    # -------------------------------------------------------- the counting

    def test_only_items_that_would_persist_count(self):
        """A malformed item must not satisfy a quota it would be dropped from.

        Same rule the coverage stage already used: count what survives create,
        or a quota looks met while the batch ships short.
        """
        items = [_mcq("good"), {"question_type": "mcq"}]  # second has no options

        counted = _count_items_by_shape(items, self.ALLOWED, {"mcq": 2})

        self.assertEqual(counted.get("mcq"), 1)

    def test_a_template_item_counts_for_its_template_and_its_type(self):
        """The admin's "this shape x 2" and the type coverage floor both apply."""
        items = [_mcq("t1", _template_shape="template:7")]

        counted = _count_items_by_shape(
            items, self.ALLOWED, {"template:7": 2, "mcq": 1})

        self.assertEqual(counted.get("template:7"), 1)
        self.assertEqual(counted.get("mcq"), 1)

    def test_an_unstamped_item_does_not_satisfy_a_template_quota(self):
        """Otherwise any mcq would silently count as the examiner's saved task."""
        counted = _count_items_by_shape(
            [_mcq("plain")], self.ALLOWED, {"template:7": 2})

        self.assertEqual(counted.get("template:7"), None)

    # ------------------------------------------------------------ the trim

    def test_the_trim_keeps_the_full_quota_not_just_one(self):
        """The behaviour change: coverage protected 1, a quota protects `wanted`.

        Five mcq and one rubric, capped at 3, with mcq x 2 requested: the two
        mcq must survive alongside the rubric's coverage floor.
        """
        items = [_mcq("m%d" % i) for i in range(5)] + [_rubric("s")]

        kept = _trim_preserving_quotas(
            items, 3, self.ALLOWED, quotas={"mcq": 2})

        self.assertEqual(len(kept), 3)
        types = [it["question_type"] for it in kept]
        self.assertEqual(types.count("mcq"), 2,
                         "the explicit quota of 2 must survive the trim")

    def test_an_oversubscribed_quota_cannot_happen_in_the_pipeline(self):
        """The squeeze this trim would face is prevented upstream.

        `effective_generation_count` raises the requested total to the quota sum,
        so the trim is never asked to choose between two shapes the examiner both
        asked for. Pinning that here because the alternative - inventing a
        priority rule for an unreachable state - is complexity with no caller.
        """
        from ..constants import effective_generation_count

        quotas = {"subjective_rubric": 2, "mcq": 2}

        self.assertEqual(effective_generation_count(2, quotas), 4,
                         "the total rises so every quota fits")

    def test_the_trim_is_deterministic_when_over_subscribed(self):
        """Called directly with an impossible cap it must still be stable.

        No priority rule is claimed: it keeps items in the model's own order,
        which is what makes two runs on one batch agree.
        """
        items = [_mcq("m1"), _mcq("m2"), _rubric("s1"), _rubric("s2")]
        quotas = {"subjective_rubric": 2, "mcq": 2}

        first = _trim_preserving_quotas(items, 2, self.ALLOWED, quotas=quotas)
        second = _trim_preserving_quotas(items, 2, self.ALLOWED, quotas=quotas)

        self.assertEqual([it["name"] for it in first],
                         [it["name"] for it in second])
        self.assertEqual(len(first), 2)
        for it in first:
            self.assertIn(it["question_type"], quotas,
                          "every kept item still serves a requested shape")

    def test_the_trim_delegates_when_there_is_no_quota(self):
        """THE NO-REGRESSION CASE: identical output to the old trim."""
        items = [_mcq("m%d" % i) for i in range(4)] + [_rubric("s")]

        self.assertEqual(
            _trim_preserving_quotas(items, 2, self.ALLOWED, quotas=None),
            _trim_preserving_type_coverage(items, 2, self.ALLOWED))

    def test_the_trim_is_a_no_op_below_the_cap(self):
        items = [_mcq("m")]

        self.assertEqual(
            _trim_preserving_quotas(items, 5, self.ALLOWED, quotas={"mcq": 1}),
            items)

    def test_the_trim_preserves_answer_keys(self):
        items = [_mcq("m", _solution={"correct_answer": "Yes"}),
                 _rubric("s", _solution={"pass_condition": "x"})]

        kept = _trim_preserving_quotas(
            items, 2, self.ALLOWED, quotas={"mcq": 1})

        for it in kept:
            self.assertIn("_solution", it)
