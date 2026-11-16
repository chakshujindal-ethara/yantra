# -*- coding: utf-8 -*-
"""The grader's `markers_hidden` agrees with what the candidate was shown (M2).

Regions with `box_2d` reach the candidate for the client to draw, so their box
numbers are the key's. Regions without geometry are never shown on an object
photo, so the grader matches labels by meaning.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers import media_stream
from ..controllers.api import candidate as candidate_api
from ..services import scoring as scoring_svc


@tagged("-at_install", "post_install")
class TestTheGraderKnowsWhichMarkersTheCandidateSaw(TransactionCase):

    def _question(self, detections):
        question = self.env["assessments.be.question"].create({
            "name": "Label %s" % uuid4().hex[:6],
            "question_type": "image_label",
            "prompt": "Label each numbered point.",
        })
        self.env["assessments.be.question.image"].create({
            "question_id": question.id, "slot": "single", "label": "Photo",
            "detections_json": json.dumps(detections)})
        question.invalidate_recordset()
        return question

    def _shown_and_told(self, question):
        shown = candidate_api.EtpAssessmentApiCandidate()._label_boxes(question)
        told = scoring_svc._question_material(question)
        return shown, told.get("markers_hidden", False)

    def test_object_regions_with_geometry_are_drawn_and_graded_by_number(self):
        question = self._question([
            {"number": 1, "label": "Weld crack", "box_2d": [0, 0, 10, 10]},
            {"number": 2, "label": "Paint run", "box_2d": [10, 10, 20, 20]}])
        self.assertEqual(question.detection_mode, "object")

        shown, hidden = self._shown_and_told(question)

        self.assertEqual(shown, [{"number": 1, "box_2d": [0, 0, 10, 10]},
                                 {"number": 2, "box_2d": [10, 10, 20, 20]}])
        self.assertFalse(hidden)

    def test_regions_without_geometry_are_hidden_and_graded_by_meaning(self):
        question = self._question([
            {"number": 1, "label": "Weld crack", "box_px": [0, 0, 10, 10]},
            {"number": 2, "label": "Paint run", "box_px": [10, 10, 20, 20]}])

        shown, hidden = self._shown_and_told(question)

        self.assertEqual(shown, [1, 2], "numbers only: nothing to draw")
        self.assertFalse(media_stream.annotated_is_worker_safe(question),
                         "and no baked overlay either")
        self.assertTrue(hidden)
