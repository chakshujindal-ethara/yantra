"""Image Labelling Count is a HARD CAP, and every lane has to obey the SAME one.

`assessments.be.prompt.image_label_count` (default `DEFAULT_IMAGE_LABEL_COUNT`)
is the maximum number of numbered boxes one `image_label` question may carry.

WHY IT NEEDS ITS OWN REGRESSION FILE. The cap is enforced at roughly nine call
sites across four files, because the box set is SERIALISED THREE TIMES and each
serialisation has a different consumer:

    label_boxes_json      the geometry of record - what gets drawn
    behavioural_key_json  what the reviewer reads and what the grader marks
    answer_key/ideal_labels  what the candidate portal counts to decide how
                          many "Label N" inputs to render

Truncating them independently is not a cosmetic mismatch: a key listing 30
entries beside 10 drawn boxes GRADES A CANDIDATE AGAINST BOXES THEY WERE NEVER
SHOWN, and the denominator is the question's own box count (see
`test_image_label_per_box`), so the mark is divided by 30 for an image that had
10 things on it. Hence almost every case asserts CONSISTENCY between the three
fields rather than just a length.

THE FOUR LANES, one class each:

  * Generation (`services/vertex._image_label_draft_fields`) - the model is told
    "up to N" and routinely ignores it. Both shapes: the dense box lane
    (`boxes[]` geometry) and the map-only lane (an `ideal_labels` dict with no
    geometry, where nothing downstream can renumber, so the cut has to bite at
    build time).
  * The defect/marker lane (same function, `defects[]` + `base_prompt`) -
    truncating the plan without re-keying the rubric leaves markers 11..30
    described in a rubric an admin reads. `_trim_marker_key` drops those and MUST
    keep non-numeric keys (`decoys`, prose) that were never markers.
  * Form Studio publish (`models/studio_form`) - the lane this file was written
    for, and the one authoring path with no ceiling at all. It was also
    PERMANENT: publish writes a non-empty `detections_json`, and that makes the
    detect cron skip the image, so the one place that would have applied a cap
    never ran.
  * The storage backstop (`models/question_image.create/write`) - nine call sites
    is nine chances to miss one, so the model trims on the way into the column.
    It truncates rather than raises on purpose: a ValidationError would fire on
    any future write that merely TOUCHES a row written before the guard existed.

NEVER ZERO. `image_label_count` is read off Many2ones that can be unset, so a
caller gets 0 or None or False routinely, and clamping to that renders a
labelling question with NO inputs. Every resolver (`vertex._label_box_cap`,
`labelling._resolve_cap`, and the two model helpers) maps anything that is not a
positive integer to `DEFAULT_IMAGE_LABEL_COUNT`. The model constraint refuses to
STORE a 0; the resolvers cover the rows and Many2ones it cannot reach.

EVERY EXPECTED COUNT IS DERIVED FROM `DEFAULT_IMAGE_LABEL_COUNT`, never a literal
20, so retuning the module default does not turn these tests red.
"""
import json
from uuid import uuid4

from odoo.exceptions import ValidationError
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.constants import DEFAULT_IMAGE_LABEL_COUNT
from odoo.addons.assessments_be_v2.services import labelling as labelling_svc
from odoo.addons.assessments_be_v2.services import vertex as vertex_svc

# Deliberately far above the default so a test that accidentally asserts the
# default instead of the cap under test still fails.
OVER_CAP = 30
TIGHT_CAP = 10


def _box(n):
    """One well-formed authored box in the generator's own output shape."""
    return {
        "box_2d": [n, n, n + 10, n + 10],
        "element": "Control %d" % n,
        "functionality": "Does thing %d" % n,
        "number": n,
    }


def _ideal_map(count):
    """An `ideal_labels` answer key as the model authors it: a {str: str} map."""
    return {str(n): "Does thing %d" % n for n in range(1, count + 1)}


def _numbers_in_ideal_text(text):
    """The box numbers a rendered `ideal_labels` string offers.

    `_image_label_draft_fields` flattens the map/box list into "N. text" lines
    because that string is what the portal counts to decide how many "Label N"
    inputs to draw. Reading the numbers back out is how a test asserts the
    CANDIDATE-FACING count, rather than the count of some internal list.
    """
    out = []
    for line in str(text or "").splitlines():
        head = line.split(".", 1)[0].strip()
        if head.isdigit():
            out.append(int(head))
    return out


