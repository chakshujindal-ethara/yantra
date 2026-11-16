# -*- coding: utf-8 -*-
"""The read contract the Odoo annotation editor is built on.

THE GAP. `as_studio_annotation_item` returns None for THREE unrelated reasons -
not a labelling question, no image uploaded, an image with no markers on it -
and /api/v1/bank/<id>/studio_item is right to collapse all three into one 404,
because its caller is only deciding whether to offer a button. A FIELD WIDGET
cannot: it is already on screen, so it has to say which one it is, and in the
third case it has to OPEN ANYWAY. A plate with no boxes is precisely the plate
an examiner needs to draw the first box on, and a question whose detection never
ran is the commonest way to arrive at one.

`studio_annotation_editor_payload` is that read. These tests pin the three
things a widget cannot recover from on its own:

  * WHICH refusal it is, so the empty state can name the fix rather than saying
    "nothing to edit" over a form whose Image Evaluation tab is one click away.
  * That a boxless plate is EDITABLE, not refused - the whole reason the method
    exists rather than the widget calling `as_studio_annotation_item` directly.
  * That markers with no drawable geometry survive the trip. The DOM-capture
    lane stores `box_px` (PIXELS, not the 0-1000 grid), and
    `as_studio_annotation_item` reports those in `annotation_count` /
    `golden_labels` but NOT in `regions`. A widget that re-united those two
    halves in JavaScript would be a second copy of the union
    `apply_studio_annotation_item` computes on the way back in - and that
    method's own comment records the measured damage from getting it wrong: a
    no-op save silently deleted a pixel-only marker, and its mark, off the
    paper.

The geometry itself is NOT re-tested here.
`test_a_generated_draft_opens_in_the_annotation_editor` owns the forward/inverse
transform; this file only proves the wrapper does not lose or invent a marker on
the way to the browser, which is why the last test composes the payload with the
save the widget actually calls.
"""
import json

