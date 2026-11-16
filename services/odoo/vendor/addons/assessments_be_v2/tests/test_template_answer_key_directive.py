"""A template quota must tell the model what answer key its type needs.

FOUND BY THE FIRST LIVE RUN OF `describe_media` (template 20, "IG"), the last
of the eight response primitives never exercised end-to-end. The run succeeded -
one well-written audit question - but the item carried NO rubric, so:

  * `_validate_question_item` failed it, and it landed as "kept for review";
  * `_stamp_template_items` skipped invalid items, so the draft ALSO lost the
    record of which template authored it - the drafts table showed the engine's
    name and the reviewer had no way back to the template.

The cause was not a bad model. The per-request directive said "reproduce the
task IG" and passed the examiner's instructions, but never named the answer-key
fields; the general rule sat ~18k characters earlier in the system prompt, and
the specific instruction won.

Both halves are pinned here: the directive must state the requirement, and
attribution must survive a failed validation.
"""
from odoo.tests.common import TransactionCase

from ..constants import ANSWER_KEY_REQUIREMENT
from ..services.vertex import _quota_directive, _stamp_template_items


class TestTemplateDirectiveStatesTheKey(TransactionCase):

    SPECS = {
        "template:20": {"name": "IG", "question_type": "subjective_rubric"},
        "template:7": {"name": "Pick one", "question_type": "mcq"},
        "template:9": {"name": "Compare", "question_type": "image_ab"},
    }

    def test_a_rubric_template_is_told_to_write_a_rubric(self):
        out = _quota_directive({"template:20": 1}, self.SPECS)

        self.assertIn("IG", out)
        self.assertIn("rubric", out)
        self.assertIn("checklist", out)

    def test_an_mcq_template_is_told_to_write_options(self):
        out = _quota_directive({"template:7": 2}, self.SPECS)

        self.assertIn("options", out)
        self.assertIn("correct_answer", out)

    def test_an_image_template_is_not_given_a_key_requirement(self):
        """Image types get `image_specs` from their own directive; repeating a
        key requirement here would contradict "do NOT emit options"."""
        out = _quota_directive({"template:9": 1}, self.SPECS)

        self.assertIn("Compare", out)
        self.assertNotIn("correct_answer", out)

    def test_a_bare_type_quota_is_unchanged(self):
        out = _quota_directive({"mcq": 3}, self.SPECS)

        self.assertIn('question_type "mcq"', out)

    def test_every_requirement_names_its_fields(self):
        """Guards against an entry being added as prose with no field names."""
        for qtype, text in ANSWER_KEY_REQUIREMENT.items():
            self.assertTrue(text.strip(), "%s has no requirement text" % qtype)
            self.assertGreater(len(text), 20, qtype)


class TestAttributionSurvivesInvalidItems(TransactionCase):

    SPECS = {"template:20": {"name": "IG",
                             "question_type": "subjective_rubric"}}

    def test_an_item_missing_its_rubric_is_still_attributed(self):
        """THE DEFECT: this item lost its provenance because it was invalid."""
        items = [{"question_type": "subjective_rubric", "title": "Audit"}]

        _stamp_template_items(items, {"template:20": 1}, self.SPECS, ())

        self.assertEqual(items[0].get("_template_shape"), "template:20")

    def test_a_valid_item_is_still_attributed(self):
        items = [{
            "question_type": "subjective_rubric",
            "name": "Audit the set",
            "prompt": "Audit the image set against the brief.",
            "rubric": {"checklist": ["sharp"], "constraints": "none",
                       "pass_condition": "all met"},
        }]

        _stamp_template_items(items, {"template:20": 1}, self.SPECS, ())

        self.assertEqual(items[0].get("_template_shape"), "template:20")

    def test_the_quota_still_caps_how_many_are_attributed(self):
        """Conservative attribution is unchanged - only the validity test went."""
        items = [
            {"question_type": "subjective_rubric", "title": "one"},
            {"question_type": "subjective_rubric", "title": "two"},
        ]

        _stamp_template_items(items, {"template:20": 1}, self.SPECS, ())

        self.assertEqual(items[0].get("_template_shape"), "template:20")
        self.assertIsNone(items[1].get("_template_shape"),
                          "only 1 was asked for")

    def test_a_different_type_is_never_attributed(self):
        items = [{"question_type": "mcq", "title": "unrelated"}]

        _stamp_template_items(items, {"template:20": 1}, self.SPECS, ())

        self.assertIsNone(items[0].get("_template_shape"))