@tagged("-at_install", "post_install")
class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Generator = self.env["assessments.be.prompt"]
        self.Draft = self.env["assessments.be.prompt.question"]
        self.Question = self.env["assessments.be.question"]
        self.Image = self.env["assessments.be.question.image"]

    def _generator(self, cap=None):
        vals = {"name": "Labelling cap %s" % uuid4().hex[:6]}
        if cap is not None:
            vals["image_label_count"] = cap
        return self.Generator.create(vals)

    def _label_question(self, generator=None):
        return self.Question.create({
            "name": "Label the controls %s" % uuid4().hex[:6],
            "question_type": "image_label",
            "prompt": "Describe what each numbered control does.",
            "generator_id": generator.id if generator else False,
        })


# ----------------------------------------------------------------------
# 1 + 2. Generation
# ----------------------------------------------------------------------
@tagged("-at_install", "post_install")
class TestGenerationTruncatesEveryLabelField(_Base):
    """`_image_label_draft_fields` is where an over-eager model is cut down.

    The model is asked for "up to N" boxes and hands back whatever it feels
    like. This is the last point at which the three serialisations can still be
    made to agree, so the assertions here are about AGREEMENT, not just length.
    """

    def _draft_fields(self, cap=TIGHT_CAP, boxes=OVER_CAP, source_url=None):
        specs = {
            "images": [{"slot": "single", "label": "Screenshot",
                        "prompt": "A settings screen."}],
            "boxes": [_box(n) for n in range(1, boxes + 1)],
            "answer_key": {"ideal_labels": _ideal_map(boxes),
                           "scoring_guide": "one mark per box"},
        }
        if source_url:
            specs["source_url"] = source_url
        return vertex_svc._image_label_draft_fields(specs, cap=cap)

    def test_thirty_authored_boxes_become_exactly_the_cap(self):
        vals = self._draft_fields()

        geometry = json.loads(vals["label_boxes_json"])
        self.assertEqual(
            len(geometry), TIGHT_CAP,
            "a cap of %d must yield %d boxes however many the model authored"
            % (TIGHT_CAP, TIGHT_CAP))
        self.assertEqual(
            [g["number"] for g in geometry], list(range(1, TIGHT_CAP + 1)),
            "the kept boxes are renumbered 1..N contiguously - a gap would "
            "leave the overlay drawing a box the key cannot name")

    def test_all_three_serialisations_describe_the_same_boxes(self):
        """The one that matters. Three consumers, one box set.

        If these ever disagree the grader marks against boxes that were never
        drawn on the image the candidate answered.
        """
        vals = self._draft_fields()

        geometry = [g["number"] for g in json.loads(vals["label_boxes_json"])]
        behavioural = [b["number"]
                       for b in json.loads(vals["behavioural_key_json"])]
        rubric = json.loads(vals["rubric_json"])
        offered = _numbers_in_ideal_text(rubric["ideal_labels"])

        self.assertEqual(geometry, behavioural)
        self.assertEqual(geometry, offered)
        self.assertEqual(
            len(offered), TIGHT_CAP,
            "the candidate is offered exactly %d places to type; a key listing "
            "%d entries beside %d boxes grades them on boxes they never saw"
            % (TIGHT_CAP, OVER_CAP, TIGHT_CAP))

    def test_the_key_never_names_a_box_past_the_cap(self):
        """Stated the other way round, because "the same 10" is only half of
        it: box 11 must be absent, not merely outnumbered."""
        vals = self._draft_fields()

        rubric = json.loads(vals["rubric_json"])
        offered = _numbers_in_ideal_text(rubric["ideal_labels"])
        self.assertEqual(max(offered), TIGHT_CAP)
        for junk in ("Does thing %d" % (TIGHT_CAP + 1),
                     "Does thing %d" % OVER_CAP):
            self.assertNotIn(junk, rubric["ideal_labels"])
            self.assertNotIn(junk, vals["behavioural_key_json"])
            self.assertNotIn(junk, vals["label_boxes_json"])

    def test_the_cap_is_frozen_into_the_capture_plan(self):
        """The live-DOM lane, where the boxes are drawn LATER.

        The capture runs at render and again on the bank image after approval,
        long after the caller that had the generator in hand is gone. So the
        ceiling travels with the capture plan the same way the viewport does,
        or the capture re-derives it from nothing and draws the default 20 on
        a question the operator capped at 10.
        """
        vals = self._draft_fields(source_url="https://example.com/app")

        cfg = json.loads(vals["capture_config_json"])
        self.assertEqual(cfg["max_boxes"], TIGHT_CAP)
        self.assertEqual(vals["source_url"], "https://example.com/app")

    def test_a_compliant_model_is_left_alone(self):
        """The cap truncates; it does not pad, renumber away, or otherwise
        touch a generator that respected the contract."""
        vals = self._draft_fields(cap=TIGHT_CAP, boxes=TIGHT_CAP - 3)

        geometry = json.loads(vals["label_boxes_json"])
        self.assertEqual(len(geometry), TIGHT_CAP - 3)
        self.assertEqual(
            len(_numbers_in_ideal_text(
                json.loads(vals["rubric_json"])["ideal_labels"])),
            TIGHT_CAP - 3)

    def test_the_map_only_lane_truncates_too(self):
        """An `ideal_labels` MAP with no `boxes[]` geometry.

        Nothing downstream can renumber this shape - the portal counts these
        entries directly to decide how many inputs to render - so it is the one
        place a 30-box question would survive if the cut did not happen here.
        """
        specs = {"answer_key": {"ideal_labels": _ideal_map(OVER_CAP)}}

        vals = vertex_svc._image_label_draft_fields(specs, cap=TIGHT_CAP)

        rubric = json.loads(vals["rubric_json"])
        offered = _numbers_in_ideal_text(rubric["ideal_labels"])
        self.assertEqual(offered, list(range(1, TIGHT_CAP + 1)))
        self.assertNotIn(
            "label_boxes_json", vals,
            "no geometry was authored, so none is invented - only the key is "
            "cut")

    def test_the_map_only_lane_keeps_the_lowest_numbers(self):
        """Ordered numerically before the cut, so a map arriving as
        1,10,11,...,2 is not cut into an arbitrary subset."""
        ideal = _ideal_map(OVER_CAP)
        shuffled = {k: ideal[k] for k in sorted(ideal, reverse=True)}
        specs = {"answer_key": {"ideal_labels": shuffled}}

        vals = vertex_svc._image_label_draft_fields(specs, cap=TIGHT_CAP)

        offered = _numbers_in_ideal_text(
            json.loads(vals["rubric_json"])["ideal_labels"])
        self.assertEqual(offered, list(range(1, TIGHT_CAP + 1)))


