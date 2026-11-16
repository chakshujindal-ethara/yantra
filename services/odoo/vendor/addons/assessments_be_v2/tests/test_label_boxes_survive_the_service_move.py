# -*- coding: utf-8 -*-
"""A labelling question must still offer its per-box inputs.

THE FAILURE MODE THIS GUARDS, which is why it is its own file. The JSON API's
`_label_boxes` used to reach `_ideal_labels_count` by importing it out of
`controllers/portal.py` - the QWeb runner's module - where it was only ever a
re-export of `services.labelling.ideal_labels_count`. That import sits inside a
deliberately broad `except Exception: return []`, whose job is to never fail a
question render.

So the dependency could not announce itself. Remove or rename that module and the
import raises, the `except` swallows it, `_label_boxes` returns `[]`, and every
labelling question renders with ZERO text inputs - over an image that still has
its numbered boxes baked into the bitmap. The candidate sees boxes 1..N drawn on
the picture and nothing to type into. Nothing in the response says so; the only
trace is one `_logger.exception` line.

Nothing else pinned it. `test_image_label_cap` covers the service function
directly, and `test_image_label_per_box` covers the marks. Both pass with
`_label_boxes` returning `[]`, because neither goes through it.

Asserted as a POSITIVE: the boxes are there. A test that only checked the count
would also pass on an empty list if the fixture happened to imply zero.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..constants import DEFAULT_IMAGE_LABEL_COUNT
from ..controllers.api import candidate as candidate_api


@tagged("-at_install", "post_install")
class TestLabelBoxesSurviveTheServiceMove(TransactionCase):

    def setUp(self):
        super().setUp()
        self.controller = candidate_api.EtpAssessmentApiCandidate()
        self.Question = self.env["assessments.be.question"]

    def _labelling_question(self, ideal_labels, detections=None):
        """An image_label question with an answer key and a single image.

        The image is what makes the fallback path reachable: `_label_boxes`
        consults `detections_json` first and only derives from the key when
        detection has not run, which is the branch the moved import lives on.

        The key goes in `subjective_rubric_json`, which is where
        `scoring._answer_key_dict` reads it from - NOT `solution_json`, which
        holds the objective key. Writing the wrong column here yields an empty
        key and `[]` boxes, i.e. it would look exactly like the bug.
        """
        question = self.Question.create({
            "name": "Label the parts %s" % uuid4().hex[:6],
            "question_type": "image_label",
            "prompt": "Name each numbered region.",
            "subjective_rubric_json": json.dumps(
                {"ideal_labels": ideal_labels}),
        })
        self.env["assessments.be.question.image"].create({
            "question_id": question.id,
            "slot": "single",
            "label": "Diagram",
            "detections_json": json.dumps(detections) if detections else False,
        })
        question.invalidate_recordset()
        return question

    def test_a_key_with_three_entries_yields_three_input_boxes(self):
        question = self._labelling_question(["Rotor", "Stator", "Housing"])

        boxes = self.controller._label_boxes(question)

        self.assertEqual(
            boxes, [1, 2, 3],
            "a three-entry answer key must offer three per-box inputs. An empty "
            "list here is the silent failure this file exists for: the numbered "
            "boxes are baked into the candidate's image, so they would see 1-3 "
            "drawn with nothing to type into.")

    def test_the_derivation_is_not_capped_by_the_generator(self):
        """No cap is passed on the candidate side, on purpose.

        The boxes are already baked into the image being shown. Lowering a
        generator's `image_label_count` after the fact must not hide the input
        for a box still drawn on screen, so this path resolves to the default
        rather than to whatever the generator now says.
        """
        over = ["Part %d" % n for n in range(1, DEFAULT_IMAGE_LABEL_COUNT + 11)]
        question = self._labelling_question(over)

        boxes = self.controller._label_boxes(question)

        self.assertEqual(len(boxes), DEFAULT_IMAGE_LABEL_COUNT)
        self.assertTrue(boxes, "the fallback must never render zero inputs")

    def test_detections_still_win_over_the_key(self):
        """Guard the guard: if this branch were broken the tests above would be
        proving the wrong path."""
        question = self._labelling_question(
            ["Rotor", "Stator"],
            detections=[{"number": 1, "box_2d": [0, 0, 10, 10]},
                        {"number": 2, "box_2d": [10, 10, 20, 20]}])

        boxes = self.controller._label_boxes(question)

        self.assertEqual(
            boxes,
            [{"number": 1, "box_2d": [0, 0, 10, 10]},
             {"number": 2, "box_2d": [10, 10, 20, 20]}],
            "a fully-geometried marker set must come back as interactive "
            "overlay pairs, not as bare numbers")

    def test_a_non_labelling_question_offers_no_boxes(self):
        mcq = self.Question.create({
            "name": "Pick one %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "Choose.",
        })
        self.assertEqual(self.controller._label_boxes(mcq), [])
