"""The task registry must reach the model, without changing single-task runs.

Two halves, and the second matters as much as the first:

  1. A multi-task SOP gets every task's OWN axes and OWN options into the
     generation directive, so a project this platform has never seen is
     reproduced rather than invented.
  2. A single-task SOP's directive is UNCHANGED. Generation is the most
     expensive path in the product; a registry that quietly rewrote every
     existing project's prompt would be a regression discovered by a paid run.
"""
import json

from odoo.tests.common import TransactionCase

from ..services.vertex import _task_registry_note


class _FakePrompt:
    """Only what `_task_registry_note` reads."""

    def __init__(self, tasks_json=""):
        self.tasks_json = tasks_json


def _task(key, display, response, dims, **kw):
    return {
        "key": key,
        "display": display,
        "subject_inputs": kw.get("inputs", "one frame"),
        "worker_output": kw.get("output", "a verdict"),
        "answer_contract": {
            "response": response,
            "dimensions": dims,
            "assets_per_question": kw.get("assets", 1),
            "justification": kw.get("justification", "none"),
            "solution_shape": kw.get("shape", ""),
        },
    }


TWO_TASKS = json.dumps([
    _task("task:compare-ai-images", "Compare Two AI Images (A/B)",
          "compare_two",
          [{"label": "Instruction Following",
            "options": ["Image A", "Image B", "Both Good", "Both Bad"]},
           {"label": "Less AI-Generated",
            "options": ["Image A", "Image B", "Tie"]}],
          inputs="a prompt and two images", output="a side per axis",
          assets=2, justification="required",
          shape="a side per axis plus one reason"),
    _task("task:mark-defects", "Mark Defects On A Frame", "annotate_image", [],
          inputs="one rendered frame", output="dots on defects"),
])


class TestTaskRegistryNote(TransactionCase):

    # ------------------------------------------------- the no-regression half

    def test_a_single_task_sop_adds_nothing_to_the_directive(self):
        """The rating scheme already says it; repeating costs tokens every run."""
        one = json.dumps([json.loads(TWO_TASKS)[0]])

        self.assertEqual(_task_registry_note(_FakePrompt(one)), "")

    def test_a_sop_with_no_registry_adds_nothing(self):
        """Every generator that existed before this feature."""
        self.assertEqual(_task_registry_note(_FakePrompt("")), "")
        self.assertEqual(_task_registry_note(_FakePrompt(None)), "")

    def test_malformed_registry_adds_nothing_rather_than_raising(self):
        """A bad registry must not lose a run that already cost money."""
        self.assertEqual(_task_registry_note(_FakePrompt("{not json")), "")
        self.assertEqual(_task_registry_note(_FakePrompt('{"a":1}')), "")

    def test_a_record_without_the_field_is_tolerated(self):
        """Belt and braces: the note is called on every generation."""
        class Bare:
            pass

        self.assertEqual(_task_registry_note(Bare()), "")

    # ----------------------------------------------------- the multi-task half

    def test_every_task_reaches_the_model(self):
        note = _task_registry_note(_FakePrompt(TWO_TASKS))

        self.assertIn("2 DISTINCT TASKS", note)
        self.assertIn("Compare Two AI Images (A/B)", note)
        self.assertIn("Mark Defects On A Frame", note)

    def test_each_task_carries_its_own_axes_and_options(self):
        """THE POINT. Two axes, two DIFFERENT option sets, both verbatim."""
        note = _task_registry_note(_FakePrompt(TWO_TASKS))

        self.assertIn(
            "axis: Instruction Following | options: Image A, Image B, "
            "Both Good, Both Bad", note)
        self.assertIn(
            "axis: Less AI-Generated | options: Image A, Image B, Tie", note)

    def test_the_directive_forbids_carrying_axes_across_tasks(self):
        """The failure mode this exists to prevent, stated to the model."""
        note = _task_registry_note(_FakePrompt(TWO_TASKS))

        self.assertIn("never carry one task's axes onto another", note)
        self.assertIn("must not be given four", note)

    def test_the_primitive_becomes_a_question_type_instruction(self):
        note = _task_registry_note(_FakePrompt(TWO_TASKS))

        self.assertIn("author these as question_type: image_ab", note)
        self.assertIn("author these as question_type: image_label", note)

    def test_a_required_justification_is_stated(self):
        note = _task_registry_note(_FakePrompt(TWO_TASKS))

        self.assertIn("justification is REQUIRED", note)

    def test_a_task_with_no_axes_still_appears(self):
        """An annotation task has no per-axis judgment but is still a task.

        Dropping it would spend every item on the comparison task - the exact
        flattening the registry exists to stop.
        """
        note = _task_registry_note(_FakePrompt(TWO_TASKS))
        marker = "TASK 2 - Mark Defects On A Frame"

        self.assertIn(marker, note)
        self.assertIn("dots on defects", note)

    def test_no_generic_response_scale_is_introduced(self):
        """The SOP said Image A / Image B; the note must not say Response A."""
        note = _task_registry_note(_FakePrompt(TWO_TASKS))

        self.assertNotIn("Response A", note)
        self.assertIn("Image A", note)
