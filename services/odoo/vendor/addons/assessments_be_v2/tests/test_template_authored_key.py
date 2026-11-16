# -*- coding: utf-8 -*-
"""The examiner's answer key travels from the template onto generated axes.

THE DEFECT THIS LOCKS DOWN, measured before it was fixed.

A task template's axes reached generation as a SHAPE with no key.
`task_template._axes()` read only `{label, options, kind}` - never `correct` -
and `vertex._authored_axes` then hardcoded `"correct": []` on every axis, with a
docstring arguing that "which option is correct is per generated instance and
belongs to the model or the reviewer".

That reasoning holds for an axis the examiner only drew the shape of. It is
wrong for one they keyed by hand, and the cost was silent: an axis with no keyed
option is not a component (`question._keyed_dimension_count`), so it entered
NEITHER the numerator nor the denominator.

Reproduced on live assessment 140. A template drew six Yes/No checks with the
correct answer marked on each. A candidate answered all six correctly. The
denominator was 3, not 9 - the six authored axes contributed nothing - and the
paper reported 1/3, 33%, FAIL. Nine live bank rows carried axes with zero keyed
options, every one of them generated from a template.

THE RULE NOW: the examiner's key is carried when they stated one, and is still
never invented when they did not. `test_template_binding.test_no_key_is_ever_
invented` pins the other half.

WHY LABELS, NOT INDICES. A key is stored as the option's own text, so it
survives a re-ordering of the options - the same reason
`_reconcile_axes_with_options` resolves to labels. An integer key on a scale or
rating is matched AS TEXT against the point labels, never used as a position;
read as an index, a model or examiner answering "1" keys the SECOND point and
every candidate who picks correctly is marked wrong.
"""
import json

from odoo.tests.common import TransactionCase

from odoo.addons.assessments_be_v2.services import vertex


