# -*- coding: utf-8 -*-
"""A chosen task template's SHAPE is the contract, not a suggestion.

TWO DEFECTS THIS LOCKS DOWN.

1. `_authored_axes` / template binding. Axes were inherited onto a generated
   draft ONLY when the model returned no structure of its own. The model
   usually answers with a flat option list, so an operator who put
   `template:78 x 2` on a run got a plain 4-option MCQ and the six checks the
   examiner drew existed nowhere. Reproduced on draft 197.

   Flipping the precedence outright would be worse: the model's key names ITS
   options, so replacing them with keyless template axes publishes a question
   whose key matches nothing. So the two are RECONCILED - the authored shape is
   adopted and the model's key carried onto it when the option sets agree,
   otherwise the scoreable output is kept and the draft says so.

2. `_normalise_template_sections` accepted four kinds while the designer offers
   thirteen, so every model-drafted scale, rating, grid, dropdown, date, time,
   compare-pair and annotation was rewritten to `shortAnswer`. A text box
   carries no choices, so the item then vanished from the answer contract too.
"""
import json

from odoo.tests.common import TransactionCase

from odoo.addons.assessments_be_v2.services import vertex


class TestAuthoredAxes(TransactionCase):

    def test_an_axis_needs_at_least_two_choices(self):
        axes = [{"label": "Sharp?", "options": ["Yes", "No"], "kind": "mc"},
                {"label": "Notes", "options": ["Only one"], "kind": "mc"},
                {"label": "Blank", "options": [], "kind": "mc"}]
        out = vertex._authored_axes(axes, {})
        self.assertEqual([a["label"] for a in out], ["Sharp?"])

    def test_options_come_from_the_map_when_the_axis_has_none(self):
        axes = [{"label": "Sharp?", "kind": "multipleChoice"}]
        out = vertex._authored_axes(axes, {"Sharp?": ["Yes", "No"]})
        self.assertEqual(out[0]["options"], ["Yes", "No"])

    def test_no_key_is_ever_invented(self):
        """An axis the examiner did not key stays keyless.

        The complement - an axis they DID key keeps that key - is
        `test_template_authored_key.py`. Both halves matter: inventing a key
        marks candidates against a fabricated answer, and dropping an authored
        one leaves the axis unmarkable so its marks do not exist at all.
        """
        axes = [{"label": "Sharp?", "options": ["Yes", "No"]}]
        out = vertex._authored_axes(axes, {})
        self.assertEqual(out[0]["correct"], [],
                         "a guessed key would mark candidates against a "
                         "fabricated answer")

    def test_the_authored_kind_survives(self):
        axes = [{"label": "Confidence", "options": ["1", "2", "3"],
                 "kind": "linearScale"}]
        self.assertEqual(vertex._authored_axes(axes, {})[0]["kind"],
                         "linearScale")


