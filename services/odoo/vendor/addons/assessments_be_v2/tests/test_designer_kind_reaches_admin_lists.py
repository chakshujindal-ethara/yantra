# -*- coding: utf-8 -*-
"""A Form Studio question must not be CALLED an MCQ on the admin lists.

THE DEFECT. `question_type` is a closed set of seven SCORING primitives
(constants.QUESTION_TYPE_SELECTION), so `dropdown`, `linearScale`, `rating` and
`multipleChoice` all publish as `mcq` - correctly, because all four are marked
the same way: pick one keyed option. The authored control is remembered
separately, on `assessments.be.question.dimension.input_kind`, and
`publish_to_assessment` has always stored it.

What was missing is that the ADMIN serializers never sent it. The candidate's
`question_dimension` did, which is why the exam runner renders a scale as a
scale - but an assessment's Selected Questions tab and a generator's question
list read `bank_question_row`, which carried no axes and no kind at all. The
client's `Question.designerKind` therefore had nothing to read and fell through
to the engine type, printing "Objective - MCQ" over four visibly different
controls. Annotation and prompt writing looked right only because they happen to
own distinct `question_type` codes.

THE SHAPES ARE DELIBERATELY DIFFERENT, and both are asserted here:
  * the DETAIL route sends `input_kind` per axis - it already sends the tree;
  * the ROW sends one `designer_kind` scalar, because the bank list clamps at
    200 rows and embedding every axis on every row to recover one string would
    multiply the payload for a value that is identical on every axis anyway.
"""
import uuid

from odoo.tests.common import TransactionCase

from ..controllers.api.serializers import (
    bank_question_detail, bank_question_row,
)


class TestDesignerKindReachesAdminLists(TransactionCase):

    def _publish(self, item):
        form = self.env["etp.studio.form"].create({
            "client_uid": uuid.uuid4().hex,
            "title": "Kind labels %s" % uuid.uuid4().hex[:6],
            "structure_json": [{"id": "sec-1", "title": "Section one",
                                "items": [item]}],
        })
        result = form.publish_to_assessment()
        self.assertFalse(result.get("problems"), result.get("problems"))
        questions = self.env["assessments.be.question"].search(
            [("source_ref", "like", "form:%s#%%" % form.client_uid)])
        self.assertEqual(len(questions), 1, "expected exactly one question")
        return questions

    def _choice(self, kind):
        return {"id": "item-1", "kind": kind, "title": "Pick one",
                # `label`, not `text` - that is the key `_options_of` reads and
                # the key form_models.dart writes.
                "options": [{"id": "o1", "label": "Yes", "correct": True},
                            {"id": "o2", "label": "No"}]}

    # ── the publish path stores it ───────────────────────────────────────────

    def test_publish_stamps_the_authored_kind_on_the_axis(self):
        q = self._publish(self._choice("dropdown"))
        self.assertEqual(q.question_type, "mcq",
                         "the SCORING type is still mcq - that is correct")
        self.assertEqual(q.question_dimension_ids.mapped("input_kind"),
                         ["dropdown"])

    # ── the row carries the scalar ───────────────────────────────────────────

    def test_the_row_names_the_control_a_dropdown_was_drawn_as(self):
        row = bank_question_row(self._publish(self._choice("dropdown")))

        self.assertEqual(row["question_type"], "mcq")
        self.assertEqual(row["designer_kind"], "dropdown")

    def test_a_linear_scale_is_not_reported_as_a_plain_mcq(self):
        q = self._publish({"id": "item-1", "kind": "linearScale",
                           "title": "How confident?", "scale_min": 1,
                           "scale_max": 5, "golden_answer": "4"})

        self.assertEqual(bank_question_row(q)["designer_kind"], "linearScale")

    def test_a_rating_is_not_reported_as_a_plain_mcq(self):
        q = self._publish({"id": "item-1", "kind": "rating",
                           "title": "Rate sharpness", "rating_max": 5,
                           "golden_answer": "3"})

        self.assertEqual(bank_question_row(q)["designer_kind"], "rating")

    def test_a_multiple_choice_still_names_itself(self):
        """The kind that really IS an MCQ keeps saying so, rather than going
        empty and leaving the client to guess from the engine type."""
        row = bank_question_row(self._publish(self._choice("multipleChoice")))

        self.assertEqual(row["designer_kind"], "multipleChoice")

    def test_checkboxes_publish_as_msq_and_still_name_the_control(self):
        item = self._choice("checkboxes")
        item["options"][1]["correct"] = True
        q = self._publish(item)

        row = bank_question_row(q)
        self.assertEqual(row["question_type"], "msq")
        self.assertEqual(row["designer_kind"], "checkboxes")

    # ── the detail carries it per axis ───────────────────────────────────────

    def test_the_detail_sends_the_kind_on_every_axis(self):
        detail = bank_question_detail(self._publish(self._choice("dropdown")))

        self.assertTrue(detail["dimensions"], "the detail must send its axes")
        for dim in detail["dimensions"]:
            self.assertEqual(dim["input_kind"], "dropdown")

    def test_a_grid_names_its_kind_on_each_row_axis(self):
        """A grid publishes one axis PER ROW, and the client reads the first
        axis that names a kind - so every one of them has to carry it."""
        q = self._publish({
            "id": "item-1", "kind": "choiceGrid", "title": "Regions",
            "rows": ["Foreground", "Background"],
            "columns": ["Clean", "Suspect"],
            "grid_key": {"0": "Clean", "1": "Suspect"},
        })

        detail = bank_question_detail(q)
        self.assertEqual(len(detail["dimensions"]), 2)
        self.assertEqual({d["input_kind"] for d in detail["dimensions"]},
                         {"choiceGrid"})
        self.assertEqual(bank_question_row(q)["designer_kind"], "choiceGrid")

    # ── nothing is invented where there is nothing to say ────────────────────

    def test_a_question_with_no_axes_reports_no_kind_rather_than_a_wrong_one(
            self):
        """A subjective question has no keyed axis, so there is no authored
        control to name - and the key must be present and empty rather than
        absent, which the client would read as a missing field."""
        q = self._publish({"id": "item-1", "kind": "paragraph",
                           "title": "Explain your reasoning",
                           "golden_answer": "Because the edit is visible."})

        row = bank_question_row(q)
        self.assertEqual(row["question_type"], "subjective_rubric")
        self.assertIn("designer_kind", row)
        self.assertEqual(row["designer_kind"], "")

    def test_a_hand_authored_bank_question_is_unaffected(self):
        """A question created outside Form Studio has no `input_kind`, which is
        the documented default. It must serialize as empty, not raise."""
        q = self.env["assessments.be.question"].create({
            "name": "Hand authored",
            "prompt": "Pick one",
            "question_type": "mcq",
        })

        self.assertEqual(bank_question_row(q)["designer_kind"], "")
        self.assertEqual(bank_question_detail(q)["dimensions"], [])