class TestTemplateAuthoredKeyReachesTheAxes(TransactionCase):
    """`_axes()` / `answer_contract()` carry what the designer marked."""

    def _template(self, items, response="single_choice"):
        return self.env["assessments.be.task.template"].create({
            "name": "Keyed template",
            "response": response,
            "structure_json": [{"title": "Checks", "items": items}],
        })

    def _choice(self, title, labels, correct=()):
        return {
            "kind": "multipleChoice",
            "title": title,
            "options": [
                dict({"id": "o%d" % i, "label": lab},
                     **({"correct": True} if lab in correct else {}))
                for i, lab in enumerate(labels)
            ],
        }

    # -- the four key carriers Form Studio writes ----------------------

    def test_a_marked_option_becomes_the_axis_key(self):
        tpl = self._template([self._choice("Is it sharp?", ["Yes", "No"],
                                           correct=("Yes",))])
        axes = tpl._axes()
        self.assertEqual(len(axes), 1)
        self.assertEqual(axes[0]["correct"], ["Yes"],
                         "the examiner marked Yes correct and the axis must "
                         "carry it, or the axis is not markable at all")

    def test_an_unmarked_item_stays_keyless(self):
        """The ordinary reusable-template case, unchanged."""
        tpl = self._template([self._choice("Which class?", ["A", "B"])])
        self.assertEqual(tpl._axes()[0]["correct"], [])

    def test_a_multi_select_carries_every_marked_option(self):
        tpl = self._template(
            [{"kind": "checkboxes", "title": "Which apply?",
              "options": [{"label": "Lighting", "correct": True},
                          {"label": "Anatomy"},
                          {"label": "Typography", "correct": True}]}])
        self.assertEqual(sorted(tpl._axes()[0]["correct"]),
                         ["Lighting", "Typography"])

    def test_a_scale_golden_point_becomes_the_key(self):
        """`scale_golden` is a NUMBER; the axis options are its point labels."""
        tpl = self._template(
            [{"kind": "linearScale", "title": "Severity",
              "scale_min": 1, "scale_max": 5, "scale_golden": 4}])
        axis = tpl._axes()[0]
        self.assertEqual(axis["options"], ["1", "2", "3", "4", "5"])
        self.assertEqual(axis["correct"], ["4"],
                         "4 is the point LABELLED 4, not the fifth position")

    def test_a_rating_golden_becomes_the_key(self):
        tpl = self._template(
            [{"kind": "rating", "title": "Quality", "rating_max": 5,
              "rating_golden": 3}])
        self.assertEqual(tpl._axes()[0]["correct"], ["3"])

    def test_a_scale_key_carried_only_in_golden_answer_is_still_read(self):
        """The wire shape `studio_form._item_spec` actually reads.

        The client publishes a scale/rating key BOTH as the typed field and as
        the `golden_answer` digit string the server validates against. A form
        written before the typed pickers existed - or one round-tripped through
        the server - carries it ONLY there, so reading just `scale_golden` would
        drop the key for exactly those forms.
        """
        tpl = self._template(
            [{"kind": "linearScale", "title": "Severity",
              "scale_min": 1, "scale_max": 5, "golden_answer": "2"}])
        self.assertEqual(tpl._axes()[0]["correct"], ["2"])

    def test_a_golden_point_outside_the_range_is_dropped(self):
        """A key naming nothing is the unanswerable state, so it is not stored."""
        tpl = self._template(
            [{"kind": "linearScale", "title": "Severity",
              "scale_min": 1, "scale_max": 5, "scale_golden": 9}])
        self.assertEqual(tpl._axes()[0]["correct"], [])

    # -- grids: one axis per row, one key per row ----------------------

    def test_a_grid_keys_each_row_independently(self):
        tpl = self._template(
            [{"kind": "choiceGrid", "title": "Regions",
              "rows": ["Foreground", "Background"],
              "columns": ["Clean", "Suspect"],
              "grid_key": {"0": "Suspect", "1": "Clean"}}])
        axes = {a["label"]: a["correct"] for a in tpl._axes()}
        self.assertEqual(axes["Regions - Foreground"], ["Suspect"])
        self.assertEqual(axes["Regions - Background"], ["Clean"])

    def test_a_grid_row_nobody_keyed_stays_keyless(self):
        """A partially keyed grid keeps its keyed rows and does not invent the
        rest - the keyed rows still score."""
        tpl = self._template(
            [{"kind": "choiceGrid", "title": "Regions",
              "rows": ["Foreground", "Background"],
              "columns": ["Clean", "Suspect"],
              "grid_key": {"0": "Suspect"}}])
        axes = {a["label"]: a["correct"] for a in tpl._axes()}
        self.assertEqual(axes["Regions - Foreground"], ["Suspect"])
        self.assertEqual(axes["Regions - Background"], [])

    def test_a_grid_key_naming_a_column_that_does_not_exist_is_dropped(self):
        tpl = self._template(
            [{"kind": "choiceGrid", "title": "Regions",
              "rows": ["Foreground"],
              "columns": ["Clean", "Suspect"],
              "grid_key": {"0": "Nonexistent"}}])
        self.assertEqual(tpl._axes()[0]["correct"], [])

    def test_a_checkbox_grid_row_keeps_every_keyed_column(self):
        """A checkbox grid row is an MSQ, so its key is a LIST.

        This editor and the Form Studio designer host the same item sheet, so a
        key shape one understands and the other does not is lost on the next
        save. Before the fix `str(want or "").strip()` stringified the list
        itself ("['Clean', 'Suspect']"), matched no column label, and left the
        row silently keyless - which drops it out of both sides of the paper.
        """
        tpl = self._template(
            [{"kind": "checkboxGrid", "title": "Regions",
              "rows": ["Foreground", "Background"],
              "columns": ["Clean", "Suspect", "Unclear"],
              "grid_key": {"0": ["Suspect", "Unclear"], "1": ["Clean"]}}])
        axes = {a["label"]: a["correct"] for a in tpl._axes()}
        self.assertEqual(
            sorted(axes["Regions - Foreground"]), ["Suspect", "Unclear"])
        self.assertEqual(axes["Regions - Background"], ["Clean"])

    def test_a_multi_key_entry_is_coerced_per_entry(self):
        """Every entry gets the same strip the scalar form got, not just the
        first - otherwise a list reintroduces the check/write disagreement
        `studio_form._grid_row_key` exists to close."""
        tpl = self._template(
            [{"kind": "checkboxGrid", "title": "Regions",
              "rows": ["Foreground"],
              "columns": ["Clean", "Suspect"],
              "grid_key": {"0": [" Suspect", "Clean "]}}])
        self.assertEqual(
            sorted(tpl._axes()[0]["correct"]), ["Clean", "Suspect"])

    # -- the contract the generator is actually handed -----------------

    def test_the_answer_contract_carries_the_key(self):
        """`answer_contract()` is what reaches the model and the draft, so the
        key has to be present THERE, not only in `_axes()`."""
        tpl = self._template([self._choice("Is it sharp?", ["Yes", "No"],
                                           correct=("Yes",))])
        dims = tpl.answer_contract().get("dimensions") or []
        self.assertEqual([d["correct"] for d in dims], [["Yes"]])


