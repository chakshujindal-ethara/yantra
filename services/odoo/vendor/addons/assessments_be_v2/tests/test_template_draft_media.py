# -*- coding: utf-8 -*-
"""A drafted template must be able to SHOW the worker what the SOP judges.

THE BUG THIS PINS. An SOP whose whole subject is auditing an image drafted as
six Pass/Fail multipleChoice questions with no media anywhere and not one
warning - a candidate would have been asked whether a picture is sharp without
being shown a picture. The cause was not the model: the drafting prompt offered
it exactly four kinds ("multipleChoice", "checkboxes", "shortAnswer",
"paragraph"), none of which shows anything, while `_normalise_template_sections`
had already been widened to ACCEPT twelve. The ask and the receiver had drifted,
so the media kinds were reachable by a hand-authored template and unreachable by
a drafted one.

WHY `response` IS THE LEVER, NOT THE ITEM KIND. Generation reads
`task_template.answer_contract()`, which maps `response` through
TASK_PRIMITIVE_TO_QUESTION_TYPE to the question type - and only
image_ab/image_label/image_prompt/video_prompt ever have media rendered. The
item kinds contribute only the AXES: `_axes()` says "SHAPE DECIDES, NOT KIND",
taking any item with two or more options as one axis whatever its kind. So a
draft of plain multipleChoice items DOES show plates when `response` is a media
one. `to_question_specs()` - which does route kinds through `_item_spec` - is
called by NOTHING in production; it borrows Form Studio's publish validator,
which demands an answer key a reusable template deliberately has none of.

WHY A WARNING AND NOT A REWRITE. Which shape fits is a judgement about the task.
Guessing one here would swap a visible gap for an invisible wrong answer, and
the examiner would have no way to tell.
"""
from odoo.tests import common, tagged

from odoo.addons.assessments_be_v2.services import vertex


