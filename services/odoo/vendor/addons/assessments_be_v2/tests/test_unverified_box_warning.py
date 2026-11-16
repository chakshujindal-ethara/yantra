# -*- coding: utf-8 -*-
"""A labelling question must not ship boxes nobody checked against the picture.

THE DEFECT THIS LOCKS DOWN. `label_boxes_json` holds coordinates the TEXT model
authored BEFORE any image existed, so they align with the render only by luck.
The synthetic lane already refused to draw them - but the source_url lane fell
back to `_draw_dense_preview` the moment DOM capture failed, which stamps those
same guesses onto the pixels. A placeholder source_url ("https://x.com") is
enough to trigger it: q303 shipped with box 5 "Cat picture" sitting on a potted
plant and box 4 "City skyline" running off the frame, and the review queue said
nothing was wrong.

Capture failure now falls through to vision detection, and a draft that ends up
with unverified geometry says so on itself.
"""
import json

from odoo.tests.common import TransactionCase


class TestUnverifiedBoxWarning(TransactionCase):

    def _draft(self, boxes=None, qtype="image_label"):
        prompt = self.env["assessments.be.prompt"].create({"name": "box probe"})
        vals = {
            "prompt_id": prompt.id,
            "name": "Categorise the boxed entities",
            "question_prompt": "Categorise each numbered box.",
            "question_type": qtype,
        }
        if boxes is not None:
            vals["label_boxes_json"] = json.dumps(boxes)
        return self.env["assessments.be.prompt.question"].create(vals)

    def test_guessed_boxes_are_flagged(self):
        """box_px that is just box_2d rescaled means nothing was checked."""
        d = self._draft(boxes=[
            {"number": 1, "box_2d": [200, 400, 800, 600], "label": "Woman"},
            {"number": 2, "box_2d": [300, 450, 500, 550], "label": "Blazer"},
        ])
        # _draw_dense_preview's own mapping: round(v / 1000 * 1024).
        scale = 1024 / 1000.0
        drawn = [
            {"number": 1, "box_px": [round(400 * scale), round(200 * scale),
                                     round(600 * scale), round(800 * scale)]},
            {"number": 2, "box_px": [round(450 * scale), round(300 * scale),
                                     round(550 * scale), round(500 * scale)]},
        ]
        images = [{"slot": "single", "detections_json": json.dumps(drawn)}]
        self.assertTrue(d._warn_on_unverified_boxes(images))
        self.assertIn("NOT confirmed", d.gen_warnings)

    def test_detected_boxes_are_not_flagged(self):
        """Real detection finds its own rectangles, unrelated to the guesses."""
        d = self._draft(boxes=[
            {"number": 1, "box_2d": [200, 400, 800, 600], "label": "Woman"},
            {"number": 2, "box_2d": [300, 450, 500, 550], "label": "Blazer"},
        ])
        drawn = [
            {"number": 1, "box_px": [118, 640, 902, 771]},
            {"number": 2, "box_px": [301, 88, 517, 402]},
        ]
        images = [{"slot": "single", "detections_json": json.dumps(drawn)}]
        self.assertFalse(d._warn_on_unverified_boxes(images))
        self.assertFalse(d.gen_warnings)

    def test_a_different_box_count_is_detection(self):
        """Detection dropping or adding a box cannot be a rescale of the guesses."""
        d = self._draft(boxes=[{"number": 1, "box_2d": [200, 400, 800, 600]}])
        images = [{"slot": "single", "detections_json": json.dumps([
            {"number": 1, "box_px": [10, 20, 30, 40]},
            {"number": 2, "box_px": [50, 60, 70, 80]},
        ])}]
        self.assertFalse(d._warn_on_unverified_boxes(images))

    def test_nothing_drawn_IS_flagged_now(self):
        """Nothing drawn used to return silently. That was the hole.

        The old assertion here was `assertFalse`, and its docstring said "missing
        boxes warn elsewhere" - which was never true: no other lane reported it,
        and a comment in `_detect_label_on_render` claiming `_draw_dense_preview`
        was the last-resort fallback was describing a method with no callers. So
        a labelling question with an authored key and zero drawn boxes reached the
        review queue with nothing said about it, which is the live 290/295/306
        state.

        `_warn_on_missing_boxes` now covers it, and this asserts the delegation
        rather than the old silence. The detect cron retrying after approval is
        still true and still welcome - it is just not a reason to withhold the
        fact from the person deciding.
        """
        d = self._draft(boxes=[{"number": 1, "box_2d": [1, 2, 3, 4]}])
        self.assertTrue(d._warn_on_unverified_boxes([{"slot": "single"}]))
        self.assertIn("NO numbered boxes", d.gen_warnings or "")

    def test_a_draft_with_no_boxes_is_not_flagged(self):
        """Nothing to mis-place, so there is nothing to warn about."""
        d = self._draft()
        self.assertFalse(
            d._warn_on_unverified_boxes([{"slot": "single"}]))

    def test_only_labelling_questions_are_checked(self):
        d = self._draft(boxes=[{"number": 1, "box_2d": [1, 2, 3, 4]}],
                        qtype="mcq")
        self.assertFalse(d._warn_on_unverified_boxes([{"slot": "single"}]))

    def _guessed_images(self, boxes, size=1024):
        """The images payload `_draw_dense_preview` would have produced."""
        scale = size / 1000.0
        drawn = []
        for b in boxes:
            y1, x1, y2, x2 = b["box_2d"]
            drawn.append({"number": b["number"], "box_px": [
                round(x1 * scale), round(y1 * scale),
                round(x2 * scale), round(y2 * scale)]})
        return [{"slot": "single", "detections_json": json.dumps(drawn)}]

    def test_the_warning_is_not_duplicated(self):
        boxes = [{"number": 1, "box_2d": [200, 400, 800, 600]}]
        d = self._draft(boxes=boxes)
        images = self._guessed_images(boxes)
        self.assertTrue(d._warn_on_unverified_boxes(images))
        first = d.gen_warnings
        self.assertFalse(d._warn_on_unverified_boxes(images))
        self.assertEqual(d.gen_warnings, first)

    def test_an_existing_warning_survives(self):
        boxes = [{"number": 1, "box_2d": [200, 400, 800, 600]}]
        d = self._draft(boxes=boxes)
        d.gen_warnings = "- The question quotes the SOP at the candidate."
        d._warn_on_unverified_boxes(self._guessed_images(boxes))
        self.assertIn("quotes the SOP", d.gen_warnings)
        self.assertIn("NOT confirmed", d.gen_warnings)