class TestAuthoredKeySurvivesIntoTheDraft(TransactionCase):
    """The vertex half: `_authored_axes` and the reconciliation precedence."""

    def test_authored_axes_carries_a_stated_key(self):
        axes = [{"label": "Is it sharp?", "options": ["Yes", "No"],
                 "kind": "multipleChoice", "correct": ["Yes"]}]
        out = vertex._authored_axes(axes, {})
        self.assertEqual(out[0]["correct"], ["Yes"])

    def test_the_stored_key_is_the_AXIS_spelling_not_the_key_spelling(self):
        """Casing and punctuation in the authored key must not cost marks, and
        must not end up stored as a second spelling of the same option."""
        axes = [{"label": "Is it sharp?", "options": ["Yes", "No"],
                 "correct": ["  yes."]}]
        self.assertEqual(vertex._authored_axes(axes, {})[0]["correct"], ["Yes"])

    def test_a_key_naming_no_option_is_dropped(self):
        axes = [{"label": "Is it sharp?", "options": ["Yes", "No"],
                 "correct": ["Maybe"]}]
        self.assertEqual(vertex._authored_axes(axes, {})[0]["correct"], [],
                         "a key matching no option publishes a question whose "
                         "key matches nothing")

    def test_the_examiner_key_OUTRANKS_the_models(self):
        """Reconciliation exists to borrow the model's key for a KEYLESS axis.

        Overwriting a stated answer with the model's would be the same defect in
        the opposite direction - the candidate marked against an answer the
        examiner did not choose.
        """
        authored = [{"label": "Which class?",
                     "options": ["Anatomy", "Typography", "Physics"],
                     "kind": "multipleChoice", "correct": ["Anatomy"]}]
        out = vertex._reconcile_axes_with_options(
            authored,
            json.dumps(["Anatomy", "Typography", "Physics"]),
            json.dumps("Typography"))
        self.assertIsNotNone(out)
        self.assertEqual(out[0]["correct"], ["Anatomy"],
                         "the model's Typography must not displace the "
                         "examiner's Anatomy")

    def test_a_keyless_axis_still_borrows_the_models_key(self):
        """The existing behaviour, which must not regress."""
        authored = [{"label": "Which class?",
                     "options": ["Anatomy", "Typography", "Physics"],
                     "kind": "multipleChoice", "correct": []}]
        out = vertex._reconcile_axes_with_options(
            authored,
            json.dumps(["Anatomy", "Typography", "Physics"]),
            json.dumps("Typography"))
        self.assertEqual(out[0]["correct"], ["Typography"])
