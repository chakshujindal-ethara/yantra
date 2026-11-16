# -*- coding: utf-8 -*-
"""A labelling question with nothing to label must not be servable.

THE DEFECT THIS LOCKS DOWN. `_compute_has_valid_key` declared every non-MCQ
type valid unconditionally, so an `image_label` question could reach the bank
with neither numbered boxes nor an ideal-label key and still pass the servable
guard (`servable = active AND has_valid_key AND NOT missing_media_warning`). A
candidate would be shown a bare picture with nothing marked on it, and the
grader would have nothing to mark against. Two such questions were sitting in
the live bank - q290 and q295 - both reporting has_valid_key=True.

BOTH are required in the BANK, and that is a tightening of what this file first
pinned. It originally accepted "boxes OR a key", on the reasoning that the defect
lane stamps markers at render time so the key can arrive first. That is true of a
DRAFT and false of the bank, where a row is approved and one attach away from a
candidate. The key-without-boxes half was live: images 290, 295 and 306 carried
keys naming 1, 3 and 2 boxes with nothing drawn at all, and this file's own
`test_a_key_alone_is_enough` asserted that was fine. A candidate would be shown a
picture with no numbers on it and asked to describe boxes 1..N - every one of
those marks unearnable.

The draft mirror (`serializers.draft_key_valid`) stays loose on purpose; see its
docstring. Quarantine here only clears `servable`, so nothing is deleted and the
detect cron can still flip the flag back by filling `detections_json`.

WHAT COUNTS AS A BOX is the count the CANDIDATE ROUTE arrives at:
`serializers._label_boxes` prefers `label_boxes_json` and falls back to
`detections_json`, so reading only the first field quarantined every
detect-after-render question, and taking the larger of the two let image 305
(6 boxes, 1 detection) claim six markers the candidate never saw.
"""
import json

from odoo.tests.common import TransactionCase


