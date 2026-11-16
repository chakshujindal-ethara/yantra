"""A labelling question has ONE numbered box list and ONE overlay (2026-09-29,
prod question 1170).

1170 showed two overlays at once: the generator's 4 panel rectangles (drawn by
the client) and 17 detected controls baked into an AI picture of invented UI.
The candidate got 17 inputs and was graded on the 4 panels.

1. The overlay served is the one numbered like the scoring key, everywhere:
   exam inputs, exam picture, bank preview and draft preview.
2. The list is made by ONE method - the generator's named boxes placed on
   the rendered picture by vision, else (fallback) vision's own detections -
   and the boxes, answer key, rubric and golden answer are all written from it.
3. Pictures are AI-made; a live website is screenshotted only for a generator
   that asks for it, with the AI picture as its fallback.
"""
import base64
import io
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger

from ..controllers.api import candidate as candidate_api
from ..controllers.api import serializers
from ..services import dom_capture, labelling, vertex

PNG = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChw"
       "GA60e6kgAAAABJRU5ErkJggg==")
PNG_URL = "data:image/png;base64,%s" % PNG
PANELS = [{"number": n, "box_2d": [100 * n, 100, 100 * n + 80, 700],
           "label": "Panel %s" % n, "description": "Does %s" % n}
          for n in range(1, 5)]
BEHAVIOURAL = [{"number": n, "element": "Panel %s" % n,
                "functionality": "Does %s" % n} for n in range(1, 5)]
# Detections carry pixel boxes only, as the detect pass writes them.
DETECTED = [{"number": n, "label": "Control %s" % n, "box_px": [n, n, n + 9,
                                                                 n + 9]}
            for n in range(1, 18)]


def _regions(numbers):
    return [b["number"] for b in numbers if isinstance(b, dict)
            and len(b.get("box_2d") or []) == 4]


@tagged("-at_install", "post_install")
class TestOneOverlay(TransactionCase):

    def _question(self, **image):
        question = self.env["assessments.be.question"].create({
            "name": "Label %s" % uuid4().hex[:6],
            "question_type": "image_label", "detection_mode": "ui",
            "prompt": "Describe each numbered panel.",
        })
        self.env["assessments.be.question.image"].create(dict({
            "question_id": question.id, "slot": "single", "label": "Shot",
            "image": PNG, "annotated_image": PNG,
        }, **image))
        question.invalidate_recordset()
        return question

    def _1170(self):
        return self._question(
            source_url="https://www.cvat.ai/",
            label_boxes_json=json.dumps(PANELS),
            behavioural_key_json=json.dumps(BEHAVIOURAL),
            detections_json=json.dumps(DETECTED))

    def test_the_1170_shape_draws_the_keys_four_panels_only(self):
        question = self._1170()

        mode, boxes = labelling.label_overlay(question)

        self.assertEqual(mode, "regions")
        self.assertEqual(_regions(boxes), [1, 2, 3, 4])

    def test_the_candidate_gets_the_keys_four_inputs_not_seventeen(self):
        boxes = candidate_api.EtpAssessmentApiCandidate()._label_boxes(
            self._1170())
        self.assertEqual(_regions(boxes), [1, 2, 3, 4])

    def test_the_baked_detection_picture_is_not_served_beside_them(self):
        question = self._1170()

        images, _videos = serializers.question_media(question, "tok")
        detail = serializers.bank_question_detail(question)

        self.assertEqual(images[0]["annotated_url"], "")
        self.assertEqual(detail["images"][0]["annotated_admin_url"], "")
        self.assertEqual(_regions(detail["label_boxes"]), [1, 2, 3, 4])

    def test_a_captured_page_serves_its_baked_picture_and_numbers(self):
        question = self._question(
            source_url="https://example.org/",
            capture_viewport="1440x900@2x 2026-09-29T10:00:00Z",
            dom_manifest_json=json.dumps(
                [{"number": n, "box_css": [0, 0, 9, 9]} for n in (1, 2, 3)]),
            label_boxes_json=json.dumps(
                [{"number": n, "box_css": [0, 0, 9, 9]} for n in (1, 2, 3)]),
            behavioural_key_json=json.dumps(BEHAVIOURAL[:3]),
            detections_json=json.dumps(DETECTED[:3]))

        self.assertEqual(labelling.label_overlay(question), ("baked", [1, 2, 3]))
        images, _videos = serializers.question_media(question, "tok")
        self.assertTrue(images[0]["annotated_url"])

    def test_a_key_whose_rectangles_are_incomplete_draws_nothing(self):
        # The baked picture numbers something else: never the second overlay.
        question = self._question(
            label_boxes_json=json.dumps(PANELS[:2]),
            behavioural_key_json=json.dumps(BEHAVIOURAL),
            detections_json=json.dumps(DETECTED))

        self.assertEqual(labelling.label_overlay(question),
                         ("none", [1, 2, 3, 4]))
        self.assertFalse(serializers.serves_baked_overlay(question))


