"""The rough edges found in the 2026-09-29 production test, closed.

1. An admin renaming an image_ab rating or option keeps the flaw plan's
   construction keys in step, so the drift guard does not score every answer 0.
2. A side-free (Yes/No) comparison tells the judge, as item data, that there is
   no Response A or B - and the instructions themselves stay byte-identical,
   because their fingerprint gates which verdicts candidates may see.
3. A rubric with rating items is held as a draft while the ratings are blank,
   like every other type whose checks are marks.
4. A generation run stuck in `finalizing` is settled after 15 minutes.
5. A zero-token call is not priced (no "no token price" noise for Veo polls).
"""
import json
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.constants import (
    ab_construction_keys, ab_key_drift, ab_materialized_keys, parse_flaw_plan,
)
from odoo.addons.assessments_be_v2.services import model_catalog, scoring

# The MODULE, not the class: a TestCase bound in this module's globals would be
# collected and run a second time here.
from . import test_a_justification_typed_before_the_verdict_is_kept as _draft

AB = ["Response A", "Response B", "Both Good", "Both Bad"]
YES_NO_LABELS = ["1. Is this reference an item?",
                 "2. Same exact item as tagged?",
                 "3. Different source than the video?",
                 "4. Single, isolated item on its own?"]
YES_NO_OPTIONS = [["Yes", "No", "Nothing meaningful shown"],
                  ["Yes", "No"], ["Yes", "No"], ["Yes", "No"]]
YES_NO_KEY = ["Yes", "Yes", "Yes", "No"]


@tagged("-at_install", "post_install")
class TestAnEditedAnswerKeyStillScores(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Edited key %s" % uuid4().hex[:6]})

    def _question(self, labels, options, key, plan_labels=True):
        codes = [label.upper() for label in labels]
        plan = {"construction_keys": dict(zip(codes, key))}
        if plan_labels:
            plan["dimension_labels"] = dict(zip(codes, labels))
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6], "question_type": "image_ab",
            "prompt": "Compare the two.", "generator_id": self.generator.id,
            "flaw_plan_json": json.dumps(plan),
        })
        for label, opts, correct in zip(labels, options, key):
            self.env["assessments.be.question.dimension"].create({
                "question_id": question.id, "name": label,
                "option_line_ids": [
                    (0, 0, {"name": o, "sequence": (i + 1) * 10,
                            "is_correct": o == correct})
                    for i, o in enumerate(opts)],
            })
        return question

    @staticmethod
    def _drift(question):
        keys = ab_construction_keys(question.flaw_plan_json)
        return ab_key_drift(ab_materialized_keys(
            question.question_dimension_ids, keys,
            parse_flaw_plan(question.flaw_plan_json).get("dimension_labels")),
            keys)

    @staticmethod
    def _rows(question, rename_dim=None, rename_option=None):
        rows = []
        for dim in question.question_dimension_ids:
            rows.append({
                "id": dim.id, "sequence": dim.sequence,
                "name": (rename_dim or {}).get(dim.name, dim.name),
                "options": [{
                    "id": o.id, "sequence": o.sequence,
                    "is_correct": o.is_correct,
                    "name": (rename_option or {}).get(o.name, o.name),
                } for o in dim.option_line_ids],
            })
        return rows

    def _sync(self, question, rows):
        from ..controllers.api import write
        denied = write._sync_dimensions(
            question, rows, "question_dimension_ids", "name",
            protect_answers=False)
        self.assertIsNone(denied)
        question.invalidate_recordset()

    def test_renaming_a_yes_no_option_and_axis_keeps_the_key(self):
        question = self._question(YES_NO_LABELS, YES_NO_OPTIONS, YES_NO_KEY)
        self.assertEqual(self._drift(question), [], "sound before the edit")

        self._sync(question, self._rows(
            question,
            rename_dim={YES_NO_LABELS[3]: "4. Is it alone in the picture?"},
            rename_option={"Yes": "Yes, it is"}))

        self.assertEqual(self._drift(question), [])
        self.assertIn("Yes, it is", ab_construction_keys(
            question.flaw_plan_json).values())

    def test_renaming_an_a_b_axis_keeps_the_key(self):
        labels = ["Instruction Following", "Overall Choice"]
        question = self._question(
            labels, [AB, ["Response A", "Response B"]],
            ["Response B", "Response B"], plan_labels=False)
        self.assertEqual(self._drift(question), [])

        self._sync(question, self._rows(
            question, rename_dim={"Overall Choice": "Final pick"}))

        self.assertEqual(self._drift(question), [])

    def test_editing_a_draft_answer_key_saves(self):
        # Draft axes are named by `label`, not `name`: the shared key reader
        # raised AttributeError here, a 500 on stage 2026-10-13.
        labels = ["Instruction Following", "Overall Choice"]
        codes = [label.upper() for label in labels]
        draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": self.generator.id, "name": "Draft",
            "question_type": "image_ab",
            "flaw_plan_json": json.dumps({"construction_keys": dict(
                zip(codes, ["Response B", "Response B"]))}),
            "answer_dimension_ids": [(0, 0, {
                "label": label, "option_line_ids": [
                    (0, 0, {"name": o, "is_correct": o == "Response B"})
                    for o in AB]}) for label in labels],
        })
        rows = [{"id": d.id, "sequence": d.sequence, "label": d.label,
                 "options": [{"id": o.id, "sequence": o.sequence,
                              "name": o.name,
                              "is_correct": o.name == "Response A"}
                             for o in d.option_line_ids]}
                for d in draft.answer_dimension_ids]
        from ..controllers.api import write
        self.assertIsNone(write._sync_dimensions(
            draft, rows, "answer_dimension_ids", "label",
            protect_answers=False))
        self.assertEqual(set(ab_construction_keys(
            draft.flaw_plan_json).values()), {"Response A"})