# ----------------------------------------------------------------------
# 3. The defect / marker lane
# ----------------------------------------------------------------------
@tagged("-at_install", "post_install")
class TestDefectLaneTrimsPlanAndRubricTogether(_Base):
    """`defects[]` and its marker-keyed rubric are cut as one unit.

    `_plant_defects_on_render` re-keys the rubric again after the render, so a
    superset would eventually be tolerated - but only at render. Between
    draft-build and render an admin READS that rubric in the reviewer form, and
    a rubric listing markers 1..30 beside a 10-defect plan reads as a
    generation bug rather than as a cap doing its job.
    """

    def _defect_specs(self, defects=OVER_CAP):
        # The shape the q7r generation contract asks the model for: a marker-
        # keyed `ideal_labels` map alongside `decoys` and `scoring_guide`.
        # Non-numeric keys are never markers - `decoys` in particular is the
        # list of things that are deliberately NOT defects, so dropping it with
        # the over-cap markers would quietly change what the judge is told.
        # One is nested INSIDE the marker map to pin that the trim filters by
        # key shape rather than just slicing the dict.
        answer_key = {
            "ideal_labels": dict(_ideal_map(defects),
                                 scoring_guide="one mark per marker found"),
            "decoys": ["a correctly rendered button"],
        }
        return {
            "base_prompt": "A dashboard screenshot.",
            "defects": [
                {"marker": n, "kind": "visual", "method": "edit",
                 "edit_instruction": "garble the label on widget %d" % n,
                 "anchor": "widget %d" % n, "flaw": "garbled text"}
                for n in range(1, defects + 1)
            ],
            "answer_key": answer_key,
        }

    def test_the_defect_plan_is_cut_to_the_cap(self):
        vals = vertex_svc._image_label_draft_fields(
            self._defect_specs(), cap=TIGHT_CAP)

        plan = json.loads(vals["defect_plan_json"])
        self.assertEqual(len(plan["defects"]), TIGHT_CAP)
        self.assertEqual([d["marker"] for d in plan["defects"]],
                         list(range(1, TIGHT_CAP + 1)))

    def test_the_marker_rubric_is_cut_with_it(self):
        vals = vertex_svc._image_label_draft_fields(
            self._defect_specs(), cap=TIGHT_CAP)

        rubric = json.loads(vals["rubric_json"])
        markers = sorted(int(k) for k in rubric["ideal_labels"]
                         if str(k).isdigit())
        self.assertEqual(
            markers, list(range(1, TIGHT_CAP + 1)),
            "the rubric describes exactly the markers that will be stamped")

    def test_non_marker_keys_survive_the_trim(self):
        """`decoys` and prose keys are not markers and are never dropped.

        Losing `decoys` would be a silent scoring change, not a cosmetic one:
        it is the list of things the candidate must NOT mark, and a wrong mark
        costs more than a miss.
        """
        vals = vertex_svc._image_label_draft_fields(
            self._defect_specs(), cap=TIGHT_CAP)

        rubric = json.loads(vals["rubric_json"])
        self.assertEqual(rubric["decoys"], ["a correctly rendered button"])
        self.assertEqual(rubric["ideal_labels"]["scoring_guide"],
                         "one mark per marker found")

    def test_trim_marker_key_uses_position_when_the_plan_is_unnumbered(self):
        """A plan whose defects carry no `marker` still has an implied
        numbering: position. Dropping every numeric key because the plan did
        not spell them out would delete the whole rubric."""
        kept = [{"flaw": "a"}, {"flaw": "b"}, {"flaw": "c"}]

        out = vertex_svc._trim_marker_key(
            {"ideal_labels": _ideal_map(OVER_CAP)}, kept)

        self.assertEqual(
            sorted(int(k) for k in out["ideal_labels"]), [1, 2, 3])