class TestReconcileAxesWithOptions(TransactionCase):

    def _authored(self):
        return [
            {"label": "Is there a tell?", "options": ["Yes", "No"],
             "kind": "multipleChoice", "correct": []},
            {"label": "Which class?",
             "options": ["Anatomy", "Typography", "Physics"],
             "kind": "multipleChoice", "correct": []},
        ]

    def test_the_key_transfers_onto_the_matching_axis(self):
        out = vertex._reconcile_axes_with_options(
            self._authored(),
            json.dumps(["Anatomy", "Typography", "Physics"]),
            json.dumps("Typography"))
        self.assertIsNotNone(out)
        by_label = {a["label"]: a for a in out}
        self.assertEqual(by_label["Which class?"]["correct"], ["Typography"])
        self.assertEqual(by_label["Is there a tell?"]["correct"], [],
                         "an axis the model did not answer must stay keyless")

    def test_a_bare_index_is_REFUSED_not_read_as_a_position(self):
        """An integer key is never an index into the option list.

        THIS TEST USED TO ASSERT THE OPPOSITE - that `0` resolved to the first
        option - and that reading is what silently keys the WRONG option.
        `prompts/question.md` states the contract twice ("Matches an option
        verbatim", "`correct_answer` strings must match an option"), so a bare
        integer is either an option's own LABEL or it is unresolvable.

        The damage the old reading did: a model answering `1` on a linear scale
        means the point labelled "1", and `opt_labels[1]` is the SECOND point.
        Every candidate who picked correctly was marked wrong, with nothing
        anywhere reporting it.

        Refusal is the right outcome because the caller turns None into "the
        template's layout was not applied" plus a warning - a guessed key is
        worse than an unapplied layout, since the guess is invisible.
        """
        out = vertex._reconcile_axes_with_options(
            self._authored(),
            json.dumps(["Anatomy", "Typography", "Physics"]),
            json.dumps(0))
        self.assertIsNone(
            out,
            "0 matches no option label, so the key is unresolvable and the "
            "layout must be left unapplied rather than keyed by position")

    def test_a_numeric_key_matching_a_numeric_LABEL_still_resolves(self):
        """The legitimate integer case: a scale point whose label IS a number.

        This is why the fix matches on text rather than simply rejecting ints -
        a linear scale's options are labelled "1".."5", and a model answering 4
        means the point labelled "4".
        """
        authored = [{
            "label": "Severity",
            "options": ["1", "2", "3", "4", "5"],
            "correct": [],
        }]
        out = vertex._reconcile_axes_with_options(
            authored,
            json.dumps(["1", "2", "3", "4", "5"]),
            json.dumps(4))
        self.assertIsNotNone(out, "a numeric label must still be matchable")
        self.assertEqual(
            [a["correct"] for a in out if a["label"] == "Severity"][0],
            ["4"],
            "4 is the point LABELLED 4, not the fifth position")

    def test_punctuation_and_case_do_not_break_the_match(self):
        out = vertex._reconcile_axes_with_options(
            self._authored(),
            json.dumps(["anatomy.", "TYPOGRAPHY", "physics"]),
            json.dumps("anatomy."))
        self.assertIsNotNone(out, "normalisation should let these reconcile")

    def test_a_different_option_set_is_refused(self):
        """No honest mapping exists, so the model's output must be kept."""
        out = vertex._reconcile_axes_with_options(
            self._authored(),
            json.dumps(["Left image", "Right image"]),
            json.dumps("Left image"))
        self.assertIsNone(out)

    def test_an_ambiguous_match_is_refused(self):
        """Two axes offering the same choices cannot be told apart."""
        authored = [
            {"label": "First check", "options": ["Yes", "No"], "correct": []},
            {"label": "Second check", "options": ["Yes", "No"], "correct": []},
        ]
        out = vertex._reconcile_axes_with_options(
            authored, json.dumps(["Yes", "No"]), json.dumps("Yes"))
        self.assertIsNone(out)

    def test_a_key_that_resolves_to_nothing_is_refused(self):
        out = vertex._reconcile_axes_with_options(
            self._authored(),
            json.dumps(["Anatomy", "Typography", "Physics"]),
            json.dumps("Something else entirely"))
        self.assertIsNone(out)

    def test_a_multi_select_key_carries_every_choice(self):
        out = vertex._reconcile_axes_with_options(
            self._authored(),
            json.dumps(["Anatomy", "Typography", "Physics"]),
            json.dumps(["Anatomy", "Physics"]))
        got = [a["correct"] for a in out if a["label"] == "Which class?"][0]
        self.assertEqual(sorted(got), ["Anatomy", "Physics"])


