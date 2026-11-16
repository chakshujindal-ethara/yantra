"""Editing a labelling question in the annotation editor saves IN PLACE.

THE OTHER HALF OF SNo 168. `as_studio_annotation_item` opens a generated
labelling question in the annotation editor; `apply_studio_annotation_item` takes
the examiner's edits back. Without it the editor was read-only in practice.

THE DECISION THESE TESTS PIN: edit the question IN PLACE. No new Studio form, no
second assessment - a corrected question in a fresh record leaves the paper being
fixed exactly as broken as it was, with the good version attached to nothing
anybody sits. `test_the_edit_lands_on_the_same_question_row` is that assertion.

WHY THE SHAPE OF THE REST MATTERS:

  * THREE STORED VIEWS OF ONE BOX SET, WRITTEN TOGETHER. `detections_json` is
    what the overlay is drawn from, `subjective_rubric_json` is the grader's key
    and `solution_json` is the judge's golden answer. A save that updated one is
    how a key naming 5 labels ends up beside 3 drawn boxes - which grades a
    candidate against boxes they were never shown.

  * THE ROUND TRIP IS CLOSED. `test_a_round_trip_through_the_editor_is_lossless`
    reads a question out, writes the same item back, and reads it again.
    Composing the two directions must be the identity, or opening a question and
    pressing Save without touching anything would move every box - the one
    corruption nobody would look for.

  * THE BURNED-IN PLATE IS REDRAWN. The candidate is shown the annotated bitmap,
    not the client's boxes (`answer_layouts.dart` prefers `annotated_url`
    whenever the question has markers), so a moved box that only rewrote
    `detections_json` leaves the numeral painted in the OLD place and the key
    naming the new one.

  * A REFUSAL IS TOTAL. An unkeyed point is a mark no candidate can earn. Same
    refusal `_item_spec` makes on publish - and it must leave the stored key
    EXACTLY as it found it, because a half-applied answer key is how a 5-point
    question ends up scored out of 2.
"""
import base64
import io
import json

from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


def _png_bytes_b64():
    """A base64 PNG big enough for badges to be placed on."""
    return _png(600, 600)


def _png(width=400, height=300):
    """A real PNG, because the overlay redraw opens it with PIL."""
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (width, height), (200, 200, 200)).save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