# ----------------------------------------------------------------------
# 4. Form Studio publish - the lane this file was written for
# ----------------------------------------------------------------------
@tagged("-at_install", "post_install")
class TestFormStudioPublishRespectsTheCap(_Base):
    """A published form cannot smuggle 30 boxes past the cap.

    This was the one authoring lane with no ceiling at all. It is also the
    lane where an over-cap question is PERMANENT: `publish_to_assessment`
    writes a non-empty `detections_json`, and a non-empty `detections_json`
    makes the detect cron skip the image, so the detection-time cap - the only
    other place that would have trimmed it - never runs.

    The cut is made once, on `numbers`, before the labels, the detections and
    the `ideal_labels` key are derived from it, so all three agree by
    construction rather than by three separate truncations that have to be
    kept in step.
    """

    # 1x1 PNG. The publish path resolves `/web/content/<id>` against
    # `ir.attachment` directly, so the fixture never opens a socket - a form
    # with an http:// media_url would sit in `requests.get` for its 20s
    # timeout per image before falling back to a link.
    _PNG_B64 = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8"
                "z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

    def setUp(self):
        super().setUp()
        self.Form = self.env["etp.studio.form"]
        self.attachment = self.env["ir.attachment"].create({
            "name": "form-media-%s.png" % uuid4().hex[:6],
            "datas": self._PNG_B64,
        })
        self.media_url = "/web/content/%d" % self.attachment.id

    def _form(self, item):
        return self.Form.create({
            "client_uid": "form-%s" % uuid4().hex[:6],
            "title": "Annotation form %s" % uuid4().hex[:6],
            "structure_json": [{"title": "Labelling", "items": [item]}],
        })

    def _annotation_item(self, regions=None, annotation_count=None,
                         labels=OVER_CAP):
        item = {
            "kind": "imageAnnotation",
            "id": "item-%s" % uuid4().hex[:6],
            "title": "Label every control",
            "media_url": self.media_url,
            "golden_labels": {str(n): "Does thing %d" % n
                              for n in range(1, labels + 1)},
        }
        if regions is not None:
            item["regions"] = regions
        if annotation_count is not None:
            item["annotation_count"] = annotation_count
        return item

    @staticmethod
    def _regions(count):
        """Markers as the designer drew them: fractional 0-1 coordinates."""
        return [{"n": n, "x": 0.01 * n, "y": 0.01 * n, "w": 0.05, "h": 0.05}
                for n in range(1, count + 1)]

    def _publish(self, item):
        form = self._form(item)
        result = form.publish_to_assessment()
        self.assertNotIn(
            "problems", result,
            "the fixture form must publish; %r" % (result.get("problems"),))
        question = self.env["assessments.be.question"].search(
            [("generator_id", "=", result["generator_id"])])
        self.assertEqual(len(question), 1)
        return result, question

    def test_thirty_drawn_regions_publish_as_the_capped_count(self):
        _result, question = self._publish(
            self._annotation_item(regions=self._regions(OVER_CAP)))

        image = question.image_ids.filtered(lambda i: i.slot == "single")
        detections = json.loads(image.detections_json)
        self.assertEqual(
            len(detections), DEFAULT_IMAGE_LABEL_COUNT,
            "a form carrying %d regions must publish %d boxes - and it is "
            "permanent, because a non-empty detections_json makes the detect "
            "cron skip this image" % (OVER_CAP, DEFAULT_IMAGE_LABEL_COUNT))
        self.assertEqual(
            [d["number"] for d in detections],
            list(range(1, DEFAULT_IMAGE_LABEL_COUNT + 1)))

    def test_the_published_answer_key_agrees_with_the_published_boxes(self):
        """Both keys, against the boxes. `subjective_rubric_json` is what the
        judge grades on and `solution_json` is the golden answer of record; a
        marker in either that has no box on the image is a mark the candidate
        cannot earn."""
        _result, question = self._publish(
            self._annotation_item(regions=self._regions(OVER_CAP)))

        image = question.image_ids.filtered(lambda i: i.slot == "single")
        drawn = {d["number"] for d in json.loads(image.detections_json)}
        rubric = json.loads(question.subjective_rubric_json)["ideal_labels"]
        solution = json.loads(question.solution_json)

        self.assertEqual({int(k) for k in rubric}, drawn)
        self.assertEqual({int(k) for k in solution}, drawn)
        self.assertEqual(len(drawn), DEFAULT_IMAGE_LABEL_COUNT)
        self.assertNotIn(str(DEFAULT_IMAGE_LABEL_COUNT + 1), rubric)
        self.assertNotIn(str(OVER_CAP), rubric)

    def test_an_annotation_count_with_no_regions_is_capped_too(self):
        """A designer who typed a count instead of drawing markers takes the
        other branch of the same expression, so it needs its own case."""
        _result, question = self._publish(
            self._annotation_item(annotation_count=OVER_CAP))

        image = question.image_ids.filtered(lambda i: i.slot == "single")
        self.assertEqual(len(json.loads(image.detections_json)),
                         DEFAULT_IMAGE_LABEL_COUNT)
        self.assertEqual(
            len(json.loads(question.subjective_rubric_json)["ideal_labels"]),
            DEFAULT_IMAGE_LABEL_COUNT)

    def test_publish_pins_the_count_on_the_generator_it_mints(self):
        """The specs are capped before the generator exists, so publish pins
        the same number onto it explicitly. If it were left to the field
        default the two could drift apart the day the default changes, and a
        later re-detect would draw a different number of boxes than the form
        published."""
        result, question = self._publish(
            self._annotation_item(regions=self._regions(OVER_CAP)))

        generator = self.env["assessments.be.prompt"].browse(
            result["generator_id"])
        self.assertEqual(generator.image_label_count,
                         DEFAULT_IMAGE_LABEL_COUNT)
        self.assertEqual(
            question.image_ids[:1]._label_box_cap(),
            DEFAULT_IMAGE_LABEL_COUNT,
            "the published question resolves the same ceiling it was built "
            "to, so a re-detect cannot lift it")

    def test_an_under_cap_form_publishes_every_region(self):
        """The cap is a ceiling, not a target: a 4-marker form stays a
        4-marker question."""
        _result, question = self._publish(
            self._annotation_item(regions=self._regions(4), labels=4))

        image = question.image_ids.filtered(lambda i: i.slot == "single")
        self.assertEqual(len(json.loads(image.detections_json)), 4)
        self.assertEqual(
            len(json.loads(question.subjective_rubric_json)["ideal_labels"]),
            4)