@tagged("-at_install", "post_install")
class TestASideFreeComparisonIsNotDescribedAsAB(TransactionCase):

    def _question(self, options):
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6], "question_type": "image_ab",
            "prompt": "A tagged frame on the left, a reference on the right.",
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": question.id, "name": "Same exact item?",
            "option_line_ids": [(0, 0, {"name": o, "is_correct": i == 0})
                                for i, o in enumerate(options)],
        })
        return question

    def test_a_yes_no_item_says_there_is_no_response_a_or_b(self):
        material = scoring._question_material(self._question(["Yes", "No"]))
        self.assertIn("images", material)
        self.assertIn("not a choice between Response A", material["images"])

    def test_an_a_b_item_is_unchanged(self):
        self.assertNotIn("images", scoring._question_material(
            self._question(AB)))

    def test_the_instructions_are_not_touched(self):
        # Their fingerprint gates which verdicts candidates see.
        self.assertNotIn("left and a right image",
                         scoring._get_scoring_prompt())


@tagged("-at_install", "post_install")
class TestARubricWithBlankRatingsIsHeld(
        _draft.TestAJustificationTypedBeforeTheVerdictIsKept):
    """Reuses the image_ab draft harness on a subjective_rubric with axes."""

    def _rubric(self):
        question = self.Question.create({
            "name": "Rubric %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Evaluate the submission.",
            "generator_id": self.generator.id,
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": question.id, "name": "Is the split right?",
            "option_line_ids": [
                (0, 0, {"name": "Yes", "sequence": 10, "is_correct": True}),
                (0, 0, {"name": "No", "sequence": 20}),
            ],
        })
        return question

    def test_prose_with_blank_ratings_is_a_draft(self):
        question = self._rubric()
        evaluator, user = self._sitting(question)

        self._answer(evaluator, user, question, justification=self.PROSE)

        row = self._row(evaluator, question)
        self.assertEqual(len(row), 1)
        self.assertEqual(row.state, "draft", "blank ratings are not an answer")
        self.assertEqual(row.justification, self.PROSE)

    def test_prose_on_a_rubric_whose_axis_has_nothing_to_pick_submits(self):
        # A Form Studio text item is an axis with no options: it can never be
        # picked, so it must not hold the prose back as a draft forever.
        question = self._rubric()
        question.question_dimension_ids.option_line_ids.unlink()
        evaluator, user = self._sitting(question)

        reply = self._answer(evaluator, user, question,
                             justification=self.PROSE)

        self.assertTrue(reply.get("ok"), reply)
        self.assertEqual(self._row(evaluator, question).state, "submitted")

    def test_ratings_and_prose_are_complete(self):
        question = self._rubric()
        evaluator, user = self._sitting(question)
        pick = question.question_dimension_ids.option_line_ids.filtered(
            "is_correct")

        reply = self._answer(evaluator, user, question,
                             justification=self.PROSE,
                             selected_option_ids=pick.ids)

        self.assertTrue(reply.get("ok"), reply)
        self.assertEqual(self._row(evaluator, question).state, "submitted")

    def test_ratings_without_optional_prose_are_complete(self):
        question = self._rubric()
        evaluator, user = self._sitting(question)
        pick = question.question_dimension_ids.option_line_ids.filtered(
            "is_correct")

        reply = self._answer(evaluator, user, question,
                             selected_option_ids=pick.ids)

        self.assertTrue(reply.get("ok"), reply)
        self.assertEqual(self._row(evaluator, question).state, "submitted")


