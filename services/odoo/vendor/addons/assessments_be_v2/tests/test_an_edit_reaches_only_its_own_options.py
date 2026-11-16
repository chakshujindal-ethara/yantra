# -*- coding: utf-8 -*-
"""An answer-key edit reaches only the edited question's own options.

`_sync_dimensions` wrote any option id the client sent, so an edit of one
question carrying another question's option id rewrote THAT question's key -
past `protect_answers`, which only guards the question being edited. Such an
id is refused like an unknown axis, and nothing is written.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import serializers as S
from ..controllers.api import write as write_api
from ._paging_harness import call_route, status_of

ADMIN_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class TestAnEditReachesOnlyItsOwnOptions(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(ADMIN_GROUP).id)]
        self.controller = write_api.EtpAssessmentApiWrite()

    def _question(self):
        return self.env["assessments.be.question"].create({
            "name": "Key %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "Which city is the capital of France?",
            "question_dimension_ids": [(0, 0, {
                "name": "Capital",
                "option_line_ids": [
                    (0, 0, {"name": n, "sequence": (i + 1) * 10,
                            "is_correct": i == 0})
                    for i, n in enumerate(("Paris", "Lyon"))]})],
        })

    def test_another_questions_option_id_is_refused(self):
        edited, other = self._question(), self._question()
        rows = S.bank_question_detail(edited)["dimensions"]
        theirs = other.question_dimension_ids.option_line_ids.sorted("sequence")
        # The edited key, with one option id swapped for the other question's.
        rows[0]["options"][1] = {"id": theirs[0].id, "name": "Rewritten",
                                 "is_correct": False}

        out = call_route(write_api, self.controller, "bank_update", self.env,
                         path={"question_id": edited.id}, dimensions=rows)

        self.assertEqual(status_of(out), 404, out)
        self.assertEqual((theirs[0].name, theirs[0].is_correct),
                         ("Paris", True), "the other question's key is intact")
        self.assertEqual(
            edited.question_dimension_ids.option_line_ids.mapped("name"),
            ["Paris", "Lyon"], "a refused edit writes nothing")

    def test_a_sibling_axis_option_id_is_refused(self):
        """The check was scoped to the whole question, so an id from another
        axis of the same question passed and rewrote that axis's option."""
        question = self._question()
        question.question_dimension_ids = [(0, 0, {
            "name": "Country", "sequence": 20,
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": (i + 1) * 10,
                        "is_correct": i == 0})
                for i, n in enumerate(("France", "Spain", "Italy"))]})]
        rows = S.bank_question_detail(question)["dimensions"]
        before = [(o.name, o.is_correct) for o in question
                  .question_dimension_ids.option_line_ids.sorted("id")]
        # Spain moves into the first axis's list, renamed.
        spain = rows[1]["options"].pop(1)
        rows[0]["options"].append({"id": spain["id"], "name": "Rewritten",
                                   "is_correct": False})

        out = call_route(write_api, self.controller, "bank_update", self.env,
                         path={"question_id": question.id}, dimensions=rows)

        self.assertEqual(status_of(out), 404, out)
        self.assertEqual([(o.name, o.is_correct) for o in question
                          .question_dimension_ids.option_line_ids
                          .sorted("id")], before, "a refused edit writes nothing")

    def test_its_own_options_are_edited_and_the_rest_saved(self):
        question = self._question()
        rows = S.bank_question_detail(question)["dimensions"]
        rows[0]["options"][1]["name"] = "Marseille"

        out = call_route(write_api, self.controller, "bank_update", self.env,
                         path={"question_id": question.id}, dimensions=rows,
                         name="Capital cities")

        self.assertEqual(status_of(out), 200, out)
        self.assertEqual(question.name, "Capital cities")
        self.assertEqual(question.question_dimension_ids.option_line_ids
                         .sorted("sequence").mapped("name"),
                         ["Paris", "Marseille"])

    def test_a_key_that_could_never_score_is_refused(self):
        question = self._question()
        for change in ("one option", "no correct option"):
            with self.subTest(change):
                rows = S.bank_question_detail(question)["dimensions"]
                if change == "one option":
                    rows[0]["options"] = rows[0]["options"][:1]
                else:
                    for option in rows[0]["options"]:
                        option["is_correct"] = False
                out = call_route(write_api, self.controller, "bank_update",
                                 self.env, path={"question_id": question.id},
                                 dimensions=rows)
                self.assertEqual(status_of(out), 422, out)