# ----------------------------------------------------------------------
# 5. The storage backstop
# ----------------------------------------------------------------------
@tagged("-at_install", "post_install")
class TestStorageBackstopCapsOnTheWayIn(_Base):
    """`question.image` trims over-cap box lists in `create` AND in `write`.

    Nine call sites is nine chances to miss one, and a lane that misses it
    writes a permanently inconsistent row. This guard is the last one before
    the column, so it is the only one that cannot be bypassed by a new caller.
    """

    def _image(self, question, **vals):
        return self.Image.create(dict(
            {"question_id": question.id, "label": "Screenshot",
             "slot": "single"}, **vals))

    @staticmethod
    def _dets(count):
        return json.dumps([{"number": n, "label": "Control %d" % n,
                            "description": "Does thing %d" % n}
                           for n in range(1, count + 1)])

    @staticmethod
    def _geometry(count):
        return json.dumps([{"number": n, "box_2d": [n, n, n + 10, n + 10],
                            "label": "Control %d" % n,
                            "description": "Does thing %d" % n}
                           for n in range(1, count + 1)])

    @staticmethod
    def _key(count):
        return json.dumps([{"number": n, "element": "Control %d" % n,
                            "functionality": "Does thing %d" % n}
                           for n in range(1, count + 1)])

    def test_create_truncates_detections(self):
        """Form Studio's publish is exactly this shape: it hands
        `detections_json` straight to `create`, so a guard that only covered
        `write` would have missed the lane it exists for."""
        question = self._label_question(self._generator())

        image = self._image(question, detections_json=self._dets(OVER_CAP))

        self.assertEqual(
            len(json.loads(image.detections_json)), DEFAULT_IMAGE_LABEL_COUNT)

    def test_create_truncates_all_three_fields_together(self):
        question = self._label_question(self._generator())

        image = self._image(
            question,
            detections_json=self._dets(OVER_CAP),
            label_boxes_json=self._geometry(OVER_CAP),
            behavioural_key_json=self._key(OVER_CAP))

        for fname in self.Image._LABEL_BOX_FIELDS:
            self.assertEqual(
                len(json.loads(image[fname])), DEFAULT_IMAGE_LABEL_COUNT,
                "%s was not cut with the others - that is how a key ends up "
                "describing a box that was never drawn" % fname)

    def test_write_truncates_all_three_fields_together(self):
        """A later write is not a safe write: the detect cron, an admin saving
        the form and the approve-time key application all arrive this way."""
        question = self._label_question(self._generator())
        image = self._image(question)

        image.write({
            "detections_json": self._dets(OVER_CAP),
            "label_boxes_json": self._geometry(OVER_CAP),
            "behavioural_key_json": self._key(OVER_CAP),
        })

        for fname in self.Image._LABEL_BOX_FIELDS:
            self.assertEqual(
                len(json.loads(image[fname])), DEFAULT_IMAGE_LABEL_COUNT,
                "%s survived a write over the cap" % fname)

    def test_the_cap_comes_from_the_questions_generator(self):
        """Not from the module default. An operator who sets 5 gets 5.

        The generator is checked FIRST precisely so that lowering Image
        Labelling Count and re-detecting applies the new ceiling to an old
        question.
        """
        question = self._label_question(self._generator(cap=5))

        image = self._image(
            question,
            detections_json=self._dets(OVER_CAP),
            label_boxes_json=self._geometry(OVER_CAP),
            behavioural_key_json=self._key(OVER_CAP))

        self.assertEqual(image._label_box_cap(), 5)
        for fname in self.Image._LABEL_BOX_FIELDS:
            self.assertEqual(
                len(json.loads(image[fname])), 5,
                "%s was cut to the module default instead of the generator's "
                "own count" % fname)

    def test_a_generator_above_the_default_is_honoured(self):
        """The field is the authority in BOTH directions - it is a cap, not a
        second hard-coded 20 wearing a field's name."""
        question = self._label_question(self._generator(cap=OVER_CAP + 5))

        image = self._image(question, detections_json=self._dets(OVER_CAP))

        self.assertEqual(len(json.loads(image.detections_json)), OVER_CAP)

    def test_a_question_with_no_generator_falls_back_to_the_capture_plan(self):
        """Hand-authored bank questions, imports and Form Studio builds have no
        generator, so the ceiling frozen into the capture plan is next in
        line."""
        question = self._label_question()

        image = self._image(
            question,
            capture_config_json=json.dumps({"max_boxes": 7}),
            detections_json=self._dets(OVER_CAP))

        self.assertEqual(image._label_box_cap(), 7)
        self.assertEqual(len(json.loads(image.detections_json)), 7)

    def test_a_deleted_generator_does_not_lift_the_cap(self):
        """`generator_id` is ondelete="set null", so a question outlives the
        generator that authored it. Losing the generator must fall back to the
        default, never to "no ceiling"."""
        generator = self._generator(cap=5)
        question = self._label_question(generator)
        generator.unlink()

        image = self._image(question, detections_json=self._dets(OVER_CAP))

        self.assertFalse(question.generator_id)
        self.assertEqual(
            len(json.loads(image.detections_json)), DEFAULT_IMAGE_LABEL_COUNT)

    def test_an_under_cap_write_is_untouched(self):
        """The guard trims; it must not rewrite or reorder compliant data."""
        question = self._label_question(self._generator())
        payload = self._dets(3)

        image = self._image(question, detections_json=payload)

        self.assertEqual(json.loads(image.detections_json),
                         json.loads(payload))

    def test_unparseable_json_is_left_alone_rather_than_destroyed(self):
        """Truncating is a repair, not a validator. Garbage in a column is a
        different bug and must not be silently blanked by this one."""
        question = self._label_question(self._generator())

        image = self._image(question, detections_json="not json at all")

        self.assertEqual(image.detections_json, "not json at all")