@tagged("-at_install", "post_install")
class TestADraftPreviewShowsOneOverlay(TransactionCase):

    def _draft(self, **vals):
        prompt = self.env["assessments.be.prompt"].create(
            {"name": "Overlay %s" % uuid4().hex[:6]})
        return self.env["assessments.be.prompt.question"].create(dict({
            "prompt_id": prompt.id, "name": "Label the panels",
            "question_type": "image_label",
        }, **vals))

    def test_the_authored_key_is_previewed_on_the_plain_picture(self):
        draft = self._draft(
            label_boxes_json=json.dumps(PANELS),
            behavioural_key_json=json.dumps(BEHAVIOURAL),
            images_json=json.dumps([{
                "slot": "single", "data": PNG_URL, "annotated_data": PNG_URL,
                "detections_json": json.dumps(DETECTED)}]))

        images, _videos = serializers.draft_media(draft)

        self.assertIn("plain=1", images[0]["admin_url"])
        self.assertFalse(images[0]["has_annotated"])
        self.assertEqual(_regions(serializers.draft_detail(draft)[
            "label_boxes"]), [1, 2, 3, 4])

    def test_a_detection_keyed_draft_previews_the_baked_picture(self):
        # No behavioural key: approval keys on the detections, so the preview
        # shows their baked picture and sends no guessed rectangles to draw.
        draft = self._draft(
            label_boxes_json=json.dumps(PANELS),
            images_json=json.dumps([{
                "slot": "single", "data": PNG_URL, "annotated_data": PNG_URL,
                "detections_json": json.dumps(DETECTED[:5])}]))

        images, _videos = serializers.draft_media(draft)

        self.assertNotIn("plain=1", images[0]["admin_url"])
        self.assertTrue(images[0]["has_annotated"])
        self.assertEqual(serializers.draft_detail(draft)["label_boxes"],
                         [1, 2, 3, 4, 5])


def _png(w=400, h=240):
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (w, h), (240, 240, 240)).save(buf, format="PNG")
    return buf.getvalue()


RENDER = "data:image/png;base64,%s" % base64.b64encode(_png()).decode()
LOCATED = {n: [100 * n, 520, 100 * n + 60, 900] for n in range(1, 5)}
DETECTED_RAW = [{"box_2d": [50 * n, 50, 50 * n + 40, 300],
                 "label": "Button %s" % n, "description": "Opens %s" % n}
                for n in range(1, 4)]


def _no_call(*_a, **_k):
    raise AssertionError("this method must not run here")


class _LabelDraft(TransactionCase):

    def _draft(self, live=False, **vals):
        prompt = self.env["assessments.be.prompt"].create({
            "name": "Boxes %s" % uuid4().hex[:6],
            "image_label_live_capture": live})
        return self.env["assessments.be.prompt.question"].create(dict({
            "prompt_id": prompt.id, "name": "Label the panels",
            "question_type": "image_label", "detection_mode": "ui",
            "label_boxes_json": json.dumps(PANELS),
            "behavioural_key_json": json.dumps(BEHAVIOURAL),
            "rubric_json": json.dumps({
                "ideal_labels": "1. Does 1\n2. Does 2\n3. Does 3\n4. Does 4",
                "mandatory_elements": ["Names the L3 panel"],
                "penalty_rules": ["L2 is not L3"],
                "scoring_guide": "One point per box."}),
            "solution_json": json.dumps(
                {str(n): "Does %s" % n for n in range(1, 5)}),
            "image_brief_json": json.dumps([{
                "slot": "single", "label": "Screenshot",
                "prompt": "The labelling tool with four panels"}]),
            "image_state": "pending",
        }, **vals))

    def _render(self, draft, located=None, detected=None, capture=None,
                ai=True):
        def render(*_a, **_k):
            if not ai:
                raise AssertionError("an AI picture was paid for")
            return [{"slot": "single", "label": "Screenshot", "data": RENDER}]

        def locate(*_a, **_k):
            if isinstance(located, Exception):
                raise located
            return located if located is not None else {}
        with patch.object(vertex, "render_draft_images", render), \
                patch.object(vertex, "locate_label_elements", locate), \
                patch.object(vertex, "detect_image_elements",
                             (lambda *a, **k: detected) if detected is not None
                             else _no_call), \
                patch.object(dom_capture, "PLAYWRIGHT_AVAILABLE", True), \
                patch.object(dom_capture, "capture_and_annotate",
                             capture or _no_call):
            return draft._render_all_images()

    def _carriers(self, draft):
        """Box numbers as each carrier sees them - they must all agree."""
        spec = draft._image_specs()[0]
        return {
            "drawn": [d["number"] for d in json.loads(spec["detections_json"])],
            "geometry": [b["number"] for b in json.loads(
                draft.label_boxes_json)],
            "key": [e["number"] for e in json.loads(
                draft.behavioural_key_json)],
            "golden": [int(k) for k in json.loads(draft.solution_json)],
            "rubric": [int(line.split(".")[0]) for line in json.loads(
                draft.rubric_json)["ideal_labels"].splitlines()],
        }


