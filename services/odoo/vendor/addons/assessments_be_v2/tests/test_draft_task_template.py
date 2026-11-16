"""Drafting a task template from the SOP: normalisation and the save boundary.

The Vertex call itself is verified live (a real draft off the T2I SOP returned the
SOP's own four axes with their own asymmetric options - Tie on two, Both Good /
Both Bad on the others - plus the justification paragraph). What matters to pin
here is the NORMALISER, because it decides what reaches the designer:

  * nothing the model returned is silently dropped - a shape the designer cannot
    render is downgraded and FLAGGED, so the admin approves or deletes, never the
    pipeline;
  * an unkeyed choice question is reported rather than saved as a question that
    would score zero for everyone.
"""
from odoo.tests.common import TransactionCase

from ..services.vertex import _normalise_template_sections


class TestDraftTaskTemplate(TransactionCase):

    def test_a_clean_draft_passes_through(self):
        warnings = []
        sections, count = _normalise_template_sections([{
            "title": "Judgment",
            "items": [{
                "kind": "multipleChoice",
                "title": "Which image better follows the prompt?",
                "options": [{"label": "Image A", "correct": True},
                            {"label": "Image B", "correct": False}],
            }],
        }], warnings)

        self.assertEqual(warnings, [])
        self.assertEqual(count, 1)
        item = sections[0]["items"][0]
        self.assertEqual(item["kind"], "multipleChoice")
        self.assertEqual([o["label"] for o in item["options"]],
                         ["Image A", "Image B"])
        self.assertTrue(item["options"][0]["correct"],
                        "the designer reads `correct`, not `is_correct`")

    def test_the_sops_own_asymmetric_options_survive(self):
        """The live draft returned 3 options on one axis and 4 on another.

        Normalising them to a common set would recreate the generic-scale bug
        this whole feature exists to remove.
        """
        warnings = []
        sections, _count = _normalise_template_sections([{
            "title": "Axes",
            "items": [
                {"kind": "multipleChoice", "title": "Less AI-generated?",
                 "options": [{"label": "Image A", "correct": True},
                             {"label": "Image B"}, {"label": "Tie"}]},
                {"kind": "multipleChoice", "title": "Follows the prompt?",
                 "options": [{"label": "Image A", "correct": True},
                             {"label": "Image B"}, {"label": "Both Good"},
                             {"label": "Both Bad"}]},
            ],
        }], warnings)

        items = sections[0]["items"]
        self.assertEqual(len(items[0]["options"]), 3)
        self.assertEqual(len(items[1]["options"]), 4)

    def test_an_unkeyed_choice_question_is_flagged_not_dropped(self):
        """It would score zero for every candidate; the admin must see it."""
        warnings = []
        sections, count = _normalise_template_sections([{
            "title": "S",
            "items": [{"kind": "multipleChoice", "title": "Which do you prefer?",
                       "options": [{"label": "Image A"}, {"label": "Image B"}]}],
        }], warnings)

        self.assertEqual(count, 1, "kept, not dropped")
        self.assertTrue(any("no correct option marked" in w for w in warnings))

    def test_an_unknown_kind_is_downgraded_and_flagged(self):
        warnings = []
        sections, count = _normalise_template_sections([{
            "title": "S",
            "items": [{"kind": "interpretiveDance", "title": "Express it"}],
        }], warnings)

        self.assertEqual(count, 1, "content is never thrown away")
        self.assertEqual(sections[0]["items"][0]["kind"], "shortAnswer")
        self.assertTrue(any("not a question kind" in w for w in warnings))

    def test_a_choice_question_with_one_option_becomes_a_short_answer(self):
        """One option is not a choice; keeping it as MCQ would be unanswerable."""
        warnings = []
        sections, _count = _normalise_template_sections([{
            "title": "S",
            "items": [{"kind": "multipleChoice", "title": "Only one",
                       "options": [{"label": "Yes", "correct": True}]}],
        }], warnings)

        self.assertEqual(sections[0]["items"][0]["kind"], "shortAnswer")
        self.assertEqual(sections[0]["items"][0]["options"], [])
        self.assertTrue(any("fewer than two options" in w for w in warnings))

    def test_blank_option_labels_are_discarded(self):
        """An option a worker cannot read is not an option."""
        warnings = []
        sections, _count = _normalise_template_sections([{
            "title": "S",
            "items": [{"kind": "multipleChoice", "title": "Pick",
                       "options": [{"label": "Yes", "correct": True},
                                   {"label": "   "},
                                   {"label": "No"}]}],
        }], warnings)

        labels = [o["label"] for o in sections[0]["items"][0]["options"]]
        self.assertEqual(labels, ["Yes", "No"])

    def test_a_junk_section_is_reported(self):
        warnings = []
        sections, count = _normalise_template_sections(
            ["not a section"], warnings)

        self.assertEqual(count, 0)
        self.assertTrue(any("was not an object" in w for w in warnings))
        self.assertEqual(len(sections), 1,
                         "an empty starting point, not a crash")

    def test_no_sections_yields_a_usable_blank_template(self):
        warnings = []
        sections, count = _normalise_template_sections(None, warnings)

        self.assertEqual(count, 0)
        self.assertEqual(sections[0]["items"], [])
        self.assertTrue(any("no usable section" in w for w in warnings))

    def test_ids_are_stable_within_a_draft(self):
        """The designer keys widgets by id; duplicates would collide."""
        warnings = []
        sections, _count = _normalise_template_sections([{
            "title": "S",
            "items": [{"kind": "paragraph", "title": "A"},
                      {"kind": "paragraph", "title": "B"}],
        }], warnings)

        ids = [i["id"] for i in sections[0]["items"]]
        self.assertEqual(len(set(ids)), 2)

    def test_the_first_call_has_room_for_the_thinking_model(self):
        """Prod 2026-09-29: at max_tokens=4000 gemini-3.1-pro-preview spent
        ~3,840 tokens thinking and was cut off on EVERY first attempt; the 8000
        retry used up to 6,348 thoughts + ~400 output. The first budget must fit
        that, and a cut-off retry must get more room than the first call."""
        from unittest.mock import patch

        from ..services import vertex

        generator = self.env["assessments.be.prompt"].create(
            {"name": "Budget", "source_text": "Judge which image is sharper."})
        with patch.object(vertex, "_call_vertex", return_value=(
                '{"name": "T", "response": "single_choice", "sections": []}'
        )) as call:
            vertex.draft_task_template_from_sop(self.env, generator)

        kwargs = call.call_args.kwargs
        self.assertGreaterEqual(kwargs["max_tokens"], 12000)
        retry = (kwargs.get("retry_max_tokens")
                 or vertex._RETRY_OUTPUT_TOKENS_CEILING)
        self.assertGreater(retry, kwargs["max_tokens"])