class TestLabellingQuestionNeedsAKey(TransactionCase):

    def _question(self, boxes=None, rubric=None, solution=None,
                  qtype="image_label"):
        q = self.env["assessments.be.question"].create({
            "name": "Categorise the boxed entities",
            "prompt": "Categorise each numbered box.",
            "question_type": qtype,
        })
        if rubric is not None:
            q.subjective_rubric_json = json.dumps(rubric)
        if solution is not None:
            q.solution_json = json.dumps(solution)
        if boxes is not None:
            self.env["assessments.be.question.image"].create({
                "question_id": q.id,
                "slot": "single",
                "label": "Image",
                "label_boxes_json": json.dumps(boxes),
            })
        q.invalidate_recordset()
        return q

    def test_no_boxes_and_no_key_is_not_valid(self):
        q = self._question()
        self.assertFalse(
            q.has_valid_key,
            "a labelling question with nothing to label passed the guard")

    def test_boxes_with_no_key_are_NOT_servable(self):
        """Boxes the grader has nothing to mark against."""
        q = self._question(boxes=[{"number": 1, "box_2d": [1, 2, 3, 4]},
                                  {"number": 2, "box_2d": [5, 6, 7, 8]}])
        self.assertFalse(
            q.has_valid_key,
            "drawn boxes with no ideal labels give the grader no key")

    def test_a_key_with_no_drawn_boxes_is_NOT_servable(self):
        """The live 290/295/306 shape: a key naming boxes nobody drew.

        Fails if the rule goes back to `boxes OR key` - which is what this file
        used to assert was correct.
        """
        q = self._question(rubric={"ideal_labels": {"1": "People",
                                                    "2": "Clothing"}})
        self.assertFalse(
            q.has_valid_key,
            "a key naming 2 boxes with nothing drawn was servable: the "
            "candidate sees no numbers and cannot earn either mark")

    def test_the_judges_golden_answer_also_needs_boxes(self):
        q = self._question(solution={"ideal_labels": {"1": "People"}})
        self.assertFalse(q.has_valid_key)

    def test_boxes_AND_a_key_together_are_servable(self):
        """The healthy shape, and the guard must not over-reach onto it."""
        q = self._question(
            boxes=[{"number": 1, "box_2d": [1, 2, 3, 4]},
                   {"number": 2, "box_2d": [5, 6, 7, 8]}],
            rubric={"ideal_labels": {"1": "People", "2": "Clothing"}})
        self.assertTrue(q.has_valid_key)

    def test_detections_alone_count_as_drawn_boxes(self):
        """The detect-after-render lane writes `detections_json`, not
        `label_boxes_json`.

        Reading only `label_boxes_json` quarantined every question whose markers
        are baked into the picture - the exact lane `_detect_label_on_render`
        produces - even though `serializers._label_boxes` serves them happily.
        """
        q = self._question(rubric={"ideal_labels": {"1": "People"}})
        self.env["assessments.be.question.image"].create({
            "question_id": q.id,
            "slot": "single",
            "label": "Rendered",
            "detections_json": json.dumps([{"number": 1, "label": "People"}]),
        })
        q.invalidate_recordset()
        self.assertTrue(
            q.has_valid_key,
            "a detected box is a real box - serving reads detections_json")

    def test_a_drawable_overlay_WINS_over_a_shorter_detection_list(self):
        """Live image 29 (question 305): 6 drawable boxes beside 1 detection.

        MIRRORS `serializers._label_boxes`, which PREFERS `label_boxes_json` when
        its entries are drawable and only falls back to `detections_json`
        otherwise. So the candidate is shown the six overlay boxes and six is the
        honest count.

        An earlier version of this guard took the SMALLER of the two carriers,
        reasoning that a disagreement means the lower number is what is really on
        screen. That was wrong in this direction - it measured a different
        picture from the one being served - and it would have quarantined a sound
        question. Checked against the live rows: images 25/26/30/34 carry an
        EMPTY `label_boxes_json` beside 20/20/20/3 detections, which is the
        detect-after-render lane's ordinary output.
        """
        q = self._question(
            boxes=[{"number": n, "box_2d": [n, n, n + 1, n + 1]}
                   for n in range(1, 7)],
            rubric={"ideal_labels": {str(n): "thing" for n in range(1, 7)}})
        img = q.image_ids[:1]
        img.detections_json = json.dumps([{"number": 1, "label": "thing"}])
        q.invalidate_recordset()
        self.assertEqual(
            q._label_box_count(), 6,
            "the drawable overlay is what the candidate sees, so it decides")

    def test_an_empty_key_map_is_not_a_key(self):
        q = self._question(rubric={"ideal_labels": {}})
        self.assertFalse(q.has_valid_key)

    def test_a_prose_key_counts_its_lines(self):
        """`_label_key_count` is asserted DIRECTLY, not through has_valid_key.

        The counter is what the rule is built on, so it is pinned on its own -
        going through the flag would only re-test the boxes half.
        """
        q = self._question(rubric={"ideal_labels": "1. People\n2. Clothing"})
        self.assertEqual(q._label_key_count(), 2)

    def test_unparseable_json_is_not_a_key(self):
        q = self._question()
        q.subjective_rubric_json = "{not json"
        q.invalidate_recordset()
        self.assertFalse(q.has_valid_key)

    def test_an_mcq_still_needs_a_marked_option(self):
        """The existing rule must not regress."""
        q = self._question(qtype="mcq")
        self.assertFalse(q.has_valid_key)

    def test_a_rubric_question_stays_valid(self):
        """Subjective types are LLM-graded and carry no per-option key."""
        q = self._question(qtype="subjective_rubric")
        self.assertTrue(q.has_valid_key)

    def test_box_count_reads_every_image(self):
        """Boxes on a second image count too - a question can carry several."""
        q = self._question(boxes=[{"number": 1}])
        self.env["assessments.be.question.image"].create({
            "question_id": q.id,
            "slot": "b",
            "label": "Second image",
            "label_boxes_json": json.dumps([{"number": 2}, {"number": 3}]),
        })
        q.invalidate_recordset()
        self.assertEqual(q._label_box_count(), 3)