@tagged("-at_install", "post_install")
class TestOneBoxList(_LabelDraft):

    def test_named_boxes_are_placed_where_vision_found_them(self):
        draft = self._draft()

        self.assertTrue(self._render(draft, located=LOCATED))

        spec = draft._image_specs()[0]
        self.assertEqual(spec["boxes_from"], "named")
        self.assertTrue(spec["annotated_data"])
        for numbers in self._carriers(draft).values():
            self.assertEqual(numbers, [1, 2, 3, 4])
        geometry = json.loads(draft.label_boxes_json)
        self.assertEqual(geometry[0]["box_2d"], LOCATED[1], "vision's, not "
                         "the generator's guess")
        rubric = json.loads(draft.rubric_json)
        self.assertEqual(rubric["mandatory_elements"], ["Names the L3 panel"])
        self.assertEqual(json.loads(draft.solution_json)["2"], "Does 2")

    def test_a_named_box_missing_from_the_picture_leaves_every_carrier(self):
        draft = self._draft()
        located = {n: LOCATED[n] for n in (1, 2, 4)}

        self._render(draft, located=located)

        for numbers in self._carriers(draft).values():
            self.assertEqual(numbers, [1, 2, 4])
        self.assertIn("3 Panel 3", draft.gen_warnings)

    def test_too_few_named_boxes_fall_back_to_detection_everywhere(self):
        draft = self._draft()

        self._render(draft, located={1: LOCATED[1]}, detected=DETECTED_RAW)

        spec = draft._image_specs()[0]
        self.assertEqual(spec["boxes_from"], "detected")
        for numbers in self._carriers(draft).values():
            self.assertEqual(numbers, [1, 2, 3])
        self.assertEqual(json.loads(draft.solution_json)["1"], "Opens 1")
        rubric = json.loads(draft.rubric_json)
        self.assertNotIn("mandatory_elements", rubric,
                         "it described the generator's boxes")
        self.assertEqual(rubric["scoring_guide"], "One point per box.")
        self.assertIn("rebuilt from what vision found", draft.gen_warnings)

    @mute_logger("odoo.addons.assessments_be_v2.models.prompt")
    def test_a_failed_locate_call_falls_back_to_detection(self):
        draft = self._draft()

        self._render(draft, located=RuntimeError("503"),
                     detected=DETECTED_RAW)

        self.assertEqual(draft._image_specs()[0]["boxes_from"], "detected")
        self.assertIn("503", draft.gen_warnings)

    def test_no_named_list_goes_straight_to_detection_without_a_warning(self):
        draft = self._draft(label_boxes_json=False, behavioural_key_json=False)

        self._render(draft, detected=DETECTED_RAW)

        self.assertEqual(draft._image_specs()[0]["boxes_from"], "detected")
        self.assertFalse(draft.gen_warnings)

    def test_approval_keeps_one_list_on_the_bank_question(self):
        draft = self._draft()
        self._render(draft, located=LOCATED)

        question = self.env["assessments.be.question"].create({
            "name": "Approved", "question_type": "image_label",
            "detection_mode": "ui", "prompt": "Label it.",
            "subjective_rubric_json": draft.rubric_json,
            "solution_json": draft.solution_json})
        image = self.env["assessments.be.question.image"].create({
            "question_id": question.id, "slot": "single", "label": "Shot",
            "image": RENDER.split(",", 1)[1]})
        spec = draft._image_specs()[0]
        draft._carry_label_capture(image)
        draft._carry_or_detect_label(question, image, "single", spec)
        draft._apply_authored_label_key(question)
        question.invalidate_recordset()

        self.assertFalse(image.source_url)
        self.assertEqual(
            [d["number"] for d in json.loads(image.detections_json)],
            [1, 2, 3, 4])
        mode, boxes = labelling.label_overlay(question)
        self.assertEqual([b["number"] for b in boxes], [1, 2, 3, 4])
        self.assertEqual(boxes[0]["box_2d"], LOCATED[1])