# ----------------------------------------------------------------------
# 6 + 7. The cap can never resolve to zero
# ----------------------------------------------------------------------
@tagged("-at_install", "post_install")
class TestTheCapNeverResolvesToZero(_Base):
    """A 0-box labelling question is unanswerable, so 0 is never the answer.

    Callers read `image_label_count` off Many2ones that may be unset, which
    yields 0 / None / False routinely, and admins type strings. Every resolver
    treats "not a positive integer" as "no opinion" and falls back to the
    module default - the same 20 that was hard-coded before the cap existed, so
    callers with no generator in scope do not move.
    """

    BAD_CAPS = (0, None, False, -1, -20, "", "twenty", "10.5", [], {})

    def test_vertex_resolver_never_returns_zero(self):
        for bad in self.BAD_CAPS:
            self.assertEqual(
                vertex_svc._label_box_cap(bad), DEFAULT_IMAGE_LABEL_COUNT,
                "vertex._label_box_cap(%r) must fall back to the default, not "
                "to zero boxes" % (bad,))

    def test_labelling_resolver_never_returns_zero(self):
        for bad in self.BAD_CAPS:
            self.assertEqual(
                labelling_svc._resolve_cap(bad), DEFAULT_IMAGE_LABEL_COUNT,
                "labelling._resolve_cap(%r) must fall back to the default"
                % (bad,))

    def test_both_resolvers_honour_a_real_cap(self):
        """The fallback must not swallow a legitimate value, including one
        arriving as a string from a config parameter."""
        for good in (1, 5, TIGHT_CAP, OVER_CAP, "5"):
            self.assertEqual(vertex_svc._label_box_cap(good), int(good))
            self.assertEqual(labelling_svc._resolve_cap(good), int(good))

    def test_ideal_labels_count_clamps_to_the_default_when_uncapped(self):
        """The portal counts these entries to decide how many "Label N" inputs
        to render. `cap=None` is every caller with no generator in scope."""
        thirty = ["Does thing %d" % n for n in range(1, OVER_CAP + 1)]

        self.assertEqual(labelling_svc.ideal_labels_count(thirty, cap=None),
                         DEFAULT_IMAGE_LABEL_COUNT)
        self.assertEqual(labelling_svc.ideal_labels_count(thirty, cap=0),
                         DEFAULT_IMAGE_LABEL_COUNT)
        self.assertEqual(labelling_svc.ideal_labels_count(thirty, cap=-3),
                         DEFAULT_IMAGE_LABEL_COUNT)
        self.assertEqual(labelling_svc.ideal_labels_count(thirty, cap="junk"),
                         DEFAULT_IMAGE_LABEL_COUNT)

    def test_ideal_labels_count_honours_a_tighter_cap_in_every_shape(self):
        """A key reaches this function as a list, a JSON array, a JSON object
        or free text, and the render path must never offer more inputs than the
        authoring path was allowed to draw boxes for - in any of them."""
        entries = ["Does thing %d" % n for n in range(1, OVER_CAP + 1)]
        shapes = {
            "python list": entries,
            "json array": json.dumps(entries),
            "json object": json.dumps(_ideal_map(OVER_CAP)),
            "semicolon text": "; ".join(entries),
            "box-numbered text": "\n".join(
                "Box %d = does thing %d" % (n, n)
                for n in range(1, OVER_CAP + 1)),
        }
        for shape, value in shapes.items():
            self.assertEqual(
                labelling_svc.ideal_labels_count(value, cap=TIGHT_CAP),
                TIGHT_CAP, "%s was not capped" % shape)

    def test_an_empty_key_still_counts_zero(self):
        """The floor is about the CAP, not about the data. An empty key really
        does imply no boxes, and must keep returning 0 so the portal falls back
        to a free-text answer instead of drawing 20 empty inputs."""
        for empty in (None, "", [], {}, "   "):
            self.assertEqual(
                labelling_svc.ideal_labels_count(empty, cap=TIGHT_CAP), 0)

    def test_the_image_resolver_never_returns_zero(self):
        """A capture plan carrying a junk or zero `max_boxes` must not zero the
        image out - it falls through to the default."""
        question = self._label_question()
        for bad in (0, -4, "junk", None):
            image = self.Image.create({
                "question_id": question.id, "label": "Screenshot",
                "slot": "single",
                "capture_config_json": json.dumps({"max_boxes": bad}),
            })
            self.assertEqual(
                image._label_box_cap(), DEFAULT_IMAGE_LABEL_COUNT,
                "max_boxes=%r must fall back to the default" % (bad,))

    def test_the_draft_resolver_never_returns_zero(self):
        """The draft reads its ceiling straight off its generator. The model
        constraint refuses to STORE a 0 there, so this drives the column below
        the ORM to prove the defensive fallback is real and not dead code - if
        it is ever removed, a legacy row written before the constraint existed
        would generate a question with no boxes.
        """
        generator = self._generator(cap=5)
        draft = self.Draft.create({
            "prompt_id": generator.id,
            "name": "Label the controls %s" % uuid4().hex[:6],
            "question_type": "image_label",
        })
        self.assertEqual(draft._label_box_cap(), 5)

        self.env.cr.execute(
            "UPDATE assessments_be_prompt SET image_label_count = 0 "
            "WHERE id = %s", (generator.id,))
        generator.invalidate_recordset(["image_label_count"])

        self.assertEqual(draft._label_box_cap(), DEFAULT_IMAGE_LABEL_COUNT)

    def test_the_constraint_refuses_zero(self):
        """0 means "let the model decide" on `sop_question_count`, and an
        operator carries that reading over. It cannot mean the same here: the
        count is also the DENOMINATOR a labelling answer is normalised by, so a
        0 would author a question with no boxes and then divide by it."""
        with self.assertRaises(ValidationError):
            self._generator(cap=0)

    def test_the_constraint_refuses_negatives(self):
        with self.assertRaises(ValidationError):
            self._generator(cap=-1)

    def test_the_constraint_refuses_zero_on_write_too(self):
        """Rejected at the write path rather than clamped at read, so the bad
        value is never stored in the first place - including by an admin
        blanking the field on an existing generator."""
        generator = self._generator(cap=TIGHT_CAP)
        with self.assertRaises(ValidationError):
            generator.write({"image_label_count": 0})

    def test_the_constraint_accepts_one(self):
        """One box is a legitimate labelling question; the floor is 1, not
        some larger "sensible" minimum nobody documented."""
        self.assertEqual(self._generator(cap=1).image_label_count, 1)

    def test_the_field_default_is_the_module_default(self):
        self.assertEqual(self._generator().image_label_count,
                         DEFAULT_IMAGE_LABEL_COUNT)
