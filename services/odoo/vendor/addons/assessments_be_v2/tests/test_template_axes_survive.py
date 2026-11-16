# -*- coding: utf-8 -*-
"""A template's authored axes have to survive generation.

THE DEFECT. A task template is drawn in the Form Studio editor, so an examiner
can author "six Yes/No checks" as six real multiple-choice items. Generation
sent that structure to the model as prose, got prose back, and stored prose:
the draft landed with no dimensions and no options, and every one of those
checks survived only as a numbered list inside the question text.

WHAT IT COST. `subjective_rubric` renders as a single free-text box, so a
candidate was shown one textarea for six distinct judgements, and the grader -
which marks per component - had nothing per-axis to mark. The examiner's
structure was visible on the template screen and nowhere else, which is exactly
why it looked fine in one place and wrong everywhere else.

THE FIX. `_resolve_template_shapes` carries the template's `answer_contract()`,
and the draft builder inherits its axes into `dimensions_json` - the module's
existing type-agnostic carrier, which `_specs_from_json` already expands into
dimension rows on approve. The inheritance is a FLOOR: a model that returns its
own structure keeps it, and no answer key is ever invented.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase

from ..services.vertex import _resolve_template_shapes


class TestTemplateAxesSurviveGeneration(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Template = self.env["assessments.be.task.template"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Axes fixture %s" % uuid4().hex[:6]})

    def _yes_no_template(self, labels, response="describe_media",
                         question_type="subjective_rubric"):
        """A template authored the way the Form Studio editor writes one."""
        items = [{
            "id": "item-%d" % i,
            "kind": "multipleChoice",
            "title": label,
            "options": [{"id": "o-%d-y" % i, "label": "Yes"},
                        {"id": "o-%d-n" % i, "label": "No"}],
        } for i, label in enumerate(labels)]
        return self.Template.create({
            "name": "Tpl %s" % uuid4().hex[:6],
            "origin_prompt_id": self.generator.id,
            "response": response,
            "question_type": question_type,
            "structure_json": [{"id": "s-1", "title": "Checks",
                                "items": items}],
        })

    def _template_with(self, items):
        """A template holding whatever items the caller drew."""
        return self.Template.create({
            "name": "Tpl %s" % uuid4().hex[:6],
            "origin_prompt_id": self.generator.id,
            "response": "describe_media",
            "question_type": "subjective_rubric",
            "structure_json": [{"id": "s-1", "title": "Checks",
                                "items": items}],
        })

    def test_every_pickable_form_studio_kind_becomes_an_axis(self):
        """SHAPE DECIDES WHICH ITEMS ARE AXES, NOT A LIST OF KIND NAMES.

        `_axes` tested `kind in (multipleChoice, dropdown, checkboxes)`, so a
        linearScale, rating or grid drawn in Form Studio reached the generator
        as ZERO axes and vanished silently - Q7R's 1-5 rating among them. Every
        pickable kind writes its options the same way, so carrying two or more
        options is what makes an item an axis.
        """
        cases = {
            "multipleChoice": ["Yes", "No"],
            "dropdown": ["Yes", "No"],
            "checkboxes": ["Yes", "No"],
            "linearScale": ["1", "2", "3", "4", "5"],
            "rating": ["1", "2", "3", "4", "5"],
        }
        for kind, options in cases.items():
            template = self._template_with([{
                "id": "i-1", "kind": kind, "title": "%s check" % kind,
                "options": [{"id": o, "label": o} for o in options],
            }])
            axes = template._axes()
            self.assertEqual(
                len(axes), 1,
                "a %s carrying options is an answerable axis" % kind)
            self.assertEqual(axes[0]["options"], options,
                             "a %s keeps the scale the examiner drew" % kind)

    def test_a_grid_contributes_one_axis_per_row(self):
        """A grid asks the same options of several rows: each row is an axis.

        Flattening a grid to one axis would silently drop every row but one,
        which is the same data loss in a different shape.
        """
        template = self._template_with([{
            "id": "g-1", "kind": "choiceGrid", "title": "Entity match",
            "options": [{"id": "p", "label": "Pass"},
                        {"id": "f", "label": "Fail"}],
            "rows": [{"id": "r1", "label": "Logo"},
                     {"id": "r2", "label": "Caption"}],
        }])
        axes = template._axes()
        self.assertEqual(len(axes), 2, "one axis per grid row")
        self.assertEqual([a["label"] for a in axes],
                         ["Entity match - Logo", "Entity match - Caption"])
        for axis in axes:
            self.assertEqual(axis["options"], ["Pass", "Fail"])

    def test_layout_and_free_text_items_are_never_axes(self):
        """The widened rule must not turn prose or decoration into questions.

        A textBlock is layout, a shortAnswer is the RESPONSE, and a media block
        with no options is context. Form Studio's own `isAnswerable` says a
        media block becomes a question only once it carries options, so the
        backend has to draw the line in the same place.
        """
        for kind in ("textBlock", "shortAnswer", "paragraph", "date", "time",
                     "fileUpload", "imageAnnotation"):
            template = self._template_with(
                [{"id": "i-1", "kind": kind, "title": "%s item" % kind}])
            self.assertEqual(template._axes(), [],
                             "a %s is not an axis" % kind)

        decorative = self._template_with(
            [{"id": "i-1", "kind": "imageBlock", "title": "Context shot"}])
        self.assertEqual(decorative._axes(), [],
                         "a media block with no options stays decorative")

        asked = self._template_with([{
            "id": "i-1", "kind": "imageBlock", "title": "Which is better?",
            "options": [{"id": "a", "label": "A"}, {"id": "b", "label": "B"}],
        }])
        self.assertEqual(
            len(asked._axes()), 1,
            "a media block WITH options is a question, as Form Studio says")

    def test_a_half_drawn_pickable_item_is_not_an_axis(self):
        """One option is not a question; it is an unfinished item."""
        template = self._template_with([{
            "id": "i-1", "kind": "rating", "title": "Half drawn",
            "options": [{"id": "1", "label": "1"}],
        }])
        self.assertEqual(template._axes(), [],
                         "fewer than two options cannot be answered")

    def _inherit(self, template):
        """Run the resolver and replay the draft builder's inheritance."""
        shape = "template:%d" % template.id
        spec = (_resolve_template_shapes(
            self.env, {shape: 1}) or {}).get(shape) or {}
        contract = spec.get("answer_contract") or {}
        axes = contract.get("dimensions") or []
        axis_options = contract.get("dimension_options") or {}
        out = []
        for axis in axes:
            if isinstance(axis, dict):
                label = axis.get("label") or ""
                choices = axis.get("options") or []
            else:
                label, choices = str(axis), []
            if not choices:
                choices = axis_options.get(label) or []
            choices = [str(c) for c in choices]
            if not label or len(choices) < 2:
                continue
            out.append({"label": str(label)[:200],
                        "options": choices, "correct": []})
        return out

    def test_the_resolver_carries_the_authored_contract(self):
        """THE seam. Without this the axes never leave the template."""
        template = self._yes_no_template(
            ["Is the picture sharp?", "Is it a real photo?"])
        shape = "template:%d" % template.id

        spec = (_resolve_template_shapes(
            self.env, {shape: 1}) or {}).get(shape) or {}

        self.assertTrue(
            spec.get("answer_contract"),
            "the resolved spec must carry the template's answer contract - "
            "it is the only path the authored structure has out of the model")
        self.assertEqual(
            len(spec["answer_contract"].get("dimensions") or []), 2)

    def test_six_authored_checks_become_six_answerable_axes(self):
        """THE regression, at the size that was actually reported."""
        labels = [
            "Is the Picture Sharp and Clear?",
            "Does This Look Like a Real Image (Not AI)?",
            "Is This a Good-Looking Photo?",
            "Does the Picture Have a Watermark?",
            "Is This From the Same Photoshoot?",
            "Does This Show the Exact Same Thing in the Box?",
        ]
        template = self._yes_no_template(labels)

        inherited = self._inherit(template)

        self.assertEqual(
            len(inherited), 6,
            "all six authored checks must become answerable axes - before the "
            "fix the draft carried zero and the candidate saw one text box")
        self.assertEqual([d["label"] for d in inherited], labels)
        for d in inherited:
            self.assertEqual(d["options"], ["Yes", "No"])

    def test_no_answer_key_is_invented(self):
        """A guessed key would mark real candidates against a fabrication."""
        template = self._yes_no_template(["Sharp?", "Real?"])

        for d in self._inherit(template):
            self.assertEqual(
                d["correct"], [],
                "which option is correct is per generated instance and "
                "belongs to the model or the reviewer, never to inheritance")

    def test_an_axis_with_one_option_is_not_carried(self):
        """An unanswerable axis would draw an empty control on screen."""
        template = self.Template.create({
            "name": "Tpl %s" % uuid4().hex[:6],
            "origin_prompt_id": self.generator.id,
            "response": "describe_media",
            "question_type": "subjective_rubric",
            "structure_json": [{
                "id": "s-1", "title": "Checks",
                "items": [
                    {"id": "i-1", "kind": "multipleChoice", "title": "Fine?",
                     "options": [{"id": "o-1", "label": "Yes"},
                                 {"id": "o-2", "label": "No"}]},
                    {"id": "i-2", "kind": "multipleChoice", "title": "Broken?",
                     "options": [{"id": "o-3", "label": "Only one"}]},
                ],
            }],
        })

        inherited = self._inherit(template)

        self.assertEqual([d["label"] for d in inherited], ["Fine?"])

    def test_approve_expands_axes_for_a_rubric_question(self):
        """THE APPROVE GATE MUST NOT BE A TYPE LIST.

        Carrying axes onto the draft is only half the path. `action_approve`
        called `_materialize_dimensions` for a FIXED set of types that excluded
        `subjective_rubric`, so a template-authored rubric reached the bank with
        its axes still trapped in JSON: the draft was right and the bank empty,
        and the candidate still got one free-text box.

        The six checks below are the real IG Entity Sample Audit SOP.
        """
        labels = ["Is the Picture Sharp and Clear?",
                  "Does This Look Like a Real Image (Not AI)?",
                  "Is This a Good-Looking Photo?",
                  "Does the Picture Have a Watermark?",
                  "Is This From the Same Photoshoot?",
                  "Does This Show the Exact Same Thing in the Box?"]
        template = self._yes_no_template(labels)
        inherited = self._inherit(template)
        self.assertEqual(len(inherited), 6, "all six axes should be inherited")

        draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": self.generator.id,
            "name": "IG Entity - Sample Audit",
            "question_type": "subjective_rubric",
            "question_prompt": "Audit this image set against the SOP.",
            "source_template_id": template.id,
            "dimensions_json": json.dumps(inherited, ensure_ascii=False),
        })
        draft.action_approve()
        self.env.cr.flush()

        bank = self.env["assessments.be.question"].search(
            [("name", "=", "IG Entity - Sample Audit")], limit=1)
        self.assertTrue(bank, "approve should create the bank question")
        dims = self.env["assessments.be.question.dimension"].search(
            [("question_id", "=", bank.id)])
        self.assertEqual(
            len(dims), 6,
            "a rubric question's axes must become real dimension rows - "
            "otherwise the candidate gets one textarea and the grader has "
            "nothing per-axis to mark")
        self.assertEqual(sorted(d.name for d in dims), sorted(labels))
        for d in dims:
            self.assertEqual([o.name for o in d.option_line_ids],
                             ["Yes", "No"])

    def test_a_draft_with_no_axes_still_approves_clean(self):
        """Widening the gate must not INVENT dimensions.

        `_dimension_specs()` returns nothing when there is nothing to expand, so
        a plain subjective draft approves with zero dimension rows exactly as
        before. The fix widened WHICH types may expand, not WHETHER an empty
        draft does.
        """
        draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": self.generator.id,
            "name": "Plain written critique",
            "question_type": "subjective_rubric",
            "question_prompt": "Write a critique of this edit.",
        })
        draft.action_approve()
        self.env.cr.flush()

        bank = self.env["assessments.be.question"].search(
            [("name", "=", "Plain written critique")], limit=1)
        self.assertTrue(bank, "it should still approve")
        dims = self.env["assessments.be.question.dimension"].search(
            [("question_id", "=", bank.id)])
        self.assertEqual(len(dims), 0,
                         "no axes authored means no dimensions invented")

    def test_the_module_expands_inherited_axes_into_dimension_rows(self):
        """END TO END: what is inherited is what the grader will mark."""
        template = self._yes_no_template(["Sharp?", "Real?", "Watermarked?"])
        inherited = self._inherit(template)

        draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": self.generator.id,
            "name": "Generated from a template",
            "question_type": "subjective_rubric",
            "question_prompt": "Judge the image.",
            "source_template_id": template.id,
            "dimensions_json": json.dumps(inherited, ensure_ascii=False),
        })

        specs = draft._specs_from_json()

        self.assertEqual(len(specs), 3)
        self.assertEqual(
            [s["label"] for s in specs],
            ["Sharp?", "Real?", "Watermarked?"])
        for s in specs:
            self.assertEqual(s["options"], ["Yes", "No"])