CAPTURE = {
    "dom_manifest": [{"number": n, "box_css": [0, 0, 9, 9]} for n in (1, 2, 3)],
    "screenshot_png": _png(),
    "annotated_png": _png(),
    "label_key": [{"number": n, "box_px": [0, 0, 9, 9]} for n in (1, 2, 3)],
    "behavioural_key": [{"number": n, "element": "Link %s" % n,
                         "functionality": "Opens page %s" % n}
                        for n in (1, 2, 3)],
}


@tagged("-at_install", "post_install")
class TestLiveScreenshotsAreOptIn(_LabelDraft):

    def test_without_the_switch_a_url_is_ignored_and_the_picture_is_ai(self):
        draft = self._draft(source_url="https://example.org/")

        self._render(draft, located=LOCATED)

        self.assertEqual(draft._image_specs()[0]["boxes_from"], "named")
        self.assertFalse(draft.gen_warnings, "no capture was even tried")
        self.assertNotIn("captured_from", draft._image_specs()[0])

    def test_with_the_switch_the_page_is_captured_and_no_ai_is_paid(self):
        draft = self._draft(live=True, source_url="https://example.org/")

        self.assertTrue(self._render(draft, capture=lambda *a, **k: CAPTURE,
                                     ai=False))

        spec = draft._image_specs()[0]
        self.assertEqual(spec["captured_from"], "https://example.org/")
        self.assertEqual(json.loads(draft.solution_json),
                         {"1": "Opens page 1", "2": "Opens page 2",
                          "3": "Opens page 3"},
                         "the golden answer is the page's own list")
        self.assertEqual(labelling.draft_label_overlay(draft),
                         ("baked", [1, 2, 3]))

    @mute_logger("odoo.addons.assessments_be_v2.models.prompt")
    def test_a_failed_capture_falls_back_to_an_ai_picture_and_says_why(self):
        draft = self._draft(live=True, source_url="https://example.org/")

        def down(*_a, **_k):
            raise RuntimeError("net::ERR_NAME_NOT_RESOLVED")
        self.assertTrue(self._render(draft, capture=down, located=LOCATED))

        self.assertEqual(draft.image_state, "rendered")
        self.assertEqual(draft._image_specs()[0]["boxes_from"], "named")
        self.assertIn("ERR_NAME_NOT_RESOLVED", draft.gen_warnings)
        self.assertIn("AI-made picture was used", draft.gen_warnings)

    def test_an_error_page_is_not_used_as_the_picture(self):
        # eBay served its "SORRY - Go to homepage" page to the capture browser
        # (2026-09-29): one control, a useless question.
        draft = self._draft(live=True, source_url="https://example.org/")
        error_page = dict(CAPTURE, dom_manifest=CAPTURE["dom_manifest"][:1])

        self._render(draft, capture=lambda *a, **k: error_page,
                     located=LOCATED)

        self.assertEqual(draft._image_specs()[0]["boxes_from"], "named")
        self.assertIn("error or bot-check page", draft.gen_warnings)
        self.assertEqual(json.loads(draft.behavioural_key_json), BEHAVIOURAL,
                         "the generator's own list survives a rejected page")

    @mute_logger("odoo.addons.assessments_be_v2.models.prompt")
    def test_an_ai_fallback_is_approved_without_its_url(self):
        # Else the bank's detect cron would re-shoot the page after approval
        # and replace the approved picture and its key.
        draft = self._draft(live=True, source_url="https://example.org/")

        def down(*_a, **_k):
            raise RuntimeError("timeout")
        self._render(draft, capture=down, located=LOCATED)
        question = self.env["assessments.be.question"].create({
            "name": "Approved", "question_type": "image_label",
            "detection_mode": "ui", "prompt": "Label it."})
        image = self.env["assessments.be.question.image"].create({
            "question_id": question.id, "slot": "single", "label": "Shot",
            "image": RENDER.split(",", 1)[1]})

        draft._carry_label_capture(image)

        self.assertFalse(image.source_url)

    def test_a_later_capture_clears_the_failure_note(self):
        draft = self._draft(live=True, source_url="https://example.org/")

        def quota(*_a, **_k):
            raise vertex.VertexQuotaError("429")
        with patch.object(vertex, "render_draft_images", quota), \
                patch.object(dom_capture, "PLAYWRIGHT_AVAILABLE", True), \
                patch.object(dom_capture, "capture_and_annotate",
                             lambda *a, **k: {}):
            draft._render_all_images()
        self.assertIn("could not be screenshotted", draft.gen_warnings)

        self._render(draft, capture=lambda *a, **k: CAPTURE, ai=False)

        self.assertNotIn("could not be screenshotted", draft.gen_warnings or "")

    def test_approval_carries_the_screenshot_the_reviewer_saw(self):
        draft = self._draft(live=True, source_url="https://example.org/")
        self._render(draft, capture=lambda *a, **k: CAPTURE, ai=False)
        question = self.env["assessments.be.question"].create({
            "name": "Approved", "question_type": "image_label",
            "detection_mode": "ui", "prompt": "Label it."})
        image = self.env["assessments.be.question.image"].create({
            "question_id": question.id, "slot": "single", "label": "Shot",
            "image": PNG})
        spec = draft._image_specs()[0]

        draft._carry_label_capture(image)
        draft._carry_or_detect_label(question, image, "single", spec)

        self.assertTrue(image.annotated_image)
        self.assertTrue(image.capture_viewport)
        self.assertEqual(len(json.loads(image.detections_json)), 3)
        question.invalidate_recordset()
        self.assertEqual(labelling.label_overlay(question),
                         ("baked", [1, 2, 3]))


