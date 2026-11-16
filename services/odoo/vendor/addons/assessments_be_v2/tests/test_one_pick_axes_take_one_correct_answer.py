# -*- coding: utf-8 -*-
"""R8: an axis a candidate answers with one pick takes one correct answer.

The exam lets a candidate tick several options on an axis only on an msq, or
when the axis is drawn as checkboxes; everywhere else they pick one, and
scoring is an exact-set match per axis. So two correct options on a one-pick
axis is a key nobody can earn. The editors' save routes and the template save
now follow that rule (`constants.takes_one_answer`): image_ab takes one
verdict per axis, a checkboxes axis on an mcq takes several, and an A/B rating
axis left to the grader needs no key as long as some axis is keyed. Approval
and the import lanes are pinned in
`test_approval_and_imports_refuse_an_unearnable_key`.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..constants import takes_one_answer
from ..controllers.api import task_templates as templates_api
from ..controllers.api import write as write_api
from ._paging_harness import call_route, status_of

ADMIN_GROUP = "assessments_be_v2.group_assessment_manager"


def _axis(label, options, correct=(), kind=None):
    row = {"label": label, "options": [
        {"name": o, "is_correct": o in correct} for o in options]}
    if kind is not None:
        row["input_kind"] = kind
    return row


@tagged("-at_install", "post_install")
class TestOnePickAxesTakeOneCorrectAnswer(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(ADMIN_GROUP).id)]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "One pick %s" % uuid4().hex[:6]})

    def _draft(self, question_type):
        return self.env["assessments.be.prompt.question"].create({
            "prompt_id": self.generator.id,
            "name": "Draft %s" % uuid4().hex[:6],
            "question_prompt": "Judge the two pictures.",
            "question_type": question_type,
        })

    def _save(self, draft, rows):
        return call_route(write_api, write_api.EtpAssessmentApiWrite(),
                          "draft_update", self.env,
                          path={"draft_id": draft.id}, dimensions=rows)

    def test_takes_one_answer_matches_the_exam(self):
        for qtype, kind, expected in (
                ("mcq", "", True), ("mcq", "dropdown", True),
                ("mcq", "checkboxes", False), ("mcq", "checkboxGrid", False),
                ("msq", "", False), ("image_ab", "", True),
                ("image_ab", "checkboxes", False), ("", None, True)):
            self.assertIs(takes_one_answer(qtype, kind), expected,
                          (qtype, kind))

    def test_an_ab_axis_takes_one_verdict(self):
        draft = self._draft("image_ab")
        out = self._save(draft, [_axis("Overall", ["A", "B", "Same"],
                                       correct=("A", "B"))])

        self.assertEqual(status_of(out), 422, out)
        self.assertIn("Overall", out["error"]["message"])
        self.assertFalse(draft.answer_dimension_ids)
        self.assertIsNotNone(write_api.answer_key_problem(
            "image_ab", ["A", "B", "Same"], ["A", "B"]))

    def test_a_checkbox_axis_on_a_single_choice_paper_takes_several(self):
        draft = self._draft("mcq")
        out = self._save(draft, [_axis(
            "Cities", ["Paris", "Lyon", "Nice"], correct=("Paris", "Lyon"),
            kind="checkboxes")])

        self.assertEqual(status_of(out), 200, out)
        self.assertEqual(
            draft.answer_dimension_ids.option_line_ids.filtered(
                "is_correct").mapped("name"), ["Paris", "Lyon"])
        # A radio axis on the same paper still takes one.
        out = self._save(draft, [_axis(
            "Cities", ["Paris", "Lyon", "Nice"], correct=("Paris", "Lyon"))])
        self.assertEqual(status_of(out), 422, out)

    def test_an_ab_axis_judged_not_keyed_still_saves(self):
        draft = self._draft("image_ab")
        out = self._save(draft, [
            _axis("Overall", ["A", "B"], correct=("A",)),
            _axis("Rating", ["1", "2", "3", "4", "5"])])

        self.assertEqual(status_of(out), 200, out)
        self.assertEqual(len(draft.answer_dimension_ids), 2)
        # Nothing keyed anywhere still scores nobody.
        out = self._save(draft, [_axis("Overall", ["A", "B"]),
                                 _axis("Rating", ["1", "2", "3"])])
        self.assertEqual(status_of(out), 422, out)

    def _template(self, kind, **extra):
        return {"name": "Capital %s" % uuid4().hex[:6],
                "response": "single_choice",
                "structure": [{"items": [dict({
                    "kind": kind, "title": "Capital",
                    "options": [{"label": "Paris", "correct": True},
                                {"label": "Lyon", "correct": True},
                                {"label": "Nice"}]}, **extra)]}]}

    def test_a_multi_select_image_block_takes_several(self):
        """An image block's "Allow several answers" was ignored: refused at
        save, and drawn as one pick in the exam (its axis was not checkboxes)."""
        controller = templates_api.AssessmentsBeTaskTemplateApi()
        media = {"media_url": "https://example.test/weld.png"}
        saved = call_route(
            templates_api, controller, "task_template_save", self.env,
            template=self._template("imageBlock", multi_select=True, **media))
        self.assertEqual(status_of(saved), 200, saved)
        template = self.env["assessments.be.task.template"].browse(
            saved["data"]["id"])
        self.assertEqual([a["kind"] for a in template._axes()], ["checkboxes"])

        refused = call_route(
            templates_api, controller, "task_template_save", self.env,
            template=self._template("imageBlock", multi_select=False, **media))
        self.assertEqual(status_of(refused), 422, refused)

    def test_a_template_cannot_save_an_unearnable_key(self):
        Template = self.env["assessments.be.task.template"]
        controller = templates_api.AssessmentsBeTaskTemplateApi()
        before = Template.search_count([])

        refused = call_route(templates_api, controller, "task_template_save",
                             self.env, template=self._template("multipleChoice"))
        self.assertEqual(status_of(refused), 422, refused)
        self.assertIn("Capital", refused["error"]["message"])
        self.assertEqual(Template.search_count([]), before, "nothing saved")

        saved = call_route(templates_api, controller, "task_template_save",
                           self.env, template=self._template("checkboxes"))
        self.assertEqual(status_of(saved), 200, saved)
        self.assertEqual(Template.search_count([]), before + 1)