class TestMissingBoxWarning(TransactionCase):
    """A key with NO drawn boxes has to reach the reviewer as a warning.

    THE SILENT CASE. `_warn_on_unverified_boxes` compares the AUTHORED geometry
    against the DRAWN geometry, so with nothing drawn it had nothing to compare
    and returned False - no warning, no log line, nothing in the queue. That is
    the live 290/295/306 state: a key naming 1, 3 and 2 boxes beside an image
    with no markers on it.

    A comment in `_detect_label_on_render` said `_draw_dense_preview` "stays as
    the LAST resort" and would cover this. It does not - that method has no
    callers at all - and believing it did is what left this path unexamined.
    """

    def _draft(self, boxes, rubric=None):
        # `prompt_id` is required and NOT NULL - a draft belongs to the generator
        # that authored it, so there is no such thing as an orphan one.
        prompt = self.env["assessments.be.prompt"].create({"name": "box probe"})
        draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": prompt.id,
            "name": "Label the entities",
            "question_prompt": "Name each numbered box.",
            "question_type": "image_label",
            "label_boxes_json": json.dumps(boxes),
        })
        if rubric is not None:
            # A DRAFT's carrier is `rubric_json`; `subjective_rubric_json` is the
            # BANK's field, written when the draft is approved. Two models, two
            # names - see models/prompt.py.
            draft.rubric_json = json.dumps(rubric)
        return draft

    def test_nothing_drawn_warns_the_reviewer(self):
        """Reverting the `_warn_on_missing_boxes` delegation leaves this red."""
        draft = self._draft(
            [{"number": 1, "box_2d": [10, 10, 200, 200]},
             {"number": 2, "box_2d": [300, 300, 500, 500]}],
            rubric={"ideal_labels": {"1": "People", "2": "Clothing"}})
        fired = draft._warn_on_unverified_boxes(
            [{"slot": "single", "detections_json": "[]"}])
        self.assertTrue(
            fired,
            "an answer key beside zero drawn boxes must be reported")
        self.assertIn(
            "NO numbered boxes", draft.gen_warnings or "",
            "the warning has to say what is missing, in the reviewer's words")

    def test_the_warning_is_not_duplicated_on_a_retry(self):
        """A re-render must not stack the same sentence twice."""
        draft = self._draft([{"number": 1, "box_2d": [1, 1, 2, 2]}])
        images = [{"slot": "single", "detections_json": "[]"}]
        self.assertTrue(draft._warn_on_unverified_boxes(images))
        self.assertFalse(draft._warn_on_unverified_boxes(images))
        self.assertEqual((draft.gen_warnings or "").count("NO numbered boxes"), 1)


