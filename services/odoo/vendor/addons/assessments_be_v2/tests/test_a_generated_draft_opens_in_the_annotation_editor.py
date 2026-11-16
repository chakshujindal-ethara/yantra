"""A labelling question can be turned back into a Form Studio item.

THE GAP (SNo 168). `studio_form._item_spec` translates a designer
`imageAnnotation` item into an `image_label` question, emitting geometry as
`box_2d` on Gemini's 0-1000 grid, y-first (studio_form.py:701). That direction
has always existed. THE INVERSE DID NOT.

The consequence is not a missing widget. The annotation editor is built, wired
and correct - verified live on a real plate: eight numbered boxes drawn over the
image, a Point 1..8 chip row, and a "Golden answers (for the LLM judge)" panel
reading "3 / 8 keyed". What was missing is the path INTO it: nothing turned a
question back into an item, so a GENERATED labelling draft could only be read,
never adjusted. An examiner could see that box 4 was in the wrong place and had
no way to move it.

WHAT THESE TESTS PIN, and why the shape of them matters:

  * THE ROUND TRIP IS EXACT. `test_a_studio_round_trip_keeps_the_boxes`
    composes BOTH directions - designer item -> question -> designer item - and
    compares the geometry it started with. A test that only checked the inverse
    arithmetic in isolation would pass while the two halves disagreed about
    which corner `box_2d` starts at, which is the one mistake that silently
    moves every box on every plate.

  * IT READS THE SOURCE A STUDIO QUESTION ACTUALLY HAS. Measured on etp_local,
    question 9602 (published from the Studio) carries `label_boxes_json` NULL
    and three `detections_json` entries. A translator that read only
    `label_boxes_json` would return nothing for exactly the questions this
    feature exists for - so `test_geometry_is_read_from_detections_too` drives
    that case on its own.

  * THE COUNT IS DERIVED, NEVER CARRIED. Seen live in the editor:
    `annotation_count` 3 beside 8 regions. Publish derives from `regions`
    (studio_form.py:641), so this must too, or the two disagree about the
    denominator a candidate is scored against.
"""
import json