@tagged("-at_install", "post_install")
class TestAnEditedMarkerLandsOnTheSameQuestion(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.Image = self.env["assessments.be.question.image"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Edit fixture %s" % uuid4().hex[:6]})

    def _question(self, *, detections=None, solution=None,
                  question_type="image_label", with_image=True):
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
                "image": _png(),
            }
            if detections is not None:
                vals["detections_json"] = json.dumps(detections)
            self.Image.create(vals)
        return question

    @staticmethod
    def _item(regions, labels, **extra):
        return dict({
            "kind": "imageAnnotation",
            "title": "Mark each defect",
            "help": "Name what is wrong at each marker.",
            "regions": regions,
            "annotation_count": len(regions),
            "golden_labels": labels,
            "required": True,
        }, **extra)

    def _stored(self, question):
        image = question.image_ids.filtered(lambda i: i.slot == "single")[:1]
        return json.loads(image.detections_json or "[]")

    # ── the decision: in place ────────────────────────────────────────

    def test_the_edit_lands_on_the_same_question_row(self):
        """THE PRODUCT DECISION, as an assertion.

        No new question, no new assessment, no new Studio form: the id the
        examiner opened is the id that now holds the corrected key. Anything
        else leaves the paper they were fixing untouched.
        """
        question = self._question(
            detections=[{"number": 1, "label": "Style drift",
                         "box_2d": [100, 100, 200, 200]}])
        before = self.Question.search_count([])
        forms_before = self.env["etp.studio.form"].search_count([])
        assessments_before = self.env["assessments.be"].search_count([])

        problems = question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.5, "y": 0.6, "w": 0.2, "h": 0.2}],
            {"1": "Moved and rekeyed"}))

        self.assertFalse(problems, "the edit must be accepted")
        self.assertEqual(self.Question.search_count([]), before,
                         "editing must not create a second question")
        self.assertEqual(self.env["etp.studio.form"].search_count([]),
                         forms_before,
                         "editing must not create a Studio form")
        self.assertEqual(self.env["assessments.be"].search_count([]),
                         assessments_before,
                         "editing must not create an assessment")
        self.assertEqual(
            json.loads(question.solution_json)["1"], "Moved and rekeyed",
            "the corrected key must be on the question that was opened")

    def test_a_round_trip_through_the_editor_is_lossless(self):
        """OPEN, SAVE UNTOUCHED, OPEN AGAIN - nothing may move.

        This is the case an examiner hits without meaning to: they open a
        question to look at it, press Save, and change nothing. If the two
        transforms disagree about which corner `box_2d` starts at, every box on
        every plate shifts and nobody would think to look for it.
        """
        question = self._question(
            detections=[
                {"number": 1, "label": "Style drift",
                 "box_2d": [100, 80, 300, 300]},
                {"number": 2, "label": "Edge artefact",
                 "box_2d": [380, 420, 560, 620]},
            ])

        first = question.as_studio_annotation_item()
        self.assertTrue(first)
        self.assertFalse(question.apply_studio_annotation_item(first))
        second = question.as_studio_annotation_item()

        self.assertEqual([r["n"] for r in second["regions"]],
                         [r["n"] for r in first["regions"]])
        for a, b in zip(first["regions"], second["regions"]):
            for axis in ("x", "y", "w", "h"):
                self.assertAlmostEqual(
                    a[axis], b[axis], places=2,
                    msg="marker %d moved on %s across a no-op save: %.3f -> "
                        "%.3f" % (a["n"], axis, a[axis], b[axis]))
        self.assertEqual(second["golden_labels"], first["golden_labels"])

    def test_a_moved_box_is_actually_moved(self):
        """The negative control's other half: a REAL edit must land.

        A round-trip test alone would pass against an implementation that
        ignored the payload and rewrote what was already stored.
        """
        question = self._question(
            detections=[{"number": 1, "label": "Style drift",
                         "box_2d": [0, 0, 100, 100]}])

        self.assertFalse(question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.40, "y": 0.50, "w": 0.10, "h": 0.20}],
            {"1": "Style drift"})))

        box = self._stored(question)[0]["box_2d"]
        self.assertEqual(box, [500, 400, 700, 500],
                         "y-first on the 0-1000 grid, matching _item_spec")

    # ── the three views agree ─────────────────────────────────────────

    def test_the_key_and_the_boxes_cannot_disagree(self):
        """`detections_json`, `subjective_rubric_json` and `solution_json` are
        parallel views of ONE box set. A save that updates a subset is how a key
        naming five labels ends up beside three drawn boxes."""
        question = self._question(
            detections=[{"number": n, "label": "old %d" % n,
                         "box_2d": [0, 0, 50, 50]} for n in (1, 2, 3)])

        self.assertFalse(question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.1, "y": 0.1, "w": 0.1, "h": 0.1},
             {"n": 2, "x": 0.3, "y": 0.3, "w": 0.1, "h": 0.1}],
            {"1": "First", "2": "Second"})))

        rubric = json.loads(question.subjective_rubric_json)
        solution = json.loads(question.solution_json)
        stored = self._stored(question)
        self.assertEqual(sorted(rubric["ideal_labels"]), ["1", "2"],
                         "the grader's key must name exactly the markers kept")
        self.assertEqual(rubric["ideal_labels"], solution,
                         "the grader's key and the judge's golden answer are "
                         "the same map")
        self.assertEqual([d["number"] for d in stored], [1, 2],
                         "the drawn markers must match the key")

    def test_the_authored_geometry_is_stored_so_a_reopen_sees_it(self):
        """`as_studio_annotation_item` reads `label_boxes_json` FIRST, so an
        examiner who moves a box has to see it there on re-open - otherwise the
        detections fallback serves the pre-edit geometry back to them."""
        question = self._question(
            detections=[{"number": 1, "label": "Style drift",
                         "box_2d": [0, 0, 100, 100]}])

        self.assertFalse(question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.25, "y": 0.35, "w": 0.10, "h": 0.10}],
            {"1": "Style drift"})))

        image = question.image_ids.filtered(lambda i: i.slot == "single")
        authored = json.loads(image.label_boxes_json or "[]")
        self.assertEqual(authored[0]["box_2d"], [350, 250, 450, 350])
        again = question.as_studio_annotation_item()
        self.assertAlmostEqual(again["regions"][0]["x"], 0.25, places=2)
        self.assertAlmostEqual(again["regions"][0]["y"], 0.35, places=2)

    def test_the_plate_the_candidate_sees_is_redrawn(self):
        """THE CANDIDATE SEES THE BURNED-IN OVERLAY, not the client's boxes.

        `answer_layouts.dart` swaps in `annotated_url` for any question with
        markers, so an edit that only rewrote the geometry would leave the
        numeral painted where the box USED to be while the key names where it
        now is. That is the "labels at the wrong positions" failure, arriving
        from the authoring side.
        """
        question = self._question(
            detections=[{"number": 1, "label": "Style drift",
                         "box_2d": [0, 0, 100, 100]}])
        image = question.image_ids.filtered(lambda i: i.slot == "single")
        image.annotated_image = _png(40, 40)
        stale = image.annotated_image

        self.assertFalse(question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.5, "y": 0.5, "w": 0.2, "h": 0.2}],
            {"1": "Style drift"})))

        self.assertTrue(image.annotated_image,
                        "the candidate must still have a marked plate")
        self.assertNotEqual(
            image.annotated_image, stale,
            "the overlay must be redrawn from the NEW geometry - a stale "
            "bitmap paints the badge where the box used to be")

    def test_the_marker_numbers_survive_the_redraw(self):
        """A SPARSE marker set must not be renumbered.

        `imaging.annotate_image` returns a key numbered 1..N BY POSITION, so
        writing its output back over `detections_json` would turn markers 1, 3,
        5 into 1, 2, 3 - and every golden answer would then point at a
        different place on the plate. The stored key stays authoritative; only
        the bitmap is replaced.
        """
        question = self._question(
            detections=[{"number": n, "label": "m%d" % n,
                         "box_2d": [0, 0, 50, 50]} for n in (1, 3, 5)])

        self.assertFalse(question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.1, "y": 0.1, "w": 0.1, "h": 0.1},
             {"n": 3, "x": 0.3, "y": 0.3, "w": 0.1, "h": 0.1},
             {"n": 5, "x": 0.5, "y": 0.5, "w": 0.1, "h": 0.1}],
            {"1": "One", "3": "Three", "5": "Five"})))

        self.assertEqual([d["number"] for d in self._stored(question)],
                         [1, 3, 5],
                         "the examiner's own numbering is the answer key")
        self.assertEqual(sorted(json.loads(question.solution_json)),
                         ["1", "3", "5"])

    # ── refusals, and that they change nothing ────────────────────────

    def test_an_unkeyed_point_is_refused(self):
        """The same refusal `_item_spec` makes on publish. An unkeyed point is
        a mark no candidate can earn."""
        question = self._question(
            detections=[{"number": 1, "label": "Style drift",
                         "box_2d": [0, 0, 100, 100]}])

        problems = question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.1, "y": 0.1, "w": 0.1, "h": 0.1},
             {"n": 2, "x": 0.3, "y": 0.3, "w": 0.1, "h": 0.1}],
            {"1": "Only the first"}))

        self.assertTrue(problems, "a keyless point must be refused")
        self.assertIn("2", problems[0], "the refusal must name the point")

    def test_a_refusal_leaves_the_stored_key_untouched(self):
        """A HALF-APPLIED ANSWER KEY is how a 5-point question ends up scored
        out of 2. The refusal has to leave the question exactly as it found
        it."""
        question = self._question(
            detections=[{"number": 1, "label": "Original",
                         "box_2d": [0, 0, 100, 100]}],
            solution={"ideal_labels": {"1": "Original"}})
        before_dets = self._stored(question)
        before_solution = question.solution_json
        before_name = question.name

        self.assertTrue(question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.1, "y": 0.1, "w": 0.1, "h": 0.1},
             {"n": 2, "x": 0.3, "y": 0.3, "w": 0.1, "h": 0.1}],
            {"1": "Rewritten"}, title="A new title")))

        self.assertEqual(self._stored(question), before_dets)
        self.assertEqual(question.solution_json, before_solution)
        self.assertEqual(question.name, before_name,
                         "not even the title may be written by a refused save")

    def test_an_item_with_no_markers_at_all_is_refused(self):
        question = self._question(
            detections=[{"number": 1, "label": "Style drift",
                         "box_2d": [0, 0, 100, 100]}])

        problems = question.apply_studio_annotation_item(
            self._item([], {}, annotation_count=0))

        self.assertTrue(problems)

    def test_a_non_labelling_question_is_refused(self):
        """THE GUARD. This writes `detection_mode` and a labelling key; running
        it on a rubric question would stamp a labelling answer key onto a
        question the grader reads a different key for."""
        question = self._question(
            question_type="subjective_rubric",
            detections=[{"number": 1, "box_2d": [0, 0, 100, 100]}])

        self.assertTrue(question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.1, "y": 0.1, "w": 0.1, "h": 0.1}],
            {"1": "Anything"})))

    def test_a_question_with_no_image_is_refused(self):
        question = self._question(with_image=False)

        self.assertTrue(question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.1, "y": 0.1, "w": 0.1, "h": 0.1}],
            {"1": "Anything"})))

    def test_malformed_geometry_never_raises(self):
        """This runs behind an admin screen; a TypeError here 500s the save and
        the examiner loses every box they drew."""
        question = self._question(
            detections=[{"number": 1, "label": "Style drift",
                         "box_2d": [0, 0, 100, 100]}])

        problems = question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": "nonsense", "y": None, "w": 0.1, "h": 0.1},
             {"n": 2, "x": 0.3, "y": 0.3, "w": 0.1, "h": 0.1}],
            {"1": "First", "2": "Second"}))

        self.assertFalse(problems, "a bad coordinate is not a refusal")
        stored = {d["number"]: d for d in self._stored(question)}
        self.assertEqual(sorted(stored), [1, 2],
                         "both markers are still points to label")
        self.assertNotIn("box_2d", stored[1],
                         "the unreadable one carries no geometry rather than "
                         "a box at the origin")

    def test_the_count_only_shape_keeps_its_markers(self):
        """A picture that carries its own baked-in markers has a COUNT and no
        geometry - what `bank_label_boxes` degrades to, and what the editor
        offers when `regions` is empty. Saving must keep the points."""
        question = self._question(
            detections=[{"number": 1, "label": "Baked in"}])

        problems = question.apply_studio_annotation_item(self._item(
            [], {"1": "First", "2": "Second", "3": "Third"},
            annotation_count=3))

        self.assertFalse(problems)
        self.assertEqual([d["number"] for d in self._stored(question)],
                         [1, 2, 3])
        self.assertEqual(sorted(json.loads(question.solution_json)),
                         ["1", "2", "3"])

    # ── what an edit must NOT disturb (found by adversarial review) ────

    def test_a_ui_question_stays_a_ui_question(self):
        """MOVING A BOX MUST NOT CHANGE WHAT KIND OF QUESTION IT IS.

        `detection_mode` decides whether the CANDIDATE may see the numbered
        overlay at all: `media_stream.annotated_is_worker_safe` serves it for
        'ui'/'dense' (boxes sit on controls, the candidate supplies the labels)
        and REFUSES it for the default 'object' (markers are drawn on the
        defects, so the overlay is the answer key - Finding L-2).

        An earlier version of this method wrote "object" unconditionally, copying
        `_item_spec` - correct there, because that lane CREATES a defect
        question. Here it flipped an existing UI question to defect mode, and the
        exam then stopped serving its overlay: the candidate got an unmarked
        screenshot above numbered inputs referring to regions they could not see.
        """
        from odoo.addons.assessments_be_v2.controllers import media_stream

        question = self._question(
            detections=[{"number": 1, "label": "Save button",
                         "box_2d": [100, 100, 200, 200]}])
        question.detection_mode = "ui"
        self.assertTrue(media_stream.annotated_is_worker_safe(question),
                        "a UI question serves its overlay to the candidate")

        self.assertFalse(question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.5, "y": 0.5, "w": 0.1, "h": 0.1}],
            {"1": "Save button"})))

        self.assertEqual(question.detection_mode, "ui",
                         "an authoring edit must not retype the question")
        self.assertTrue(
            media_stream.annotated_is_worker_safe(question),
            "the candidate must still be served the marked plate - flipping to "
            "object mode strips their only view of the markers")

    def test_the_rest_of_the_rubric_survives_a_label_edit(self):
        """`subjective_rubric_json` is a rubric OBJECT, not just the label map.

        Beside `ideal_labels` a generated question can carry `decoys`,
        `mandatory_elements`, `penalty_rules` and `scoring_guide`, and the grader
        reads them (`scoring._image_label_key`). Measured on etp_walk2: question
        306 carries a real `decoys` list. Writing a bare {"ideal_labels": ...}
        would delete every sibling key, so moving one box would quietly relax
        the whole rubric.
        """
        question = self._question(
            detections=[{"number": 1, "label": "Original",
                         "box_2d": [0, 0, 100, 100]}])
        question.subjective_rubric_json = json.dumps({
            "ideal_labels": {"1": "Original"},
            "decoys": ["The blue jeans - a generic item, not the defect"],
            "penalty_rules": ["Naming a decoy costs the mark"],
            "scoring_guide": "One mark per correctly named defect",
        })

        self.assertFalse(question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.2, "y": 0.2, "w": 0.1, "h": 0.1}],
            {"1": "Rewritten"})))

        rubric = json.loads(question.subjective_rubric_json)
        self.assertEqual(rubric["ideal_labels"], {"1": "Rewritten"},
                         "the labels ARE edited")
        self.assertEqual(
            rubric.get("decoys"),
            ["The blue jeans - a generic item, not the defect"],
            "the decoys must survive - dropping them relaxes the rubric")
        self.assertEqual(rubric.get("penalty_rules"),
                         ["Naming a decoy costs the mark"])
        self.assertEqual(rubric.get("scoring_guide"),
                         "One mark per correctly named defect")

    def test_the_behavioural_key_cannot_outlive_its_markers(self):
        """`behavioural_key_json` grades what each numbered box DOES, per marker
        (`scoring._image_label_behavioural_key`). An entry for a marker that no
        longer exists grades an answer against a region that is not on the plate.
        """
        question = self._question(
            detections=[{"number": n, "label": "m%d" % n,
                         "box_2d": [n * 10, n * 10, n * 10 + 40, n * 10 + 40]}
                        for n in (1, 2, 3)])
        image = question.image_ids.filtered(lambda i: i.slot == "single")
        image.behavioural_key_json = json.dumps([
            {"number": 1, "element": "Save", "functionality": "Commits"},
            {"number": 2, "element": "Cancel", "functionality": "Discards"},
            {"number": 3, "element": "Help", "functionality": "Opens docs"},
        ])

        # The examiner deletes marker 3.
        self.assertFalse(question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.1, "y": 0.1, "w": 0.1, "h": 0.1},
             {"n": 2, "x": 0.3, "y": 0.3, "w": 0.1, "h": 0.1}],
            {"1": "Save", "2": "Cancel"})))

        kept = json.loads(image.behavioural_key_json or "[]")
        self.assertEqual([b["number"] for b in kept], [1, 2],
                         "the deleted marker's entry must go with it")
        self.assertEqual(
            [b["element"] for b in kept], ["Save", "Cancel"],
            "a surviving marker keeps its own element - dropping it would "
            "remove a mark the candidate could earn")

    def test_switching_to_the_count_only_shape_clears_the_old_boxes(self):
        """`as_studio_annotation_item` reads `label_boxes_json` FIRST.

        So an examiner who deletes every box and switches to the count-only shape
        (markers baked into the picture, no coordinates) must not be served the
        boxes they just removed on re-open - which is what happened while this
        field was only written when geometry existed.
        """
        question = self._question(
            detections=[{"number": 1, "label": "Old box",
                         "box_2d": [0, 0, 100, 100]}])
        self.assertFalse(question.apply_studio_annotation_item(self._item(
            [{"n": 1, "x": 0.1, "y": 0.1, "w": 0.1, "h": 0.1}],
            {"1": "Old box"})))
        image = question.image_ids.filtered(lambda i: i.slot == "single")
        self.assertTrue(image.label_boxes_json, "geometry was stored")

        # Now the count-only shape: no regions, two baked-in markers.
        self.assertFalse(question.apply_studio_annotation_item(self._item(
            [], {"1": "First", "2": "Second"}, annotation_count=2)))

        # ASSERTED ON THE STORED GEOMETRY, not on the field being empty.
        #
        # The field is no longer emptied - it now carries the whole marker list,
        # including entries with no coordinates, because the READ prefers this
        # field and stops as soon as it yields anything, so a drawable-only
        # subset lost the pixel-only markers entirely. What must be true is the
        # product fact: none of the OLD boxes survive.
        stored = json.loads(image.label_boxes_json or "[]")
        self.assertFalse(
            [b for b in stored if b.get("box_2d")],
            "stale authored geometry must be gone, or the editor serves back "
            "boxes the examiner deleted while the exam draws the new set")
        again = question.as_studio_annotation_item()
        self.assertEqual(again["annotation_count"], 2)
        self.assertEqual(again["regions"], [],
                         "the count-only shape has no drawable geometry")

    def test_a_sparse_marker_set_keeps_its_numbers_on_the_plate(self):
        """THE CRITICAL ONE, and it was real: the burned-in badge must show the
        SAME number as the answer key.

        `imaging.annotate_from_pixels` numbers 1..N by position unless the item
        carries its own `number`. Verified by experiment before the fix: markers
        1, 3, 5 were painted 1, 2, 3, so every candidate read a badge that meant
        a different region than the key they were graded against.
        """
        from odoo.addons.assessments_be_v2.services import imaging

        dets = [
            {"number": 1, "box_2d": [100, 100, 200, 200], "label": "one"},
            {"number": 3, "box_2d": [300, 300, 400, 400], "label": "three"},
            {"number": 5, "box_2d": [500, 500, 600, 600], "label": "five"},
        ]
        _png, key = imaging.annotate_image(
            base64.b64decode(_png_bytes_b64()), dets)

        self.assertEqual([k["number"] for k in key], [1, 3, 5],
                         "the examiner's own numbering is the answer key, and "
                         "it is what must be painted on the plate")
        self.assertEqual([k["label"] for k in key], ["one", "three", "five"])

    def test_an_unnumbered_detection_is_still_numbered_by_position(self):
        """THE NEGATIVE HALF. The detection lanes (Gemini, the DOM capture) hand
        over an UNNUMBERED list, and this function assigning 1..N in draw order
        IS the key for them. Honouring an explicit number must not break that.
        """
        from odoo.addons.assessments_be_v2.services import imaging

        dets = [
            {"box_2d": [100, 100, 200, 200], "label": "first"},
            {"box_2d": [300, 300, 400, 400], "label": "second"},
        ]
        _png, key = imaging.annotate_image(
            base64.b64decode(_png_bytes_b64()), dets)

        self.assertEqual([k["number"] for k in key], [1, 2])

    def test_no_lane_renumbers_a_sparse_key_by_draw_position(self):
        """THE BUG CLASS, swept - not just the one instance that was reported.

        After fixing the overlay redraw, `rg` found three more places that hand a
        marker list to `imaging.annotate_image` and write the returned key back:
        `prompt._apply_authored_label_key`, `prompt._dense_preview_dets` and
        `question_image._dense_detections`. Every one of them FILTERS the stored
        geometry - dropping entries without a 4-element `box_2d` - so every one
        can produce a sparse list, and any that dropped the number would renumber
        it 1..N by draw position.

        That matters because `behavioural_key_json` is the parallel view of the
        same numbered list and keeps the ORIGINAL numbers, and the grader reads it
        per marker (`scoring._image_label_behavioural_key`). A disagreement means
        marker 3's action is graded against the box authored as marker 4 - and
        `_apply_authored_label_key`'s own comment says any disagreement it writes
        "is permanent", because it also sets `detections_json`, which makes the
        detect cron skip the image for ever.

        THE DETECTION LANE IS DELIBERATELY NOT INCLUDED: Vertex and the DOM
        capture hand over an UNNUMBERED list, so there 1..N by position IS the
        key. `test_an_unnumbered_detection_is_still_numbered_by_position` pins
        that half.
        """
        from odoo.addons.assessments_be_v2.services import imaging

        # An authored key whose marker 3 has unrenderable geometry: 1, 2, 4 draw.
        authored = [
            {"number": 1, "box_2d": [100, 100, 200, 200], "label": "one"},
            {"number": 2, "box_2d": [250, 250, 350, 350], "label": "two"},
            {"number": 3, "box_2d": "unrenderable", "label": "three"},
            {"number": 4, "box_2d": [400, 400, 500, 500], "label": "four"},
        ]
        drawable = [g for g in authored
                    if isinstance(g.get("box_2d"), list)
                    and len(g["box_2d"]) == 4]
        self.assertEqual([g["number"] for g in drawable], [1, 2, 4],
                         "the fixture is the sparse case")

        _png, key = imaging.annotate_image(
            base64.b64decode(_png_bytes_b64()),
            [{"number": g.get("number"), "box_2d": g["box_2d"],
              "label": g.get("label", ""), "description": ""}
             for g in drawable])

        self.assertEqual(
            [k["number"] for k in key], [1, 2, 4],
            "a sparse authored key must keep its own numbers - renumbering to "
            "1, 2, 3 puts marker 3's badge on the box authored as marker 4, and "
            "the behavioural key still says 4")

    def test_a_marker_the_client_cannot_draw_survives_a_save(self):
        """A MARK MUST NOT BE DELETED BY PRESSING SAVE ON AN UNCHANGED QUESTION.

        `as_studio_annotation_item` deliberately reports markers the client cannot
        draw: the DOM-capture lane stores `box_px` - PIXELS, not the 0-1000 grid -
        so those come back inside `annotation_count` and `golden_labels` but NOT
        inside `regions`, the same reduction `serializers.bank_label_boxes` makes
        (pixel coordinates handed to the client paint degenerate boxes in the
        corner of the image).

        Two bugs conspired here and BOTH had to be fixed, which is why this test
        drives the full round trip rather than either half:

          * the save derived its marker set from `regions` alone, so the
            pixel-only marker was never written; and
          * `label_boxes_json` was stored as the DRAWABLE SUBSET, and the read
            prefers that field and stops as soon as it yields anything - so even
            after the write was correct, the re-open still lost the marker.

        Measured before the fix: a question with marker 1 drawable and marker 2
        pixel-only opened as 2 markers with both keyed, and a save that changed
        NOTHING left it at 1. A mark removed from the paper, with its golden
        answer, by an examiner who touched nothing.
        """
        question = self._question(
            detections=[
                {"number": 1, "label": "Drawable", "box_2d": [0, 0, 100, 100]},
                {"number": 2, "label": "Pixels only",
                 "box_px": [10, 10, 90, 90]},
            ])

        opened = question.as_studio_annotation_item()
        self.assertEqual(opened["annotation_count"], 2)
        self.assertEqual([r["n"] for r in opened["regions"]], [1],
                         "only one of the two is drawable - that is the fixture")
        self.assertEqual(sorted(opened["golden_labels"]), ["1", "2"])

        self.assertFalse(question.apply_studio_annotation_item(opened),
                         "a no-op save must be accepted")

        back = question.as_studio_annotation_item()
        self.assertEqual(
            back["annotation_count"], 2,
            "the undrawable marker is still a point the candidate must label")
        self.assertEqual(
            back["golden_labels"], opened["golden_labels"],
            "its golden answer is a mark somebody can earn - saving must not "
            "silently delete it")
        self.assertEqual([r["n"] for r in back["regions"]], [1],
                         "and it must not acquire fabricated geometry")

