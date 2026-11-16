"""Rows generated before the fix are repaired on `-u`, and only when it is safe.

The generator now writes a rationale, an official reasoning and axis labels
that agree with the key (test_generated_text_agrees_with_its_key). Rows already
in the bank were written before that, so `question.init` queues
`vertex.repair_generated_question_text`. These fixtures are shaped exactly like
production questions 1165, 1167 and 1178. The repair must fix what it can
decide mechanically, list what it cannot, leave everything else alone, and
change nothing on a second run.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.constants import (
    ab_construction_keys, ab_key_drift, ab_materialized_keys, parse_flaw_plan,
)
from odoo.addons.assessments_be_v2.services import vertex

AB = ["Response A", "Response B", "Both Good", "Both Bad"]
FLAW_1165 = ("The reference image shows multiple different items on a rack, "
             "meaning the target entity is not single and isolated.")


def _official(winner, flaw):
    loser = "A" if winner == "B" else "B"
    return ("Response %s is correct by construction: it renders the brief "
            "cleanly, while Response %s carries deliberately injected flaws "
            "(%s). Response %s therefore wins Overall Choice."
            % (winner, loser, flaw, winner))


@tagged("-at_install", "post_install")
class TestExistingRowsAreRepairedToAgreeWithTheirKey(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Video Caption Labeling %s" % uuid4().hex[:6]})

    def _question(self, dims, **vals):
        question = self.Question.create(dict({
            "name": "Q %s" % uuid4().hex[:6], "question_type": "image_ab",
            "prompt": "Compare the two.", "generator_id": self.generator.id,
        }, **vals))
        for label, options, correct in dims:
            self.env["assessments.be.question.dimension"].create({
                "question_id": question.id, "name": label,
                "option_line_ids": [
                    (0, 0, {"name": o, "sequence": (i + 1) * 10,
                            "is_correct": o == correct})
                    for i, o in enumerate(options)],
            })
        return question

    def _ab(self, rationale, winner="B", flaw="the wrong hand is used"):
        side = "Response %s" % winner
        return self._question(
            [("Instruction Following", AB, side),
             ("Visual Quality", AB, "Both Good"),
             ("Less AI-Generated", AB, "Both Good"),
             ("Overall Choice", ["Response A", "Response B"], side)],
            official_reasoning=_official(winner, flaw),
            solution_rationale=rationale)

    def _repair(self):
        return vertex.repair_generated_question_text(self.env)

    # -- B ---------------------------------------------------------------

    def test_1167_the_inverted_rationale_is_flipped(self):
        question = self._ab(
            "Response A correctly follows the instruction to use the right "
            "hand. Response B is flawed because it depicts the left hand "
            "performing the action, violating the explicit hand phrasing in "
            "the prompt.")

        report = self._repair()

        self.assertIn("question:%d" % question.id, report["rationale"])
        self.assertEqual(
            question.solution_rationale,
            "Response B correctly follows the instruction to use the right "
            "hand. Response A is flawed because it depicts the left hand "
            "performing the action, violating the explicit hand phrasing in "
            "the prompt.")

    def test_1178_the_inverted_rationale_is_flipped(self):
        question = self._ab(
            "The instruction requires the bottle to be in the 'middle slot in "
            "the bottom row'. Response B plants a deliberate flaw by placing "
            "the bottle in the bottom right slot, violating the precise target "
            "location. Response A follows all instructions correctly.")

        self._repair()

        self.assertEqual(
            question.solution_rationale,
            "The instruction requires the bottle to be in the 'middle slot in "
            "the bottom row'. Response A plants a deliberate flaw by placing "
            "the bottle in the bottom right slot, violating the precise target "
            "location. Response B follows all instructions correctly.")

    def test_a_rationale_that_already_agrees_is_left_alone(self):
        text = ("Response B follows the brief. Response A is flawed: the "
                "left hand acts.")
        question = self._ab(text)

        report = self._repair()

        self.assertEqual(question.solution_rationale, text)
        tag = "question:%d" % question.id
        self.assertNotIn(tag, report["rationale"] + report["ambiguous"])

    def test_an_ambiguous_rationale_is_listed_and_untouched(self):
        # One sentence praises the loser, the next the winner.
        text = "Response A follows the prompt. Response B also follows it."
        question = self._ab(text)

        report = self._repair()

        self.assertEqual(question.solution_rationale, text)
        self.assertIn("question:%d" % question.id, report["ambiguous"])

    def test_a_negated_sentence_is_not_read_as_a_fault(self):
        text = "Response B is not flawed. Response A does not follow the brief."
        question = self._ab(text)

        report = self._repair()

        self.assertEqual(question.solution_rationale, text)
        self.assertIn("question:%d" % question.id, report["ambiguous"])

    def test_a_key_that_disagrees_with_the_reasoning_is_not_guessed_at(self):
        question = self._ab("Response A correctly follows the brief.")
        question.official_reasoning = _official("A", "the wrong hand")

        report = self._repair()

        self.assertEqual(question.solution_rationale,
                         "Response A correctly follows the brief.")
        self.assertIn("question:%d" % question.id, report["ambiguous"])

    # -- C and D: 1165 ---------------------------------------------------

    def _question_1165(self):
        labels = ["1. Is this reference a {type}?",
                  "2. Same exact {type} as tagged?",
                  "3. Different source than the video?",
                  "4. Single, isolated {type} on its own?"]
        options = [["Yes", "No", "Nothing meaningful shown"],
                   ["Yes", "No"], ["Yes", "No"], ["Yes", "No"]]
        key = ["Yes", "Yes", "Yes", "No"]
        template = self.env["assessments.be.task.template"].create({
            "name": "Verify Video Entities %s" % uuid4().hex[:6],
            "response": "compare_two", "question_type": "image_ab",
            "structure_json": [{"id": "s", "title": "Checks", "items": [
                {"id": "i%d" % n, "kind": "multipleChoice", "title": label,
                 "options": [{"id": "o%d%d" % (n, m), "label": o}
                             for m, o in enumerate(opts)]}
                for n, (label, opts) in enumerate(zip(labels, options))]}],
        })
        codes = [label.upper() for label in labels]
        plan = {
            "faithful_side": "a", "flawed_side": "b",
            "planted": {"a": [], "b": [FLAW_1165]},
            "construction_keys": dict(zip(codes, key)),
            "dimension_options": dict(zip(codes, options)),
            "dimension_labels": dict(zip(codes, labels)),
        }
        question = self._question(
            list(zip(labels, options, key)),
            source_template_id=template.id,
            flaw_plan_json=json.dumps(plan),
            official_reasoning=_official("A", FLAW_1165),
            solution_json=json.dumps("\n".join(
                "%s: %s" % pair for pair in zip(labels, key))),
            solution_rationale="The reference image shows the correct entity "
                               "(red floral dress) on a rack.")
        return question

    def _drift(self, question):
        keys = ab_construction_keys(question.flaw_plan_json)
        return ab_key_drift(ab_materialized_keys(
            question.question_dimension_ids, keys,
            parse_flaw_plan(question.flaw_plan_json).get("dimension_labels")),
            keys)

    def test_1165_the_template_slot_is_filled_in_every_copy(self):
        question = self._question_1165()
        self.assertEqual(self._drift(question), [], "sound before the repair")

        report = self._repair()

        self.assertIn("question:%d" % question.id, report["slots"])
        self.assertEqual(question.question_dimension_ids.mapped("name"), [
            "1. Is this reference an item?", "2. Same exact item as tagged?",
            "3. Different source than the video?",
            "4. Single, isolated item on its own?"])
        for field in ("solution_json", "flaw_plan_json", "official_reasoning"):
            self.assertNotIn("{type}", question[field].lower(), field)
        self.assertEqual(self._drift(question), [],
                         "every copy was filled alike, so no key drift")

    def test_1165_yes_no_checks_get_their_own_reasoning(self):
        question = self._question_1165()

        report = self._repair()

        self.assertIn("question:%d" % question.id, report["reasoning"])
        self.assertEqual(
            question.official_reasoning,
            "The correct ratings are: 1. Is this reference an item?: Yes; "
            "2. Same exact item as tagged?: Yes; 3. Different source than the "
            "video?: Yes; 4. Single, isolated item on its own?: No. "
            + FLAW_1165)

    def test_a_second_run_changes_nothing(self):
        rows = [self._question_1165(),
                self._ab("Response A correctly follows the brief. Response B "
                         "is flawed.")]
        self._repair()
        before = [(q.official_reasoning, q.solution_rationale,
                   q.flaw_plan_json, q.question_dimension_ids.mapped("name"))
                  for q in rows]

        report = self._repair()

        self.assertEqual(before, [
            (q.official_reasoning, q.solution_rationale, q.flaw_plan_json,
             q.question_dimension_ids.mapped("name")) for q in rows])
        tags = {"question:%d" % q.id for q in rows}
        self.assertFalse(tags & set(sum(report.values(), [])), report)