from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAGeneratedDraftOpensInTheAnnotationEditor(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.Image = self.env["assessments.be.question.image"]
        self.Form = self.env["etp.studio.form"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Studio fixture %s" % uuid4().hex[:6]})

    # ── fixtures ──────────────────────────────────────────────────────

    def _labelling_question(self, *, detections=None, label_boxes=None,
                            solution=None, question_type="image_label",
                            with_image=True):
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
                "image_url": "https://example.test/plate.png",
            }
            if detections is not None:
                vals["detections_json"] = json.dumps(detections)
            if label_boxes is not None:
                vals["label_boxes_json"] = json.dumps(label_boxes)
            self.Image.create(vals)
        return question

    # ── the round trip, which is the whole point ──────────────────────

    def test_a_studio_round_trip_keeps_the_boxes(self):
        """THE HEADLINE, and the only test that can catch a flipped axis.

        Designer item -> published question -> designer item. Whatever the two
        transforms are, composing them must be the identity on geometry.
        """
        drawn = [
            {"n": 1, "x": 0.08, "y": 0.10, "w": 0.22, "h": 0.20},
            {"n": 2, "x": 0.42, "y": 0.38, "w": 0.20, "h": 0.18},
            {"n": 3, "x": 0.68, "y": 0.62, "w": 0.24, "h": 0.22},
        ]
        form = self.Form.create({
            "client_uid": "rt-%s" % uuid4().hex[:8],
            "title": "Round trip %s" % uuid4().hex[:4],
            "structure_json": [{
                "title": "Section",
                "items": [{
                    "id": "i1",
                    "kind": "imageAnnotation",
                    "title": "Mark each defect",
                    "help": "Name what is wrong at each marker.",
                    "media_url": "https://example.test/plate.png",
                    "regions": drawn,
                    "annotation_count": len(drawn),
                    "golden_labels": {
                        "1": "Style drift",
                        "2": "Edge artefact",
                        "3": "Colour banding",
                    },
                    "required": True,
                }],
            }],
        })

        result = form.publish_to_assessment()
        self.assertFalse(
            result.get("problems"),
            "the fixture form must publish cleanly; got %r"
            % (result.get("problems"),))

        question = self.env["assessments.be"].browse(
            result["assessment_id"]).question_ids.filtered(
                lambda q: q.question_type == "image_label")
        self.assertEqual(len(question), 1, "one labelling question")

        item = question.as_studio_annotation_item()
        self.assertTrue(item, "a published labelling question must come back")
        self.assertEqual(item["kind"], "imageAnnotation")

        back = {r["n"]: r for r in item["regions"]}
        self.assertEqual(sorted(back), [1, 2, 3])
        for original in drawn:
            got = back[original["n"]]
            for axis in ("x", "y", "w", "h"):
                self.assertAlmostEqual(
                    got[axis], original[axis], places=2,
                    msg="marker %d moved on %s: drew %.3f, got back %.3f"
                        % (original["n"], axis, original[axis], got[axis]))

    def test_the_round_trip_keeps_the_golden_answers(self):
        """The labels are the answer key. Losing them on a re-open would make
        the editor show 0 / N keyed on a fully keyed question, and an examiner
        would reasonably retype them."""
        form = self.Form.create({
            "client_uid": "rt-%s" % uuid4().hex[:8],
            "title": "Keys %s" % uuid4().hex[:4],
            "structure_json": [{
                "title": "Section",
                "items": [{
                    "id": "i1",
                    "kind": "imageAnnotation",
                    "title": "Mark each defect",
                    "media_url": "https://example.test/plate.png",
                    "regions": [{"n": 1, "x": 0.1, "y": 0.1,
                                 "w": 0.2, "h": 0.2}],
                    "annotation_count": 1,
                    "golden_labels": {"1": "Style drift - texture is wrong"},
                    "required": True,
                }],
            }],
        })
        result = form.publish_to_assessment()
        self.assertFalse(result.get("problems"))
        question = self.env["assessments.be"].browse(
            result["assessment_id"]).question_ids.filtered(
                lambda q: q.question_type == "image_label")

        item = question.as_studio_annotation_item()

        self.assertEqual(
            item["golden_labels"].get("1"),
            "Style drift - texture is wrong",
            "the golden answer must survive the round trip")

    # ── the source a Studio-published question actually has ───────────

    def test_geometry_is_read_from_detections_too(self):
        """THE CASE THE FEATURE EXISTS FOR.

        A question published from the Studio has `label_boxes_json` NULL and
        its geometry in `detections_json` - measured on etp_local question
        9602. Reading only the former would return nothing here.
        """
        question = self._labelling_question(
            detections=[
                {"number": 1, "label": "Style drift", "box_2d": [100, 80, 300, 300]},
                {"number": 2, "label": "Edge artefact", "box_2d": [380, 420, 560, 620]},
            ])

        item = question.as_studio_annotation_item()

        self.assertTrue(item, "detections alone must be enough")
        self.assertEqual(len(item["regions"]), 2)
        first = item["regions"][0]
        # [y0, x0, y1, x1] / 1000 -> y .1, x .08, h .2, w .22
        self.assertAlmostEqual(first["y"], 0.10, places=3)
        self.assertAlmostEqual(first["x"], 0.08, places=3)
        self.assertAlmostEqual(first["h"], 0.20, places=3)
        self.assertAlmostEqual(first["w"], 0.22, places=3)
        self.assertEqual(item["golden_labels"]["1"], "Style drift")

    def test_authored_geometry_wins_over_detections(self):
        """`label_boxes_json` is what the examiner drew; detections are what a
        model guessed. Merging both would draw two boxes for one marker."""
        question = self._labelling_question(
            label_boxes=[{"number": 1, "label": "Authored",
                          "box_2d": [0, 0, 500, 500]}],
            detections=[{"number": 1, "label": "Detected",
                         "box_2d": [900, 900, 1000, 1000]}])

        item = question.as_studio_annotation_item()

        self.assertEqual(len(item["regions"]), 1, "one marker, one box")
        self.assertAlmostEqual(item["regions"][0]["h"], 0.5, places=3,
                               msg="the authored box must be the one kept")

    def test_the_solution_map_supplies_the_labels(self):
        """A generated question keys its labels in `solution_json`, not on the
        boxes. Both shapes seen in the wild are read."""
        question = self._labelling_question(
            detections=[{"number": 1, "box_2d": [100, 100, 200, 200]}],
            solution={"ideal_labels": {"1": "From the solution map"}})

        item = question.as_studio_annotation_item()

        self.assertEqual(item["golden_labels"]["1"], "From the solution map")

    def test_a_bare_solution_map_is_read_as_well(self):
        question = self._labelling_question(
            detections=[{"number": 1, "box_2d": [100, 100, 200, 200]}],
            solution={"1": "Bare shape"})

        item = question.as_studio_annotation_item()

        self.assertEqual(item["golden_labels"]["1"], "Bare shape")

    # ── the count is derived, and the guards ──────────────────────────

    def test_the_annotation_count_is_derived_not_carried(self):
        """Seen live: `annotation_count` 3 beside 8 regions, reading
        "3 / 8 keyed". Publish derives from `regions`, so this must too."""
        question = self._labelling_question(
            detections=[{"number": n, "box_2d": [n * 10, n * 10,
                                                 n * 10 + 50, n * 10 + 50]}
                        for n in range(1, 9)])

        item = question.as_studio_annotation_item()

        self.assertEqual(item["annotation_count"], 8,
                         "the count must match the markers actually present")
        self.assertEqual(len(item["regions"]), 8)

    def test_a_marker_with_no_drawable_box_still_counts(self):
        """The DOM-capture lane stores `box_px` - PIXELS, not the 0-1000 grid -
        so its entries are not redrawable. The marker is still a point to
        label, which is the same reduction `bank_label_boxes` makes."""
        question = self._labelling_question(
            detections=[
                {"number": 1, "label": "Drawable", "box_2d": [0, 0, 100, 100]},
                {"number": 2, "label": "Pixels only",
                 "box_px": [10, 10, 90, 90]},
            ])

        item = question.as_studio_annotation_item()

        self.assertEqual(item["annotation_count"], 2,
                         "both markers exist and both need a label")
        self.assertEqual(len(item["regions"]), 1,
                         "only one of them can be drawn")
        self.assertEqual(item["golden_labels"]["2"], "Pixels only")

    def test_a_non_labelling_question_is_refused(self):
        """THE GUARD. The editor must not be offered for a question that has no
        markers - it would open on an empty plate."""
        question = self._labelling_question(
            question_type="subjective_rubric",
            detections=[{"number": 1, "box_2d": [0, 0, 100, 100]}])

        self.assertIsNone(question.as_studio_annotation_item())

    def test_a_labelling_question_with_no_image_is_refused(self):
        question = self._labelling_question(with_image=False)
        self.assertIsNone(question.as_studio_annotation_item())

    def test_a_labelling_question_with_no_markers_is_refused(self):
        """An image with no key yet. Nothing to edit, so nothing is offered -
        and returning an item here would render an editor with zero points."""
        question = self._labelling_question(detections=[])
        self.assertIsNone(question.as_studio_annotation_item())

    def test_malformed_geometry_never_raises(self):
        """A stored key is data, and data can be wrong. This runs on an admin
        screen; a TypeError here would 500 the whole detail route."""
        question = self._labelling_question(
            detections=[
                {"number": 1, "box_2d": "not a list"},
                {"number": 2, "box_2d": [1, 2]},
                {"number": 3, "box_2d": ["a", "b", "c", "d"]},
                {"number": None, "box_2d": [0, 0, 10, 10]},
                {"number": 4, "box_2d": [0, 0, 100, 100]},
            ])

        item = question.as_studio_annotation_item()

        self.assertTrue(item, "the one good marker must still come through")
        self.assertEqual([r["n"] for r in item["regions"]], [4])
        self.assertEqual(item["annotation_count"], 4,
                         "markers 1-3 are unrenderable but real")