class TestNonSquareGuessDetection(TransactionCase):
    """The guessed-box detector has to work on an image that is not square.

    `_boxes_are_authored_guesses` collected every edge into ONE ratio set, but
    `_draw_dense_preview` scales x by the width and y by the height. On a
    non-square image those differ, so a straight rescale of the model's guesses
    produced four distinct ratios, sailed past the `<= 2` test, and the "these
    were never checked" warning never fired.

    Invisible until now because every fixture in this module used a square 1024
    image - which is why the fixture below is deliberately 1280x800.
    """

    W, H = 1280, 800

    def _rescaled(self, guesses):
        """What `_draw_dense_preview` would draw for these guesses, verbatim:
        x by the width, y by the height."""
        drawn = []
        for g in guesses:
            y0, x0, y1, x1 = g["box_2d"]
            drawn.append({"number": g["number"], "box_px": [
                round(x0 / 1000 * self.W), round(y0 / 1000 * self.H),
                round(x1 / 1000 * self.W), round(y1 / 1000 * self.H)]})
        return drawn

    def test_rescaled_guesses_are_recognised_on_a_non_square_image(self):
        Draft = self.env["assessments.be.prompt.question"]
        guesses = [
            {"number": 1, "box_2d": [100, 120, 300, 340]},
            {"number": 2, "box_2d": [400, 200, 620, 480]},
            {"number": 3, "box_2d": [650, 500, 880, 760]},
            {"number": 4, "box_2d": [120, 600, 340, 900]},
            {"number": 5, "box_2d": [500, 60, 700, 260]},
            {"number": 6, "box_2d": [700, 300, 950, 560]},
        ]
        self.assertTrue(
            Draft._boxes_are_authored_guesses(
                guesses, self._rescaled(guesses)),
            "six rescaled guesses on a 1280x800 image must still read as "
            "guesses - one shared ratio set made this False and suppressed the "
            "warning entirely")

    def test_genuinely_detected_boxes_are_not_flagged(self):
        """The guard must not cry wolf on real detection output."""
        Draft = self.env["assessments.be.prompt.question"]
        guesses = [
            {"number": 1, "box_2d": [100, 120, 300, 340]},
            {"number": 2, "box_2d": [400, 200, 620, 480]},
        ]
        detected = [
            {"number": 1, "box_px": [7, 91, 431, 233]},
            {"number": 2, "box_px": [261, 318, 613, 501]},
        ]
        self.assertFalse(
            Draft._boxes_are_authored_guesses(guesses, detected),
            "vision output does not reproduce the authored geometry")