@tagged("-at_install", "post_install")
class TestGenerationAsksForAnAIPicture(TransactionCase):

    def test_the_labelling_contract_asks_for_no_website(self):
        contract = vertex._image_type_contract("image_label")
        self.assertNotIn("source_url", contract)
        self.assertIn("AI-MADE", contract)

    def test_an_ai_brief_is_a_valid_labelling_item(self):
        item = {"question_type": "image_label", "name": "Label it",
                "prompt": "Name each numbered panel.",
                "image_specs": {"images": [{"slot": "single",
                                            "prompt": "A labelling tool"}],
                                "answer_key": {"ideal_labels": {"1": "Plays"}}}}
        # With no site to fall back on, only the brief can make it valid.
        with patch.object(vertex, "_image_label_site_pool", lambda: []):
            errors = vertex._validate_question_item(item, "image_label")
        self.assertFalse([e for e in errors if "image_label" in e], errors)

    def _generate(self, live):
        gen = self.env["assessments.be.prompt"].create({
            "name": "Labelling %s" % uuid4().hex[:6],
            "source_text": "Label the tool's panels.",
            "image_label_live_capture": live})
        item = {"name": "Label the tool", "question_type": "image_label",
                "prompt": "Name what each numbered box does.",
                "image_specs": {
                    "source_url": "https://example.org/",
                    "application": "Example tool",
                    "images": [{"slot": "single", "label": "Screenshot",
                                "prompt": "The tool with two panels"}],
                    "boxes": [{"number": n, "box_2d": [10, 10, 90, 90],
                               "element": "Panel %s" % n,
                               "functionality": "Does %s" % n}
                              for n in (1, 2)],
                    "answer_key": {"ideal_labels": {"1": "Does 1",
                                                    "2": "Does 2"}}}}
        raw = json.dumps({"questions": [item], "solutions": [
            {"answers": {"1": "Does 1", "2": "Does 2"}}]})
        with patch.object(vertex, "_call_vertex", return_value=raw) as call, \
                patch.object(vertex, "_selfheal_generation",
                             side_effect=lambda env, pr, items, *a, **k: items):
            ids = vertex.generate_questions_from_sop(self.env, gen, report={})
        return (self.env["assessments.be.prompt.question"].browse(ids),
                str(call.call_args_list))

    def test_a_generator_without_the_switch_keeps_no_website(self):
        draft, sent = self._generate(live=False)

        self.assertEqual(len(draft), 1)
        self.assertFalse(draft.source_url)
        self.assertEqual(draft.detection_mode, "ui")
        self.assertNotIn("LIVE WEBSITE SCREENSHOTS", sent)

    def test_a_generator_with_the_switch_asks_for_and_keeps_the_site(self):
        draft, sent = self._generate(live=True)

        self.assertEqual(draft.source_url, "https://example.org/")
        self.assertIn("LIVE WEBSITE SCREENSHOTS", sent)

