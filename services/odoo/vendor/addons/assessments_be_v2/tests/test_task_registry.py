"""The SOP's task registry: many tasks per SOP, each with its own answer shape.

WHY THIS EXISTS. The platform could only assess a task shape someone had already
written Python for. Extraction captured exactly ONE `canonical_task` per SOP
("one task, never a list"), `question_spec_json` was NULL on every recent
generator, and the eight question types were a closed list with 122 literal
mentions across five files. A new project therefore meant a code change, and
every A/B item on every project got the same four options - "Response A /
Response B / Both Good / Both Bad" - because the options lived in the harness
instead of in the SOP that names them.

THE FIX IS DATA, NOT CODE. The eight types stay a closed set of RESPONSE
PRIMITIVES (ways a human can answer). What an item ASKS - its axis names, its
per-axis options, whether a justification is required - is read from the SOP at
extraction time and stored per task. A new project brings new dimensions and
options; it never needs a new primitive.

`canonical_task` remains the primary entry and still drives ranking and the
single task tag, so a single-task SOP behaves exactly as it did.
"""
import json

from odoo.tests.common import TransactionCase

from ..constants import (
    TASK_PRIMITIVE_TO_QUESTION_TYPE,
    TASK_RESPONSE_PRIMITIVES,
    parse_task_registry,
    task_answer_contract,
    task_question_type,
)
from ..services.vertex import _capture_knowledge_profile