from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestTheOdooAnnotationEditorOpensAndSaves(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.Image = self.env["assessments.be.question.image"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Editor fixture %s" % uuid4().hex[:6]})

    def _labelling_question(self, *, detections=None, solution=None,
                            question_type="image_label", with_image=True,
                            image_url="https://example.test/plate.png"):
        question = self.Question.create({
            "name": "Mark each defect %s" % uuid4().hex[:4],
            "question_type": question_type,
            "prompt": "Mark and name each defect you can see.",
            "generator_id": self.generator.id,
            "solution_json": json.dumps(solution or {}),
        })
        if with_image:
            vals = {
                "question_id": question.id,
                "slot": "single",
                "label": "Scene",
                "image_url": image_url,
            }
            if detections is not None:
                vals["detections_json"] = json.dumps(detections)
            self.Image.create(vals)
        return question

    # ── the three refusals, told apart ─────────────────────────────────────

    def test_a_non_labelling_question_says_so_instead_of_going_blank(self):
        """`ok` False with a NAMED reason, not None.

        The widget renders one empty state per reason. Collapsing them would put
        "nothing to mark up" on a subjective question whose actual fix is one
        selection field away, which reads as the editor being broken.
        """
        question = self._labelling_question(
            question_type="subjective_rubric",
            detections=[{"number": 1, "box_2d": [0, 0, 100, 100]}])

        payload = question.studio_annotation_editor_payload()

        self.assertFalse(payload["ok"])
        self.assertEqual(payload["reason"], "not_labelling")
        self.assertEqual(payload["markers"], [])

    def test_a_labelling_question_with_no_image_names_the_missing_image(self):
        question = self._labelling_question(with_image=False)

        payload = question.studio_annotation_editor_payload()

        self.assertFalse(payload["ok"])
        self.assertEqual(payload["reason"], "no_image")

    def test_an_image_row_with_no_bitmap_and_no_url_is_refused(self):
        """Nothing to draw ON. The row exists but carries neither uploaded bytes
        nor a URL, so `image_admin_url` computes to False as well - an `<img>`
        with an empty src is a broken-image icon the operator cannot act on."""
        question = self._labelling_question(image_url="")

        payload = question.studio_annotation_editor_payload()

        self.assertFalse(payload["ok"])
        self.assertEqual(payload["reason"], "no_media")

    # ── the case the wrapper exists for ────────────────────────────────────

    def test_a_plate_with_no_boxes_opens_empty_and_editable(self):
        """THE WHOLE POINT. `as_studio_annotation_item` returns None here, and a
        widget that trusted that verdict would refuse to open the editor for
        every question whose detection has not run - i.e. exactly the questions
        that need a box drawn by hand."""
        question = self._labelling_question(detections=[])
        self.assertIsNone(
            question.as_studio_annotation_item(),
            "the API's read still refuses this, and is right to")

        payload = question.studio_annotation_editor_payload()

        self.assertTrue(payload["ok"], "the editor must open on a bare plate")
        self.assertEqual(payload["reason"], "no_markers",
                         "and must be able to say that it is bare, so the "
                         "operator is told to drag rather than left guessing")
        self.assertEqual(payload["markers"], [])
        self.assertTrue(payload["media_url"], "there is a picture to draw on")
        self.assertGreaterEqual(
            payload["marker_cap"], 1,
            "a cap of 0 would refuse the first box; the model's own floor "
            "guarantees at least one")

    def test_the_cap_comes_from_the_generator_that_authored_the_question(self):
        """The widget disables drawing at the ceiling, so it has to be the SAME
        ceiling `question_image.write` enforces - otherwise the operator draws a
        box the write silently trims off."""
        self.generator.write({"image_label_count": 3})
        question = self._labelling_question(
            detections=[{"number": 1, "label": "One",
                         "box_2d": [0, 0, 100, 100]}])

        payload = question.studio_annotation_editor_payload()

        image = question.image_ids.filtered(lambda i: i.slot == "single")
        self.assertEqual(payload["marker_cap"], image._label_box_cap())
        self.assertEqual(payload["marker_cap"], 3)

    # ── markers, drawable and not ─────────────────────────────────────────

    def test_every_marker_arrives_and_says_whether_it_can_be_drawn(self):
        """One flat list, `drawable` per entry.

        Marker 2 is the DOM-capture lane's shape: `box_px` is pixels on the
        original bitmap, so painting it on a normalised overlay puts a numbered
        badge in the corner of the picture. It still has to REACH the widget,
        because its golden answer is editable and because a save derived from
        the drawable subset alone deletes it.
        """
        question = self._labelling_question(
            detections=[
                {"number": 1, "label": "Drawable", "box_2d": [100, 80, 300, 300]},
                {"number": 2, "label": "Pixels only", "box_px": [10, 10, 90, 90]},
            ])

        payload = question.studio_annotation_editor_payload()

        self.assertEqual([m["n"] for m in payload["markers"]], [1, 2])
        first, second = payload["markers"]
        self.assertTrue(first["drawable"])
        self.assertAlmostEqual(first["y"], 0.10, places=3)
        self.assertAlmostEqual(first["x"], 0.08, places=3)
        self.assertAlmostEqual(first["h"], 0.20, places=3)
        self.assertAlmostEqual(first["w"], 0.22, places=3)
        self.assertFalse(second["drawable"],
                         "box_px is not on the same grid and must not be drawn")
        self.assertEqual(second["label"], "Pixels only",
                         "its label is still the operator's to edit")
        self.assertEqual(payload["annotation_count"], 2)
        self.assertEqual(payload["unkeyed_markers"], 0)

    def test_a_marker_the_key_names_but_cannot_draw_still_arrives(self):
        """Drawn OR keyed, the same union the save applies on the way back.

        Marker 2 is a real marker - `detections_json` carries its number and
        `solution_json` its golden answer - it just has no coordinates. Deriving
        the editor's rows from `regions` alone would hide it, and a save built
        from what the editor showed would then delete a mark the candidate can
        earn. Note that a number appearing ONLY in `solution_json` is not a
        marker: `as_studio_annotation_item` filters `golden_labels` down to the
        markers the picture actually claims, and this wrapper inherits that
        rather than re-deciding it.
        """
        question = self._labelling_question(
            detections=[{"number": 1, "box_2d": [0, 0, 100, 100]},
                        {"number": 2}],
            solution={"ideal_labels": {"1": "Drawn", "2": "Keyed only",
                                       "9": "Not on this picture"}})

        payload = question.studio_annotation_editor_payload()

        self.assertEqual([m["n"] for m in payload["markers"]], [1, 2],
                         "marker 9 is keyed but the picture does not carry it")
        self.assertEqual(payload["markers"][1]["label"], "Keyed only")
        self.assertFalse(payload["markers"][1]["drawable"])
        self.assertEqual(payload["unkeyed_markers"], 0)

    def test_a_marker_that_is_neither_drawable_nor_keyed_is_reported_as_lost(self):
        """`unkeyed_markers` is a WARNING the widget shows BEFORE the save.

        Markers 1-3 here have malformed geometry and no golden answer, so they
        cannot be carried in the item shape at all and a save WILL drop them.
        Dropping a mark off a paper silently is the class of damage
        `apply_studio_annotation_item` refuses partial writes to avoid, so the
        count travels to the browser rather than the difference being swallowed.
        """
        question = self._labelling_question(
            detections=[
                {"number": 1, "box_2d": "not a list"},
                {"number": 2, "box_2d": [1, 2]},
                {"number": 3, "box_2d": ["a", "b", "c", "d"]},
                {"number": 4, "label": "Real", "box_2d": [0, 0, 100, 100]},
            ])

        payload = question.studio_annotation_editor_payload()

        self.assertEqual([m["n"] for m in payload["markers"]], [4])
        self.assertEqual(payload["annotation_count"], 4,
                         "the stored key really does carry four markers")
        self.assertEqual(payload["unkeyed_markers"], 3,
                         "and three of them cannot survive a save")

    def test_the_count_only_shape_is_expanded_to_numbered_markers(self):
        """Numerals baked into the picture, no coordinates and no key: 1..N is
        the only reading available, and it is the one `apply` falls back to. The
        widget must get rows to type labels into, not an empty list."""
        question = self._labelling_question(
            detections=[{"number": 1}, {"number": 2}, {"number": 3}])

        payload = question.studio_annotation_editor_payload()

        self.assertEqual([m["n"] for m in payload["markers"]], [1, 2, 3])
        self.assertTrue(all(not m["drawable"] for m in payload["markers"]))
        self.assertEqual(payload["unkeyed_markers"], 0)

    def test_the_payload_never_raises_on_a_malformed_key(self):
        """It feeds a FORM VIEW. An exception here replaces the whole question
        form with an error dialog - on the one screen whose other tabs are the
        operator's only way to repair the data that broke this call."""
        image_vals = {"detections_json": "{not json at all"}
        question = self._labelling_question(
            detections=[{"number": 1, "label": "Fine",
                         "box_2d": [0, 0, 100, 100]}])
        question.image_ids.write(image_vals)
        question.write({"solution_json": "]["})

        payload = question.studio_annotation_editor_payload()

        self.assertTrue(payload["ok"], "a bad key is still a drawable plate")
        self.assertEqual(payload["markers"], [])
        self.assertEqual(payload["reason"], "no_markers")

    # ── the widget's own round trip ────────────────────────────────────────

    def test_what_the_editor_saves_is_what_the_editor_re_opens(self):
        """THE HEADLINE FOR THE WIDGET, and the only test that can catch the
        two ends of it disagreeing.

        The widget reads `studio_annotation_editor_payload` and writes
        `apply_studio_annotation_item` - the SAME method
        /api/v1/bank/<id>/studio_item/save calls, not a copy of it. Composing
        the two must be the identity on geometry AND on the marker set,
        including the pixel-only marker that has no geometry to compare.
        """
        question = self._labelling_question(
            detections=[
                {"number": 1, "label": "Style drift", "box_2d": [100, 80, 300, 300]},
                {"number": 2, "label": "Pixels only", "box_px": [10, 10, 90, 90]},
            ])

        opened = question.studio_annotation_editor_payload()
        # Exactly the item the OWL widget builds: drawable markers as `regions`,
        # EVERY marker in `golden_labels`, and the count off the marker list.
        item = {
            "regions": [{"n": m["n"], "x": m["x"], "y": m["y"],
                         "w": m["w"], "h": m["h"]}
                        for m in opened["markers"] if m["drawable"]],
            "golden_labels": {str(m["n"]): m["label"]
                              for m in opened["markers"]},
            "annotation_count": len(opened["markers"]),
        }
        # Move marker 1 the way a drag would, and re-key it.
        item["regions"][0]["x"] = 0.40
        item["regions"][0]["y"] = 0.50
        item["golden_labels"]["1"] = "Moved and re-keyed"

        self.assertEqual(question.apply_studio_annotation_item(item), [],
                         "the item the widget builds must be accepted as-is")

        again = question.studio_annotation_editor_payload()
        self.assertEqual([m["n"] for m in again["markers"]], [1, 2],
                         "the pixel-only marker must survive a save that could "
                         "not draw it")
        moved = again["markers"][0]
        self.assertAlmostEqual(moved["x"], 0.40, places=2)
        self.assertAlmostEqual(moved["y"], 0.50, places=2)
        self.assertEqual(moved["label"], "Moved and re-keyed")
        self.assertEqual(again["markers"][1]["label"], "Pixels only")
        self.assertEqual(again["unkeyed_markers"], 0)

    def test_deleting_a_marker_never_renumbers_the_survivors(self):
        """Marker numbers are stable for the question's life, because a
        submitted answer names them. `_redraw_label_overlay` records the
        measured failure from the other side: renumbering 1/3/5 to 1/2/3 painted
        every badge against a different region than the key it was graded on. So
        the widget deletes marker 2 and sends {1, 3} - and 3 must still mean 3.
        """
        question = self._labelling_question(
            detections=[
                {"number": n, "label": "Point %d" % n,
                 "box_2d": [n * 100, n * 100, n * 100 + 80, n * 100 + 80]}
                for n in (1, 2, 3)
            ])

        item = {
            "regions": [{"n": 1, "x": 0.1, "y": 0.1, "w": 0.08, "h": 0.08},
                        {"n": 3, "x": 0.3, "y": 0.3, "w": 0.08, "h": 0.08}],
            "golden_labels": {"1": "Point 1", "3": "Point 3"},
            "annotation_count": 2,
        }
        self.assertEqual(question.apply_studio_annotation_item(item), [])

        again = question.studio_annotation_editor_payload()

        self.assertEqual([m["n"] for m in again["markers"]], [1, 3],
                         "the survivors keep their own numbers")
        self.assertEqual(again["markers"][1]["label"], "Point 3")
        self.assertAlmostEqual(again["markers"][1]["x"], 0.3, places=2)

    def test_an_unkeyed_box_is_refused_rather_than_half_written(self):
        """The refusal the widget mirrors client-side. It has to come back as a
        LIST from the model, because the widget renders it and stops - a truthy
        return that the widget read as success would show a green toast over a
        key that was never written."""
        question = self._labelling_question(
            detections=[{"number": 1, "label": "One",
                         "box_2d": [0, 0, 100, 100]}])
        before = question.image_ids.detections_json

        problems = question.apply_studio_annotation_item({
            "regions": [{"n": 1, "x": 0.1, "y": 0.1, "w": 0.1, "h": 0.1},
                        {"n": 2, "x": 0.5, "y": 0.5, "w": 0.1, "h": 0.1}],
            "golden_labels": {"1": "One", "2": "   "},
            "annotation_count": 2,
        })

        self.assertTrue(problems, "an unkeyed point is a mark nobody can earn")
        self.assertIn("2", " ".join(problems),
                      "the refusal has to name which marker, or the operator "
                      "hunts for it")
        self.assertEqual(question.image_ids.detections_json, before,
                         "and nothing may have been written in the meantime")


@tagged("-at_install", "post_install")
class TestASaveCannotShrinkThePaper(TestTheOdooAnnotationEditorOpensAndSaves):
    """A save may not delete markers the editor was never handed.

    THE FAILURE THIS PINS, measured on a production-shaped database before the
    guard existed: question 1417 carried 46 markers and 349 keyed labels, all
    of its geometry stored as `box_px`. `as_studio_annotation_item` can only
    express markers it can draw or key, so the editor opened with 9 - and a
    save it reported no problem with left the question at 9 markers and 9
    labels. Thirty-seven marks disappeared off a paper candidates had already
    sat, and `apply_studio_annotation_item` returned an EMPTY refusal list.

    The editor warned on screen, which is not the same as refusing: the warning
    is advisory, the operator is mid-correction, and the destructive path was
    one click with no confirmation and no server-side objection.
    """

    def _pixel_only_question(self, markers=6, keyed=2):
        """A question whose geometry the editor cannot draw.

        `box_px` is the DOM-capture lane's shape - PIXELS, not the 0-1000 grid -
        and the model deliberately refuses to hand those out as regions.
        """
        out = self._labelling_question()
        q = out[0] if isinstance(out, tuple) else out
        image = q.image_ids.filtered(lambda i: i.slot == "single")[:1]
        image.write({
            "detections_json": json.dumps([
                {"number": n, "label": "el %d" % n,
                 "box_px": [n, n, n + 10, n + 10]}
                for n in range(1, markers + 1)
            ]),
            # THE LABEL LIVES ON THE BOX, and only the first `keyed` of them
            # carry one. That is what `as_studio_annotation_item` reads to
            # build `golden_labels`, so a partial key here is what makes the
            # editor open with fewer markers than the question holds - the
            # exact shape of question 1417 on a production-like database, and
            # the only shape in which a save can delete something unseen.
            "label_boxes_json": json.dumps([
                dict({"number": n, "box_px": [n, n, n + 10, n + 10]},
                     **({"label": "el %d" % n} if n <= keyed else {}))
                for n in range(1, markers + 1)
            ]),
        })
        # KEYED IS DELIBERATELY FEWER THAN MARKERS. That is what reproduces
        # the real case: `as_studio_annotation_item` can only express a marker
        # it can DRAW or KEY, so a question with pixel-only geometry and a
        # partial key opens with a fraction of its markers - and the ones that
        # never arrive are the ones a save would silently delete. Keying all of
        # them would make every marker openable and the guard would correctly
        # not fire, which is what the first version of this fixture did.
        q.write({"subjective_rubric_json": json.dumps({
            "ideal_labels": {str(n): "el %d" % n for n in range(1, keyed + 1)},
        })})
        return q, image

    def test_a_reducing_save_is_refused_and_changes_nothing(self):
        q, image = self._pixel_only_question(markers=6)
        before = (image.label_boxes_json, image.detections_json,
                  q.subjective_rubric_json)

        refusals = q.apply_studio_annotation_item({
            "regions": [],
            "golden_labels": {"1": "el 1", "2": "el 2"},
            "annotation_count": 2,
        })

        self.assertTrue(refusals, "a save that halves the paper must refuse")
        self.assertIn("could not be opened in the editor", refusals[0])
        image.invalidate_recordset()
        q.invalidate_recordset()
        self.assertEqual(
            (image.label_boxes_json, image.detections_json,
             q.subjective_rubric_json),
            before,
            "a refusal must be a NO-OP - half-applying an answer key is worse "
            "than refusing it")

    def test_the_escape_hatch_is_explicit(self):
        """A caller that genuinely means to shorten the paper says so.

        The point of the guard is that the DEFAULT is safe, not that shrinking
        is impossible - and the editor never sends this flag, which is what
        stops it doing this by accident.
        """
        q, _image = self._pixel_only_question(markers=6, keyed=2)
        refusals = q.apply_studio_annotation_item({
            "regions": [],
            "golden_labels": {"1": "el 1", "2": "el 2"},
            "annotation_count": 2,
            "allow_marker_drop": True,
        })
        self.assertEqual(refusals, [], "an explicit reduction is allowed")

    def test_a_same_size_save_still_goes_through(self):
        """The guard must not block ordinary work.

        Correcting the wording of every label is the commonest edit there is,
        and it does not change the marker count.
        """
        q, _image = self._pixel_only_question(markers=4, keyed=4)
        refusals = q.apply_studio_annotation_item({
            "regions": [],
            "golden_labels": {str(n): "corrected %d" % n for n in range(1, 5)},
            "annotation_count": 4,
        })
        self.assertEqual(refusals, [], "relabelling all four must save")

    def test_growing_the_paper_is_never_blocked(self):
        q, _image = self._pixel_only_question(markers=3, keyed=3)
        refusals = q.apply_studio_annotation_item({
            "regions": [],
            "golden_labels": {str(n): "el %d" % n for n in range(1, 6)},
            "annotation_count": 5,
        })
        self.assertEqual(refusals, [], "adding markers is not a reduction")