@tagged("-at_install", "post_install")
class TestAStuckFinalizingRunIsSettled(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Prompt = self.env["assessments.be.prompt"]

    def _stuck(self, minutes_ago, with_draft=False):
        prompt = self.Prompt.create({"name": "Stuck %s" % uuid4().hex[:6]})
        started = fields.Datetime.now() - timedelta(minutes=minutes_ago + 5)
        prompt.write({"sop_gen_state": "finalizing",
                      "sop_gen_started_at": started})
        if with_draft:
            self.env["assessments.be.prompt.question"].create({
                "prompt_id": prompt.id, "name": "Draft",
                "question_type": "mcq"})
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be_prompt SET write_date = %s WHERE id = %s",
            [fields.Datetime.now() - timedelta(minutes=minutes_ago),
             prompt.id])
        prompt.invalidate_recordset()
        return prompt

    def _settle(self):
        # The cron commits per run; a test cursor forbids that.
        with patch.object(self.env.cr, "commit", lambda *a, **k: None):
            self.Prompt._settle_stuck_finalizing()

    def test_a_run_stuck_15_minutes_with_no_drafts_fails_with_advice(self):
        prompt = self._stuck(20)
        self._settle()
        self.assertEqual(prompt.sop_gen_state, "failed")
        self.assertIn("Generate questions again", prompt.sop_gen_error)
        self.assertTrue(prompt.sop_gen_finished_at)

    def test_a_run_whose_drafts_landed_is_done(self):
        prompt = self._stuck(20, with_draft=True)
        self._settle()
        self.assertEqual(prompt.sop_gen_state, "done")

    def test_a_run_from_before_the_deploy_keeps_its_drafts(self):
        # Stuck before `sop_gen_started_at` existed: no start time recorded.
        prompt = self._stuck(20, with_draft=True)
        self.env.cr.execute(
            "UPDATE assessments_be_prompt SET sop_gen_started_at = NULL "
            "WHERE id = %s", [prompt.id])
        self.env.cr.execute(
            "UPDATE assessments_be_prompt_question SET create_date = %s "
            "WHERE prompt_id = %s",
            [fields.Datetime.now() - timedelta(minutes=30), prompt.id])
        prompt.invalidate_recordset()

        self._settle()

        self.assertEqual(prompt.sop_gen_state, "done",
                         "its drafts landed; 'failed' would ask to pay again")

    def test_a_recent_finalizing_run_is_left_alone(self):
        prompt = self._stuck(3)
        self._settle()
        self.assertEqual(prompt.sop_gen_state, "finalizing")


@tagged("-at_install", "post_install")
class TestAZeroTokenCallIsNotPriced(TransactionCase):

    def test_a_veo_poll_costs_nothing_and_warns_nothing(self):
        with self.assertNoLogs("odoo.addons.assessments_be_v2.services"
                               ".model_catalog", level="WARNING"):
            cost = model_catalog.estimate_cost(
                "veo-3.1-generate-zz-%s" % uuid4().hex[:4], 0, 0, 0, 0)
        self.assertEqual(cost, 0.0)

    def test_a_real_call_on_an_unknown_model_still_warns(self):
        with self.assertLogs("odoo.addons.assessments_be_v2.services"
                             ".model_catalog", level="WARNING"):
            model_catalog.estimate_cost(
                "mystery-model-%s" % uuid4().hex[:6], 100, 10, 0, 0)
