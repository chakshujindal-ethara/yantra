# -*- coding: utf-8 -*-
"""R8: saving an edited answer key keeps its order and its controls.

`_sync_dimensions` wrote every axis and option at sequence 10, so an option
added in the middle of a list landed last, and it never wrote an axis's
`input_kind`, so a new checkboxes axis came back as a radio list. It also ran
after the rest of the save, so a key refused for an unknown axis still wrote
the new title. Now each axis and option keeps its place ((i + 1) * 10 unless
the row carries one), `input_kind` is written when sent, and the key is synced
first: a refused save writes nothing.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import serializers as S
from ..controllers.api import write as write_api
from ._paging_harness import call_route, status_of

ADMIN_GROUP = "assessments_be_v2.group_assessment_manager"


def _no_sequence(rows):
    """The rows as the app sends them: ids and text, no sequence."""
    return [dict({k: v for k, v in row.items() if k != "sequence"},
                 options=[{k: v for k, v in o.items() if k != "sequence"}
                          for o in row["options"]])
            for row in rows]


@tagged("-at_install", "post_install")
class TestAnEditedKeyKeepsItsShape(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(ADMIN_GROUP).id)]
        self.controller = write_api.EtpAssessmentApiWrite()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Shape %s" % uuid4().hex[:6]})

    def _template_draft(self):
        """A draft as a template run writes it: `dimensions_json` only."""
        return self.env["assessments.be.prompt.question"].create({
            "prompt_id": self.generator.id,
            "name": "Draft %s" % uuid4().hex[:6],
            "question_prompt": "Which city is the capital of France?",
            "question_type": "mcq",
            "dimensions_json": json.dumps([{
                "label": "Capital", "options": ["Paris", "Lyon", "Nice"],
                "kind": "dropdown", "correct": ["Paris"]}]),
        })

    def _draft_update(self, draft, **params):
        return call_route(write_api, self.controller, "draft_update", self.env,
                          path={"draft_id": draft.id}, **params)

    def test_a_template_draft_saves_by_axis(self):
        draft = self._template_draft()
        rows = _no_sequence(S.draft_dimensions(draft))
        self.assertTrue(rows and rows[0]["id"], "the draft is keyed by axis")
        options = rows[0]["options"]
        for option in options:
            option["is_correct"] = option["name"] == "Lyon"
        options.insert(1, {"name": "Marseille", "is_correct": False})

        out = self._draft_update(draft, dimensions=rows)

        self.assertEqual(status_of(out), 200, out)
        dim = draft.answer_dimension_ids
        self.assertEqual(dim.input_kind, "dropdown")
        lines = dim.option_line_ids.sorted("sequence")
        self.assertEqual(lines.mapped("sequence"), [10, 20, 30, 40])
        self.assertEqual(lines.mapped("name"),
                         ["Paris", "Marseille", "Lyon", "Nice"])

        # Approval is its own request, which reads the rows in their stored
        # order; this cursor still caches them in the order they were written.
        self.env.invalidate_all()
        draft.action_approve()
        bank = draft.approved_question_id.question_dimension_ids
        self.assertEqual(bank.input_kind, "dropdown")
        self.assertEqual(
            bank.option_line_ids.sorted("sequence").mapped("name"),
            ["Paris", "Marseille", "Lyon", "Nice"])
        self.assertEqual(
            bank.option_line_ids.filtered("is_correct").mapped("name"),
            ["Lyon"])

    def test_a_saved_key_survives_rebuild_answer_key(self):
        """`dimensions_json` kept the pre-edit key after an axis save, and
        Rebuild Answer Key - which reads it - brought that key back."""
        draft = self._template_draft()
        rows = _no_sequence(S.draft_dimensions(draft))
        for option in rows[0]["options"]:
            option["is_correct"] = option["name"] == "Lyon"
        rows[0]["options"].insert(1, {"name": "Marseille",
                                      "is_correct": False})

        out = self._draft_update(draft, dimensions=rows)

        self.assertEqual(status_of(out), 200, out)
        self.assertEqual(json.loads(draft.dimensions_json), [{
            "label": "Capital",
            "options": ["Paris", "Marseille", "Lyon", "Nice"],
            "kind": "dropdown", "correct": ["Lyon"]}])
        draft.action_rebuild_answer_key_from_json()
        lines = draft.answer_dimension_ids.option_line_ids.sorted("sequence")
        self.assertEqual(lines.mapped("name"),
                         ["Paris", "Marseille", "Lyon", "Nice"])
        self.assertEqual(lines.filtered("is_correct").mapped("name"), ["Lyon"])

    def test_a_new_axis_keeps_its_kind(self):
        draft = self._template_draft()
        out = self._draft_update(draft, dimensions=[{
            "label": "City", "input_kind": "dropdown", "options": [
                {"name": "Paris", "is_correct": True},
                {"name": "Lyon", "is_correct": False}]}])

        self.assertEqual(status_of(out), 200, out)
        self.assertEqual(draft.answer_dimension_ids.input_kind, "dropdown")

    def test_a_refused_draft_save_writes_nothing(self):
        draft = self._template_draft()
        name = draft.name
        rows = S.draft_dimensions(draft)
        rows[0]["id"] = 10 ** 9
        out = self._draft_update(draft, name="Renamed", dimensions=rows)

        self.assertEqual(status_of(out), 404, out)
        self.assertEqual(draft.name, name)

    def test_a_refused_bank_save_writes_nothing(self):
        question = self.env["assessments.be.question"].create({
            "name": "Bank %s" % uuid4().hex[:6], "question_type": "mcq",
            "prompt": "Pick", "difficulty": "easy",
            "generator_id": self.generator.id,
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": question.id, "name": "Capital",
            "option_line_ids": [(0, 0, {"name": n, "is_correct": n == "Paris"})
                                for n in ("Paris", "Lyon")]})
        name = question.name
        out = call_route(write_api, self.controller, "bank_update", self.env,
                         path={"question_id": question.id}, name="Renamed",
                         dimensions=[{"id": 10 ** 9, "name": "Capital",
                                      "options": [
                                          {"name": "Paris", "is_correct": True},
                                          {"name": "Lyon"}]}])

        self.assertEqual(status_of(out), 404, out)
        self.assertEqual(question.name, name)