class TestTaskRegistry(TransactionCase):

    # A two-task SOP: judge a pair, and separately annotate a single frame.
    # The second axis offers only two options where the first offers four -
    # the exact asymmetry that produced an unmarked dimension in production.
    TWO_TASK_PROFILE = {
        "knowledge_profile": {
            "summary": "Workers judge AI images and mark defects.",
            "canonical_task": {
                "key": "task:compare-ai-images",
                "display": "Compare Two AI Images (A/B)",
                "one_sentence": "Pick the better of two generated images.",
            },
            "subject_inputs": "two AI images + the prompt",
            "worker_output": "an A/B verdict",
            "tasks": [
                {
                    "key": "task:compare-ai-images",
                    "display": "Compare Two AI Images (A/B)",
                    "one_sentence": "Pick the better of two generated images.",
                    "subject_inputs": "two AI images + the prompt",
                    "worker_output": "an A/B verdict + justification",
                    "answer_contract": {
                        "response": "compare_two",
                        "dimensions": [
                            {"label": "Which image better follows the prompt?",
                             "options": ["Response A", "Response B",
                                         "Both Good", "Both Bad"],
                             "evidence": "A. Instruction Following"},
                            {"label": "Which looks less AI-generated?",
                             "options": ["Response A", "Response B"],
                             "evidence": "C. Less AI-Generated"},
                        ],
                        "assets_per_question": 2,
                        "justification": "required",
                        "solution_shape": "a side per axis plus one reason",
                    },
                    "evidence": "Compare the two images side by side.",
                },
                {
                    "key": "task:mark-defects",
                    "display": "Mark Defects On A Frame",
                    "one_sentence": "Place a dot on each visible defect.",
                    "subject_inputs": "one rendered frame",
                    "worker_output": "dots on defects",
                    "answer_contract": {
                        "response": "annotate_image",
                        "dimensions": [],
                        "assets_per_question": 1,
                        "justification": "none",
                        "solution_shape": "one dot per defect",
                    },
                    "evidence": "Place a dot on every artifact you find.",
                },
            ],
        }
    }

    # ---------------------------------------------------------------- parsing

    def test_a_multi_task_sop_keeps_every_task(self):
        """The headline behaviour change: three jobs stay three jobs."""
        vals = _capture_knowledge_profile(self.env, None, self.TWO_TASK_PROFILE)
        tasks = parse_task_registry(vals["tasks_json"])

        self.assertEqual(len(tasks), 2,
                         "a two-task SOP must not collapse onto its primary")
        self.assertEqual([t["key"] for t in tasks],
                         ["task:compare-ai-images", "task:mark-defects"],
                         "primary first - order is read downstream")

    def test_the_primary_task_still_names_the_sop(self):
        """canonical_task keeps driving ranking and the title, unchanged."""
        vals = _capture_knowledge_profile(self.env, None, self.TWO_TASK_PROFILE)

        self.assertEqual(vals["sop_title"], "Compare Two AI Images (A/B)")

    def test_a_registry_missing_its_primary_is_repaired_not_dropped(self):
        """Losing the secondary tasks over a missing echo would be worse.

        canonical_task is already trusted enough to name the generator, so it is
        a valid first entry.
        """
        obj = json.loads(json.dumps(self.TWO_TASK_PROFILE))
        obj["knowledge_profile"]["tasks"] = [
            obj["knowledge_profile"]["tasks"][1]]  # secondary only

        vals = _capture_knowledge_profile(self.env, None, obj)
        tasks = parse_task_registry(vals["tasks_json"])

        self.assertEqual([t["key"] for t in tasks],
                         ["task:compare-ai-images", "task:mark-defects"],
                         "the primary is reinserted at the front")

    def test_a_primary_returned_out_of_order_is_hoisted(self):
        obj = json.loads(json.dumps(self.TWO_TASK_PROFILE))
        obj["knowledge_profile"]["tasks"].reverse()

        vals = _capture_knowledge_profile(self.env, None, obj)
        tasks = parse_task_registry(vals["tasks_json"])

        self.assertEqual(tasks[0]["key"], "task:compare-ai-images")
        self.assertEqual(len(tasks), 2, "hoisting must not drop the other task")

    def test_a_single_task_sop_is_unchanged(self):
        """The no-regression case: one task in, one task out, primary intact."""
        obj = json.loads(json.dumps(self.TWO_TASK_PROFILE))
        obj["knowledge_profile"]["tasks"] = [
            obj["knowledge_profile"]["tasks"][0]]

        vals = _capture_knowledge_profile(self.env, None, obj)

        self.assertEqual(len(parse_task_registry(vals["tasks_json"])), 1)

    def test_a_sop_with_no_registry_stores_nothing(self):
        """Older SOPs and older prompts must not gain an empty field."""
        obj = json.loads(json.dumps(self.TWO_TASK_PROFILE))
        del obj["knowledge_profile"]["tasks"]

        vals = _capture_knowledge_profile(self.env, None, obj)

        self.assertNotIn("tasks_json", vals)

    def test_malformed_json_degrades_to_empty_rather_than_raising(self):
        """A bad registry must not lose a generation run that cost money."""
        self.assertEqual(parse_task_registry("{not json"), [])
        self.assertEqual(parse_task_registry(""), [])
        self.assertEqual(parse_task_registry(None), [])
        self.assertEqual(parse_task_registry('{"a": 1}'), [],
                         "an object is not a task list")
        self.assertEqual(parse_task_registry('[{"display": "no key"}]'), [],
                         "a task without a key cannot be addressed")

    # -------------------------------------------------------------- contracts

    def test_each_task_keeps_its_own_per_axis_options(self):
        """THE BUG THIS FIXES. Axis two offers two options, not four.

        Copying one axis's options onto another is what made every A/B question
        on every project look identical, and what left a narrowed axis unmarked
        when the model answered with a verdict that axis never offered.
        """
        tasks = parse_task_registry(
            _capture_knowledge_profile(
                self.env, None, self.TWO_TASK_PROFILE)["tasks_json"])
        contract = task_answer_contract(tasks[0])

        self.assertEqual(len(contract["dimensions"]), 2)
        self.assertEqual(len(contract["dimensions"][0]["options"]), 4)
        self.assertEqual(contract["dimensions"][1]["options"],
                         ["Response A", "Response B"],
                         "the SOP narrowed this axis; the contract must too")

    def test_the_sops_own_wording_survives(self):
        tasks = parse_task_registry(
            _capture_knowledge_profile(
                self.env, None, self.TWO_TASK_PROFILE)["tasks_json"])
        labels = [d["label"]
                  for d in task_answer_contract(tasks[0])["dimensions"]]

        self.assertEqual(labels, ["Which image better follows the prompt?",
                                  "Which looks less AI-generated?"],
                         "verbatim SOP wording, not a generic scale")

    def test_an_unanswerable_axis_is_dropped(self):
        """A label with no options cannot be answered; one option is not a choice."""
        task = {"key": "task:x", "answer_contract": {
            "response": "single_choice",
            "dimensions": [
                {"label": "Real axis", "options": ["Yes", "No"]},
                {"label": "No options at all", "options": []},
                {"label": "Only one option", "options": ["Yes"]},
                {"label": "", "options": ["Yes", "No"]},
            ]}}

        dims = task_answer_contract(task)["dimensions"]

        self.assertEqual([d["label"] for d in dims], ["Real axis"])

    def test_an_unknown_primitive_is_refused(self):
        """The primitive set is closed on purpose; a typo must not become a type."""
        task = {"key": "task:x",
                "answer_contract": {"response": "interpretive_dance"}}

        self.assertNotIn("response", task_answer_contract(task))
        self.assertIsNone(task_question_type(task))

    def test_every_primitive_maps_to_a_question_type(self):
        """A primitive with no mapping would author items nothing can serve."""
        for primitive in TASK_RESPONSE_PRIMITIVES:
            self.assertIn(primitive, TASK_PRIMITIVE_TO_QUESTION_TYPE,
                          "primitive %r has no question type" % primitive)

    def test_a_task_with_no_contract_falls_back_rather_than_failing(self):
        """No contract means "use what you would have used", not "no dimensions"."""
        task = {"key": "task:bare", "display": "Bare"}

        self.assertEqual(task_answer_contract(task), {})
        self.assertEqual(task_question_type(task, fallback="mcq"), "mcq")

    def test_the_primitive_picks_the_question_type(self):
        tasks = parse_task_registry(
            _capture_knowledge_profile(
                self.env, None, self.TWO_TASK_PROFILE)["tasks_json"])

        self.assertEqual(task_question_type(tasks[0]), "image_ab",
                         "compare_two is served by the A/B type")
        self.assertEqual(task_question_type(tasks[1]), "image_label",
                         "annotate_image is served by the labelling type")