class TestAiDraftedTemplateKinds(TransactionCase):

    def _sections(self, item):
        return [{"title": "Questions", "items": [item]}]

    def test_a_scale_is_no_longer_downgraded(self):
        warnings = []
        out, count = vertex._normalise_template_sections(
            self._sections({"kind": "linearScale", "title": "Confidence",
                            "scale_min": 1, "scale_max": 5}), warnings)
        item = out[0]["items"][0]
        self.assertEqual(item["kind"], "linearScale")
        self.assertEqual((item["scale_min"], item["scale_max"]), (1, 5))
        self.assertEqual(count, 1)

    def test_a_rating_keeps_its_maximum(self):
        warnings = []
        out, _ = vertex._normalise_template_sections(
            self._sections({"kind": "rating", "title": "Quality",
                            "rating_max": 7}), warnings)
        self.assertEqual(out[0]["items"][0]["rating_max"], 7)

    def test_a_grid_keeps_its_rows_and_columns(self):
        warnings = []
        out, _ = vertex._normalise_template_sections(
            self._sections({"kind": "choiceGrid", "title": "Regions",
                            "rows": ["Fore", "Back"],
                            "columns": ["Clean", "Suspect"]}), warnings)
        item = out[0]["items"][0]
        self.assertEqual(item["kind"], "choiceGrid")
        self.assertEqual(item["rows"], ["Fore", "Back"])

    def test_an_unbounded_scale_is_defaulted_and_flagged(self):
        warnings = []
        out, _ = vertex._normalise_template_sections(
            self._sections({"kind": "linearScale", "title": "Confidence"}),
            warnings)
        item = out[0]["items"][0]
        self.assertEqual((item["scale_min"], item["scale_max"]), (1, 5))
        self.assertTrue(any("scale with no range" in w for w in warnings),
                        "a defaulted range must be said out loud")

    def test_a_grid_missing_its_axes_falls_back_and_says_so(self):
        warnings = []
        out, _ = vertex._normalise_template_sections(
            self._sections({"kind": "checkboxGrid", "title": "Tells"}),
            warnings)
        self.assertEqual(out[0]["items"][0]["kind"], "shortAnswer")
        self.assertTrue(any("missing its rows or columns" in w
                            for w in warnings))

    def test_a_dropdown_needs_its_choices(self):
        warnings = []
        out, _ = vertex._normalise_template_sections(
            self._sections({"kind": "dropdown", "title": "Overall",
                            "options": [{"label": "Pass", "correct": True},
                                        {"label": "Fail"}]}), warnings)
        item = out[0]["items"][0]
        self.assertEqual(item["kind"], "dropdown")
        self.assertEqual(len(item["options"]), 2)

    def test_a_genuinely_unknown_kind_is_still_kept_as_text(self):
        warnings = []
        out, _ = vertex._normalise_template_sections(
            self._sections({"kind": "hologram", "title": "Wat"}), warnings)
        self.assertEqual(out[0]["items"][0]["kind"], "shortAnswer")
        self.assertTrue(any("not a question kind" in w for w in warnings))

    def test_every_designer_kind_round_trips(self):
        """The backend's accepted set must match what the designer offers.

        `date` and `time` LEFT BOTH SIDES together. Neither is gradeable here -
        one literal, no answer key, no rubric - so an examiner could publish one
        and the candidate's answer would count for nothing. They now coerce to
        `shortAnswer` with a warning, which is asserted separately below;
        `fileUpload` was never accepted (`_walk_section` refuses it outright).
        """
        designer = [
            "multipleChoice", "checkboxes", "dropdown",
            "choiceGrid", "checkboxGrid", "linearScale", "rating",
            "shortAnswer", "paragraph",
            "comparePair", "imageAnnotation",
        ]
        for kind in designer:
            warnings = []
            item = {"kind": kind, "title": "probe"}
            if kind in ("multipleChoice", "checkboxes", "dropdown"):
                item["options"] = [{"label": "A", "correct": True},
                                   {"label": "B"}]
            if kind in ("choiceGrid", "checkboxGrid"):
                item["rows"] = ["r1"]
                item["columns"] = ["c1", "c2"]
            out, _ = vertex._normalise_template_sections(
                self._sections(item), warnings)
            self.assertEqual(
                out[0]["items"][0]["kind"], kind,
                "%r was rewritten - the designer offers it but the backend "
                "does not accept it" % kind)

    def test_a_retired_kind_is_coerced_and_SAID_OUT_LOUD(self):
        """`date` / `time` degrade to a markable question rather than storing a
        kind the client silently reads as something else."""
        for kind in ("date", "time", "fileUpload"):
            warnings = []
            out, _ = vertex._normalise_template_sections(
                self._sections({"kind": kind, "title": "When did it change?"}),
                warnings)
            self.assertEqual(
                out[0]["items"][0]["kind"], "shortAnswer",
                "%r must not survive - it has no answer key and no rubric, so "
                "the candidate's answer would count for nothing" % kind)
            self.assertTrue(
                any("not a question kind" in w for w in warnings),
                "a coerced kind has to be reported, not swallowed")

    def test_prompt_writing_keeps_its_media_and_golden_prompt(self):
        """It was MISSING from the accepted set, so a drafted prompt question
        was rewritten to a text box - losing both plates and the key."""
        warnings = []
        out, _ = vertex._normalise_template_sections(
            self._sections({
                "kind": "promptWriting",
                "title": "Write the prompt that made this",
                "media_url": "https://example.test/out.png",
                "media_url_b": "https://example.test/ref.png",
                "golden_answer": "a studio portrait, softbox lighting",
            }), warnings)
        item = out[0]["items"][0]
        self.assertEqual(item["kind"], "promptWriting")
        self.assertEqual(item["media_url"], "https://example.test/out.png")
        self.assertEqual(item["media_url_b"], "https://example.test/ref.png")
        self.assertIn("softbox", item["golden_answer"])

    def test_a_prompt_question_with_no_media_degrades_here_not_at_publish(self):
        """`_item_spec` REFUSES a prompt item with no plate, so leaving it as
        `promptWriting` would fail after the examiner had already saved it."""
        warnings = []
        out, _ = vertex._normalise_template_sections(
            self._sections({"kind": "promptWriting",
                            "title": "Write the prompt"}), warnings)
        self.assertEqual(out[0]["items"][0]["kind"], "shortAnswer")
        self.assertTrue(any("carries no image or clip" in w for w in warnings))
