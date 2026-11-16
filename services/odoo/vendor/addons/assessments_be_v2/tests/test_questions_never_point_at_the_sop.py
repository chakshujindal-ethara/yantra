"""A generated question never points the candidate at the SOP (owner, 2026-09-29).

Candidates do not have the SOP in the exam, yet 8 of 8 labelling questions in
one run said "according to the SOP" or "Refer to the SOP for the full element
list" - copied from High Res Dense's own golden.docx. Generation now rewrites
every such string in one small call before it becomes a draft; an option,
correct answer or key verdict is never touched, because the key matches them.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..services import vertex

CITING = ("Describe what each numbered box does, according to the SOP. "
          "Refer to the SOP for the full element list and examples.")
CLEAN = "Describe what each numbered box does."


def _item(prompt=CITING):
    return {
        "name": "Label the tool", "question_type": "image_label",
        "prompt": prompt,
        "options": ["Per the SOP, yes"],
        "correct_answer": ["Per the SOP, yes"],
        "image_specs": {
            "images": [{"slot": "single", "label": "Screenshot",
                        "prompt": "The labelling tool with two panels"}],
            "boxes": [{"number": n, "box_2d": [10, 10, 90, 90],
                       "element": "Panel %s" % n,
                       "functionality": "Does %s" % n} for n in (1, 2)],
            "answer_key": {
                "ideal_labels": {"1": "Does 1", "2": "Does 2"},
                "penalty_rules": ["Penalize anything the SOP section 6 forbids"],
            },
        },
        "_solution": {"answers": {"1": "Does 1"},
                      "rationale": "The SOP requires action-based wording."},
    }


def _rewrites(found_texts):
    """The model's reply: every text rewritten without the pointer."""
    return json.dumps([{"id": n, "text": "Rewritten %d." % n}
                       for n in range(len(found_texts))])


@tagged("-at_install", "post_install")
class TestSopPointersAreRewritten(TransactionCase):

    def test_every_candidate_and_grader_string_is_found_but_no_key(self):
        item = _item()
        # An image_ab plan's verdicts and options ARE its key.
        item["image_specs"]["flaw_plan"] = {
            "construction_keys": {"Q1": "Per the SOP, Yes"},
            "dimension_options": {"Q1": ["Per the SOP, Yes", "No"]}}

        paths = [path for _i, path, _t in vertex._source_citing_strings([item])]

        self.assertIn(("prompt",), paths)
        self.assertIn(("image_specs", "answer_key", "penalty_rules", 0), paths)
        self.assertIn(("_solution", "rationale"), paths)
        self.assertFalse([p for p in paths if set(p) & {
            "options", "correct_answer", "construction_keys",
            "dimension_options"}], "the key matches these exactly")

    def test_a_rewrite_is_applied_in_place(self):
        item = _item()
        texts = [t for _i, _p, t in vertex._source_citing_strings([item])]

        with patch.object(vertex, "_call_vertex",
                          return_value=_rewrites(texts)):
            fixed = vertex._rewrite_source_references(self.env, None, [item])

        self.assertEqual(fixed, len(texts))
        self.assertFalse(vertex._item_cites_source(dict(
            item, options=[], correct_answer=[])))
        self.assertEqual(item["options"], ["Per the SOP, yes"], "untouched")

    def test_a_rewrite_that_still_points_at_the_sop_is_not_kept(self):
        item = _item()
        with patch.object(vertex, "_call_vertex", return_value=json.dumps(
                [{"id": 0, "text": "Describe each box, as per the SOP."}])):
            vertex._rewrite_source_references(self.env, None, [item])

        self.assertEqual(item["prompt"], CITING)

    def test_a_failed_call_keeps_the_originals(self):
        item = _item()
        with patch.object(vertex, "_call_vertex",
                          side_effect=RuntimeError("503")):
            self.assertEqual(
                vertex._rewrite_source_references(self.env, None, [item]), 0)
        self.assertEqual(item["prompt"], CITING)

    def test_a_kill_still_stops_it(self):
        with patch.object(vertex, "_call_vertex",
                          side_effect=vertex.VertexCancelledError("killed")):
            with self.assertRaises(vertex.VertexCancelledError):
                vertex._rewrite_source_references(self.env, None, [_item()])

    def test_a_clean_batch_makes_no_call(self):
        with patch.object(vertex, "_call_vertex",
                          side_effect=AssertionError("no call")):
            self.assertEqual(vertex._rewrite_source_references(
                self.env, None, [_item(prompt=CLEAN) | {
                    "image_specs": {}, "_solution": {}}]), 0)


@tagged("-at_install", "post_install")
class TestAGeneratedDraftDoesNotPointAtTheSop(TransactionCase):
    """Through the real draft writer, with the model mocked."""

    def test_the_draft_reads_clean_and_carries_no_warning(self):
        gen = self.env["assessments.be.prompt"].create({
            "name": "No SOP pointers %s" % uuid4().hex[:6],
            "source_text": "Label the tool's panels."})
        item = _item()
        # A labelling item has no options; the one in `_item` is there to
        # prove options are never rewritten, and would keep the warning.
        for key in ("_solution", "options", "correct_answer"):
            item.pop(key)
        generation = json.dumps({"questions": [item], "solutions": [
            {"answers": {"1": "Does 1", "2": "Does 2"},
             "rationale": "The SOP requires action-based wording."}]})
        calls = []

        def model(env, system_prompt, *a, **k):
            text = json.dumps(k.get("user_parts") or [], default=str)
            calls.append(text)
            if "has NOT read the SOP" in text:
                sent = json.loads(text)[0]["text"].split("TEXTS:\n", 1)[1]
                return json.dumps([
                    {"id": e["id"], "text": CLEAN if "numbered box" in e["text"]
                     else "Rewritten."} for e in json.loads(sent)])
            return generation
        with patch.object(vertex, "_call_vertex", side_effect=model), \
                patch.object(vertex, "_selfheal_generation",
                             side_effect=lambda env, pr, items, *a, **k: items):
            ids = vertex.generate_questions_from_sop(self.env, gen, report={})

        draft = self.env["assessments.be.prompt.question"].browse(ids)
        self.assertEqual(len(draft), 1)
        self.assertEqual(draft.question_prompt, CLEAN)
        self.assertNotIn("quotes the SOP", draft.gen_warnings or "")
        self.assertNotIn("SOP", draft.rubric_json or "")
        self.assertNotIn("SOP", draft.solution_rationale or "")
        self.assertTrue(any("has NOT read the SOP" in c for c in calls))