@tagged("post_install", "-at_install")
class TestTemplateDraftMedia(common.TransactionCase):

    # ------------------------------------------------------------------
    # The ask matches the receiver.
    # ------------------------------------------------------------------
    # Each kind with the extra fields it needs to SURVIVE the normaliser. A
    # grid with no rows/columns and a scale with no bounds are coerced to
    # shortAnswer by design (they carry no axis), so the fixture has to author
    # each kind properly or this would test the coercion instead of the offer.
    KIND_SHAPES = {
        "multipleChoice": {},
        "checkboxes": {},
        "dropdown": {},
        "choiceGrid": {"rows": ["r1", "r2"], "columns": ["Pass", "Fail"]},
        "checkboxGrid": {"rows": ["r1", "r2"], "columns": ["Pass", "Fail"]},
        "linearScale": {"scale_min": 1, "scale_max": 5,
                        "scale_min_label": "poor", "scale_max_label": "great"},
        "rating": {"rating_max": 5},
        "shortAnswer": {},
        "paragraph": {},
        "comparePair": {"left_label": "A", "right_label": "B"},
        "imageAnnotation": {"max_boxes": 4},
        "promptWriting": {"media_url": "https://example.test/plate.png"},
    }

    def test_every_kind_the_normaliser_accepts_is_offered_to_the_model(self):
        """No kind may be accepted-but-never-asked-for.

        This is the drift itself, asserted as a property rather than a list, so
        widening one side without the other fails here instead of silently
        producing draftable-by-hand-only kinds.
        """
        warnings = []
        offered = self._directive_text()
        for kind, extra in self.KIND_SHAPES.items():
            item = dict({"kind": kind, "title": "q",
                         "options": [{"label": "a"}, {"label": "b"}]}, **extra)
            sections, _count = vertex._normalise_template_sections(
                [{"title": "s", "items": [item]}], warnings)
            self.assertEqual(
                sections[0]["items"][0]["kind"], kind,
                "%s is no longer accepted by the normaliser; update this "
                "test and the directive together" % kind)
            self.assertIn(
                kind, offered,
                "%s is ACCEPTED by _normalise_template_sections but never "
                "OFFERED to the model in the drafting directive - so only a "
                "hand-authored template can ever use it" % kind)

    def test_the_media_kinds_are_named_as_the_ones_that_show_media(self):
        text = self._directive_text()
        for kind in ("comparePair", "imageAnnotation", "promptWriting"):
            self.assertIn(kind, text)
        # The rule has to connect the SOP's subject to the choice, not merely
        # list the kinds - listing alone is what failed before.
        self.assertIn("media_brief", text)

    def _directive_text(self):
        """The directive source, read from the function that builds it."""
        import inspect
        return inspect.getsource(vertex.draft_task_template_from_sop)

    # ------------------------------------------------------------------
    # A blind draft is flagged.
    # ------------------------------------------------------------------
    def test_an_image_sop_drafted_with_no_media_is_warned_about(self):
        """The exact shape that shipped wrong: image SOP, all multipleChoice."""
        tasks = [{
            "key": "image-entity-verification",
            "display": "Audit Image Reference Sets",
            "subject_inputs": "A main image with numbered boxes and its "
                              "reference images",
            "worker_output": "Pass or fail per axis",
        }]
        sections = [{"title": "Questions", "items": [
            {"kind": "multipleChoice", "title": "Is the Picture Sharp and "
                                                "Clear?",
             "options": [{"label": "Yes"}, {"label": "No"}]},
        ]}]
        self.assertTrue(vertex._sop_subject_names_media(tasks))
        self.assertFalse(vertex._draft_shows_media(sections, "single_choice"))

    def test_a_media_kind_satisfies_the_check(self):
        sections = [{"title": "Questions", "items": [
            {"kind": "comparePair", "title": "Is this the exact same item?",
             "options": [{"label": "Yes"}, {"label": "No"}]},
        ]}]
        self.assertTrue(vertex._draft_shows_media(sections, "single_choice"),
                        "the ITEM KIND decides the question type, so a "
                        "comparePair item shows media whatever the primitive")

    def test_a_media_primitive_satisfies_the_check(self):
        sections = [{"title": "Questions", "items": [
            {"kind": "multipleChoice", "title": "q",
             "options": [{"label": "a"}, {"label": "b"}]},
        ]}]
        for primitive in ("compare_two", "annotate_image", "author_prompt",
                          "author_video_prompt"):
            self.assertTrue(
                vertex._draft_shows_media(sections, primitive), primitive)

    def test_a_knowledge_sop_is_not_warned_about(self):
        """No false positive on a task that legitimately shows nothing.

        A warning on every text quiz would train the examiner to ignore it,
        which costs more than the warning buys.
        """
        tasks = [{
            "key": "policy-knowledge-check",
            "display": "Policy Knowledge Check",
            "subject_inputs": "Written scenarios describing a support ticket",
            "worker_output": "The correct policy decision",
        }]
        self.assertFalse(vertex._sop_subject_names_media(tasks))

    def test_media_words_are_matched_whole(self):
        """`_MEDIA_SUBJECT_WORDS` must not fire on a substring.

        "imagine" and "videographer" contain media words; a warning on those
        would be noise.
        """
        self.assertFalse(vertex._sop_subject_names_media(
            [{"key": "k", "subject_inputs": "Imagine a scenario and reimagine "
                                            "the outcome"}]))
        self.assertTrue(vertex._sop_subject_names_media(
            [{"key": "k", "subject_inputs": "A short video clip"}]))

    def test_no_registry_means_no_warning(self):
        """An SOP with no extracted task cannot be judged, so stay quiet."""
        self.assertFalse(vertex._sop_subject_names_media([]))
        self.assertFalse(vertex._sop_subject_names_media(None))

    # ------------------------------------------------------------------
    # The MEDIUM, which decides what can be asked at all.
    #
    # `author_video_prompt` is the only primitive that renders a clip, and
    # `video_prompt` carries no dimensions. So a SOP's pass/fail axes can be
    # asked about a still (they become the `image_ab` comparison's own
    # dimensions) and CANNOT be asked about a clip. Getting the medium wrong is
    # therefore not a cosmetic miss - it produces a template that cannot
    # generate what it appears to promise.
    # ------------------------------------------------------------------
    def _task(self, subject, output="A verdict per axis"):
        return [{"key": "k", "display": "T", "subject_inputs": subject,
                 "worker_output": output}]

    def test_the_medium_is_read_off_the_sop(self):
        video = self._task("Short marketing clips submitted by a vendor")
        image = self._task("A main image with numbered bounding boxes")
        both = self._task("A main image and the video it was cut from")

        self.assertTrue(vertex._sop_subject_names_video(video))
        self.assertFalse(vertex._sop_subject_names_image(video))

        self.assertTrue(vertex._sop_subject_names_image(image))
        self.assertFalse(vertex._sop_subject_names_video(image))

        self.assertTrue(vertex._sop_subject_names_video(both))
        self.assertTrue(vertex._sop_subject_names_image(both))

    def test_medium_words_match_whole_words_only(self):
        """"imagine" is not an image and "reframe" is not a frame."""
        self.assertFalse(vertex._sop_subject_names_image(
            self._task("Imagine the customer's intent and reimagine the reply")))
        self.assertFalse(vertex._sop_subject_names_video(
            self._task("Reframe the objection in the advisor's own words")))

    def test_axes_are_detected_by_shape_not_kind(self):
        """Mirrors `task_template._option_labels`, which is the real reader.

        THE DEFECT THIS PINS. An earlier version of `_draft_has_axes` read
        `options` alone, so a drafted grid, linear scale or rating counted as
        ZERO axes - reintroducing the exact bug `_option_labels` documents:
        "reading only `options` dropped all four to zero axes, so the kinds
        vanished from the contract even though the designer drew them."
        """
        def sec(item):
            return [{"title": "Questions", "items": [item]}]

        # Choice kinds carry `options`.
        self.assertTrue(vertex._draft_has_axes(sec(
            {"kind": "multipleChoice", "title": "Sharp?",
             "options": [{"label": "Pass"}, {"label": "Fail"}]})))
        # A grid carries its shared choices in `columns`.
        self.assertTrue(vertex._draft_has_axes(sec(
            {"kind": "choiceGrid", "rows": ["r1", "r2"],
             "columns": ["Pass", "Fail"]})))
        # A scale carries scale_min / scale_max.
        self.assertTrue(vertex._draft_has_axes(sec(
            {"kind": "linearScale", "scale_min": 1, "scale_max": 5})))
        # A rating carries rating_max.
        self.assertTrue(vertex._draft_has_axes(sec(
            {"kind": "rating", "rating_max": 5})))
        # Prose is NOT an axis - it is the response.
        self.assertFalse(vertex._draft_has_axes(sec(
            {"kind": "paragraph", "title": "Write the prompt"})))
        # One option is not a choice.
        self.assertFalse(vertex._draft_has_axes(sec(
            {"kind": "multipleChoice", "title": "x",
             "options": [{"label": "only"}]})))
        self.assertFalse(vertex._draft_has_axes([]))

    def test_media_words_do_not_fire_on_ordinary_prose(self):
        """A warning that cries wolf trains the examiner to ignore it.

        Every sentence below is text-only work, and every one of them used to
        trip the media check because "render", "still", "frame", "clip" and
        "recording" all have a common non-media sense.
        """
        for prose in (
                "Render a decision on each ticket and record the outcome",
                "The worker renders a verdict from the policy",
                "Clip the customer's quote into the summary",
                "Frame the objection in the advisor's own words",
                "Still open after the SLA window",
                "A recording of the call is attached",
        ):
            tasks = [{"key": "k", "subject_inputs": prose}]
            self.assertFalse(vertex._sop_subject_names_media(tasks), prose)

    def test_the_medium_check_reads_EVERY_task_not_only_the_primary(self):
        """The registry is a LIST, and the video half is often task two.

        Reading `tasks[0]` alone made this blind to exactly the "Image + Video"
        SOP the check exists for.
        """
        tasks = [
            {"key": "a", "display": "Audit stills",
             "subject_inputs": "A main image with numbered bounding boxes"},
            {"key": "b", "display": "Audit clips",
             "subject_inputs": "Short vendor videos"},
        ]
        self.assertTrue(vertex._sop_subject_names_image(tasks))
        self.assertTrue(vertex._sop_subject_names_video(tasks),
                        "the video task is second and must still be seen")
        # And the mismatch warning therefore fires for an image-only shape.
        w = vertex._draft_shape_warnings(tasks, self.AXES, "compare_two", "A pair.")
        self.assertTrue(any("renders stills" in x for x in w), w)

    def test_an_image_shape_renders_no_clip(self):
        """The IG Entity case: an 'Image + Video' SOP drafted as an image audit.

        Allowed - a template may cover one medium - but it must not be silent,
        which is what happened: a correct image audit came back and nothing
        anywhere said the video checks were left out.
        """
        for primitive in ("compare_two", "annotate_image", "author_prompt"):
            self.assertIn(primitive, vertex._IMAGE_PRIMITIVES)
            self.assertNotIn(primitive, vertex._VIDEO_PRIMITIVES)
        self.assertEqual(vertex._VIDEO_PRIMITIVES, frozenset({
            "author_video_prompt"}))

    def test_video_primitive_maps_to_the_only_video_question_type(self):
        """Pins the claim the medium rule rests on."""
        from odoo.addons.assessments_be_v2.constants import (
            TASK_PRIMITIVE_TO_QUESTION_TYPE, VIDEO_QUESTION_TYPES)
        self.assertEqual(
            TASK_PRIMITIVE_TO_QUESTION_TYPE["author_video_prompt"],
            "video_prompt")
        self.assertIn("video_prompt", VIDEO_QUESTION_TYPES)
        # And no OTHER primitive renders a clip.
        for primitive, qtype in TASK_PRIMITIVE_TO_QUESTION_TYPE.items():
            if qtype in VIDEO_QUESTION_TYPES:
                self.assertIn(primitive, vertex._VIDEO_PRIMITIVES)

    def test_the_directive_states_the_medium_rule(self):
        text = self._directive_text()
        self.assertIn("MIND THE MEDIUM", text)
        self.assertIn("author_video_prompt", text)

    # ------------------------------------------------------------------
    # THE WIRING, not just the conditions.
    #
    # These checks used to be inline in `draft_task_template_from_sop`, which
    # cannot run without an LLM call - so the conditions were tested through
    # their helpers while the thing that decides whether an examiner SEES a
    # warning was untested. `_draft_shape_warnings` is pure for this reason.
    # ------------------------------------------------------------------
    IMAGE_SOP = [{"key": "k", "display": "Audit image reference sets",
                  "subject_inputs": "A main image with numbered bounding boxes "
                                    "and reference images",
                  "worker_output": "Pass/Fail per axis"}]
    VIDEO_SOP = [{"key": "k", "display": "Audit submitted clips",
                  "subject_inputs": "Short vendor clips",
                  "worker_output": "Pass/Fail per axis"}]
    BOTH_SOP = [{"key": "k", "display": "Audit image and video",
                 "subject_inputs": "A main image and the video it was cut from",
                 "worker_output": "Pass/Fail per axis"}]
    TEXT_SOP = [{"key": "k", "display": "Policy check",
                 "subject_inputs": "Written support tickets",
                 "worker_output": "The correct policy decision"}]

    AXES = [{"title": "Questions", "items": [
        {"kind": "multipleChoice", "title": "Is the Picture Sharp and Clear?",
         "options": [{"label": "Pass"}, {"label": "Fail"}]},
    ]}]

    def _warn(self, tasks, response, brief="A pair of product photos.",
              sections=None):
        return vertex._draft_shape_warnings(
            tasks, sections if sections is not None else self.AXES,
            response, brief)

    def test_a_good_image_draft_warns_about_nothing(self):
        """The IG Entity shape, which is correct and must stay quiet."""
        self.assertEqual(self._warn(self.IMAGE_SOP, "compare_two"), [])

    def test_a_text_sop_with_no_media_warns_about_nothing(self):
        self.assertEqual(
            self._warn(self.TEXT_SOP, "single_choice", brief=""), [])

    def test_a_media_shape_with_no_brief_is_warned(self):
        w = self._warn(self.IMAGE_SOP, "compare_two", brief="")
        self.assertEqual(len(w), 1)
        self.assertIn("no brief describes it", w[0])

    def test_an_image_sop_drafted_blind_is_warned(self):
        """The original defect: image SOP, plain choices, nothing shown."""
        w = self._warn(self.IMAGE_SOP, "single_choice", brief="")
        self.assertTrue(any("shows the candidate nothing" in x for x in w), w)

    def test_a_video_sop_drafted_as_stills_is_warned(self):
        """Allowed, but never silent - the half that is missing gets named."""
        w = self._warn(self.BOTH_SOP, "compare_two")
        self.assertEqual(len(w), 1)
        self.assertIn("renders stills", w[0])

    def test_axes_on_a_clip_are_warned_as_unaskable(self):
        w = self._warn(self.VIDEO_SOP, "author_video_prompt")
        self.assertTrue(any("cannot be asked about a clip" in x for x in w), w)

    def test_a_clip_prompt_task_with_no_axes_is_fine(self):
        """Prompt-authoring on a clip is exactly what video_prompt is for."""
        prose = [{"title": "Questions", "items": [
            {"kind": "promptWriting", "title": "Write the prompt for this clip",
             "media_url": "x"}]}]
        self.assertEqual(
            self._warn(self.VIDEO_SOP, "author_video_prompt", sections=prose),
            [])

    def test_every_warning_names_the_fix_not_only_the_fault(self):
        for w in (self._warn(self.IMAGE_SOP, "compare_two", brief="")
                  + self._warn(self.IMAGE_SOP, "single_choice", brief="")
                  + self._warn(self.BOTH_SOP, "compare_two")
                  + self._warn(self.VIDEO_SOP, "author_video_prompt")):
            self.assertGreater(len(w), 60, w)

    # ------------------------------------------------------------------
    # THE WIRING, not just the conditions.
    #
    # These checks used to be inline in `draft_task_template_from_sop`, which
    # cannot run without an LLM call - so the conditions were tested through
    # their helpers while the thing that decides whether an examiner SEES a
    # warning was untested. `_draft_shape_warnings` is pure for this reason.
    # ------------------------------------------------------------------
    IMAGE_SOP = [{"key": "k", "display": "Audit image reference sets",
                  "subject_inputs": "A main image with numbered bounding boxes "
                                    "and reference images",
                  "worker_output": "Pass/Fail per axis"}]
    VIDEO_SOP = [{"key": "k", "display": "Audit submitted clips",
                  "subject_inputs": "Short vendor clips",
                  "worker_output": "Pass/Fail per axis"}]
    BOTH_SOP = [{"key": "k", "display": "Audit image and video",
                 "subject_inputs": "A main image and the video it was cut from",
                 "worker_output": "Pass/Fail per axis"}]
    TEXT_SOP = [{"key": "k", "display": "Policy check",
                 "subject_inputs": "Written support tickets",
                 "worker_output": "The correct policy decision"}]

    AXES = [{"title": "Questions", "items": [
        {"kind": "multipleChoice", "title": "Is the Picture Sharp and Clear?",
         "options": [{"label": "Pass"}, {"label": "Fail"}]},
    ]}]

    def _warn(self, tasks, response, brief="A pair of product photos.",
              sections=None):
        return vertex._draft_shape_warnings(
            tasks, sections if sections is not None else self.AXES,
            response, brief)

    def test_a_good_image_draft_warns_about_nothing(self):
        """The IG Entity shape, which is correct and must stay quiet."""
        self.assertEqual(self._warn(self.IMAGE_SOP, "compare_two"), [])

    def test_a_text_sop_with_no_media_warns_about_nothing(self):
        self.assertEqual(
            self._warn(self.TEXT_SOP, "single_choice", brief=""), [])

    def test_a_media_shape_with_no_brief_is_warned(self):
        w = self._warn(self.IMAGE_SOP, "compare_two", brief="")
        self.assertEqual(len(w), 1)
        self.assertIn("no brief describes it", w[0])

    def test_an_image_sop_drafted_blind_is_warned(self):
        """The original defect: image SOP, plain choices, nothing shown."""
        w = self._warn(self.IMAGE_SOP, "single_choice", brief="")
        self.assertTrue(any("shows the candidate nothing" in x for x in w), w)

    def test_a_video_sop_drafted_as_stills_is_warned(self):
        """Allowed, but never silent - the half that is missing gets named."""
        w = self._warn(self.BOTH_SOP, "compare_two")
        self.assertEqual(len(w), 1)
        self.assertIn("renders stills", w[0])

    def test_axes_on_a_clip_are_warned_as_unaskable(self):
        w = self._warn(self.VIDEO_SOP, "author_video_prompt")
        self.assertTrue(any("cannot be asked about a clip" in x for x in w), w)

    def test_a_clip_prompt_task_with_no_axes_is_fine(self):
        """Prompt-authoring on a clip is exactly what video_prompt is for."""
        prose = [{"title": "Questions", "items": [
            {"kind": "promptWriting", "title": "Write the prompt for this clip",
             "media_url": "x"}]}]
        self.assertEqual(
            self._warn(self.VIDEO_SOP, "author_video_prompt", sections=prose),
            [])

    def test_warnings_are_plain_sentences_an_examiner_can_act_on(self):
        """Every warning must name the fix, not only the fault."""
        for w in (self._warn(self.IMAGE_SOP, "compare_two", brief="")
                  + self._warn(self.IMAGE_SOP, "single_choice", brief="")
                  + self._warn(self.BOTH_SOP, "compare_two")
                  + self._warn(self.VIDEO_SOP, "author_video_prompt")):
            self.assertGreater(len(w), 60, w)
            self.assertNotIn("_", w.split(" ")[0], "no identifiers up front")

    # ------------------------------------------------------------------
    # The contract generation actually reads.
    # ------------------------------------------------------------------
    def test_a_media_response_carries_the_brief_to_the_generator(self):
        """`media_brief` must reach `answer_contract`, or every item differs.

        The contract's own comment: the brief "anchors the stimulus so every
        generated item is a variation on the same task rather than a different
        one". A compare_two template could not state one, because the editor
        offered the field to four primitives and compare_two was not among them
        - the one that shows the MOST media, two plates.
        """
        tpl = self.env["assessments.be.task.template"].sudo().create({
            "name": "Audit reference sets",
            "response": "compare_two",
            "media_brief": "A product photo and a sourced reference of the "
                           "same product, one carrying a colorway difference.",
            "structure_json": [{"title": "Questions", "items": [
                {"kind": "multipleChoice", "title": "Is the Picture Sharp and "
                                                   "Clear?",
                 "options": [{"label": "Pass"}, {"label": "Fail"}]},
                {"kind": "multipleChoice", "title": "Is This From the Same "
                                                    "Photoshoot?",
                 "options": [{"label": "Pass"}, {"label": "Fail"}]},
            ]}],
        })
        contract = tpl.answer_contract()
        self.assertEqual(contract["response"], "compare_two")
        self.assertIn("media_brief", contract)
        self.assertIn("colorway", contract["media_brief"])

    def test_plain_choice_items_still_become_axes(self):
        """Kind does not gate an axis - shape does.

        This is why a draft of multipleChoice items is not broken so long as
        `response` shows media: each item is still one graded axis about the
        plate, with the SOP's own option labels.
        """
        tpl = self.env["assessments.be.task.template"].sudo().create({
            "name": "Audit", "response": "compare_two",
            "media_brief": "A pair of product photos.",
            "structure_json": [{"title": "Questions", "items": [
                {"kind": "multipleChoice", "title": "Sharp and clear?",
                 "options": [{"label": "Pass"}, {"label": "Fail"}]},
                {"kind": "multipleChoice", "title": "Watermark?",
                 "options": [{"label": "Pass"}, {"label": "Fail"}]},
                {"kind": "paragraph", "title": "Name the difference"},
            ]}],
        })
        contract = tpl.answer_contract()
        labels = [d["label"] for d in contract["dimensions"]]
        self.assertEqual(labels, ["Sharp and clear?", "Watermark?"],
                         "each choice item is one axis; the free-text item is "
                         "the response, not an axis")
        self.assertEqual(
            contract["dimension_options"]["Watermark?"], ["Pass", "Fail"],
            "the SOP's own words must survive to the generator")

    # ------------------------------------------------------------------
    # THE WARNINGS OUTLIVE THE TOAST.
    #
    # They were surfaced once, as `toaster.info` per line. A toast lasts three
    # seconds and belongs to the tab that saw it, so the only signal saying
    # "this template will generate the wrong thing" was gone on dismiss, on
    # reload, and to whoever opened the template next.
    # ------------------------------------------------------------------
    def _tpl(self, **kw):
        vals = dict(name="T", response="compare_two",
                    media_brief="A pair of product photos.",
                    structure_json=self.AXES)
        vals.update(kw)
        return self.env["assessments.be.task.template"].sudo().create(vals)

    def test_a_sound_template_carries_no_warnings(self):
        rec = self._tpl()
        self.assertFalse(rec.has_shape_warnings)
        self.assertFalse((rec.shape_warnings or "").strip())

    def test_a_media_shape_with_no_brief_is_warned_ON_THE_RECORD(self):
        """Gap 6: an empty brief saved silently and generation ran unanchored."""
        rec = self._tpl(media_brief="")
        self.assertTrue(rec.has_shape_warnings)
        self.assertIn("no brief describes it", rec.shape_warnings)

    def test_fixing_the_cause_clears_the_warning(self):
        """Computed, so it cannot go stale - the reason it is not stored raw."""
        rec = self._tpl(media_brief="")
        self.assertTrue(rec.has_shape_warnings)
        rec.media_brief = "A main image with numbered boxes and a reference."
        self.assertFalse(rec.has_shape_warnings, rec.shape_warnings)

    def test_editing_a_good_template_into_a_bad_one_earns_the_warning(self):
        """No second LLM call needed - it recomputes off the record."""
        rec = self._tpl()
        self.assertFalse(rec.has_shape_warnings)
        rec.media_brief = ""
        self.assertTrue(rec.has_shape_warnings)

    def test_one_implementation_serves_the_drafter_and_the_record(self):
        """The public alias exists so the two can never disagree."""
        self.assertIs(vertex.draft_shape_warnings.__wrapped__
                      if hasattr(vertex.draft_shape_warnings, "__wrapped__")
                      else vertex.draft_shape_warnings,
                      vertex.draft_shape_warnings)
        rec = self._tpl(media_brief="")
        direct = vertex.draft_shape_warnings(
            [], self.AXES, "compare_two", "")
        self.assertEqual(rec.shape_warnings, "\n".join(direct))

