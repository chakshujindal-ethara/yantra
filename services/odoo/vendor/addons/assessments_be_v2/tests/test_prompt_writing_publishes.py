"""Form Studio can finally author a PROMPT-WRITING question.

THE GAP THIS CLOSES. `image_prompt` and `video_prompt` are two of the seven
stored question types. The exam runner has rendered both for as long as they
have existed (`answer_layouts._ImagePromptLayout` / `_VideoPromptLayout`), and
`TASK_PRIMITIVE_TO_QUESTION_TYPE` routes `author_prompt` /
`author_video_prompt` onto them - so a TASK TEMPLATE could author one. Form
Studio could not: no designer kind produced either type, so `_item_spec` had
no branch that could ever emit them and a designer's document could not carry
a prompt-writing question at all. A generated one opened in the designer as a
lossy paragraph, and saving it back silently downgraded it to plain free text.

`FormItemKind.promptWriting` on the client plus this branch closes it. ONE kind
serves both stored types because they differ only in the medium the prompt has
to produce - exactly the reason the primitive table needed two entries but the
harness needs no third engine.

WHAT THESE TESTS PIN, and why each is the thing that would break silently:

  * THE MEDIUM IS READ, NOT ASKED. A `.mp4` publishes as `video_prompt` and a
    still as `image_prompt`, decided by `_looks_like_video`. If the author had
    to pick, the pick could disagree with the actual file and the runner would
    render the wrong layout for a question that looked correct in the designer.

  * THE PAIR KEEPS ITS DIRECTION. The transform form asks "write the prompt
    that turns the REFERENCE into the OUTPUT". Slots carry that; list order
    does not. Reading positionally would reverse the question with no symptom.

  * NO MEDIA IS A REFUSAL, NO GOLDEN PROMPT IS A WARNING. The stimulus IS the
    question - without it there is nothing to write a prompt for. A missing
    golden prompt only costs auto-scoring, which is the examiner's call to
    make, so it warns and publishes.

  * THE AXES ARE OPTIONAL, AND KEYED WHEN PRESENT. Every other option-carrying
    kind treats an empty option list as a defect; here it is the normal case,
    because the written prompt is the answer. An axis that IS added goes
    through the same single-answer guard as any other choice - the unearnable
    key `test_authored_question_marks` exists for costs marks here too.
"""
from uuid import uuid4

from odoo.tests.common import tagged

from odoo.addons.assessments_be_v2.tests.test_authored_question_marks import (
    _FormBase,
)


@tagged("post_install", "-at_install")
class TestPromptWritingPublishes(_FormBase):
    """`promptWriting` -> image_prompt | video_prompt."""

    # A clip URL, never fetched: `_create_questions` stores a video by URL and
    # only images go through `_fetch_media_b64`, so this costs no network.
    VIDEO_URL = "https://media.example.test/clip-%s.mp4" % uuid4().hex[:6]

    def _prompt_item(self, **extra):
        return self._item("promptWriting", **extra)

    # -- the medium decides the type -----------------------------------

    def test_a_still_publishes_as_image_prompt(self):
        form, result = self._publish(
            self._prompt_item(
                title="Write the prompt for this render",
                media_url=self.media_url,
                golden_answer="A red barn at dusk, wide shot.",
            ))
        question = self._published_one(form, result)
        self.assertEqual(
            question.question_type, "image_prompt",
            "a still stimulus must publish as image_prompt")
        self.assertEqual(
            len(question.image_ids), 1,
            "the plate must be attached to the question")
        self.assertEqual(question.image_ids.slot, "single")

    def test_a_clip_publishes_as_video_prompt(self):
        form, result = self._publish(
            self._prompt_item(
                title="Write the prompt for this clip",
                media_url=self.VIDEO_URL,
                golden_answer="A drone pull-back over pine forest.",
            ))
        question = self._published_one(form, result)
        self.assertEqual(
            question.question_type, "video_prompt",
            "an .mp4 stimulus must publish as video_prompt - the medium is "
            "read from the URL, not asked of the author")
        self.assertEqual(
            len(question.video_ids), 1,
            "the clip must be attached to the question")

    # -- the pair keeps its direction ----------------------------------

    def test_a_reference_output_pair_keeps_its_slots(self):
        form, result = self._publish(
            self._prompt_item(
                media_url=self.media_url,
                media_url_b=self.media_url_b,
                golden_answer="Remove the fence, keep the lighting.",
            ))
        question = self._published_one(form, result)
        slots = question.image_ids.mapped("slot")
        self.assertEqual(
            sorted(slots), ["output", "reference"],
            "the transform form must publish a reference -> output PAIR, not "
            "two anonymous plates; got %r" % (slots,))
        by_slot = {i.slot: i for i in question.image_ids}
        # The direction is the question. Reversing it asks the opposite thing.
        self.assertEqual(by_slot["reference"].label, "Reference")
        self.assertEqual(by_slot["output"].label, "Output")

    # -- refusals and warnings ----------------------------------------

    def test_no_media_is_refused_and_says_why(self):
        form, result = self._publish(self._prompt_item(golden_answer="x"))
        self._refused(form, result, "prompt-writing question needs")

    def test_no_golden_prompt_is_REFUSED(self):
        """THIS TEST USED TO ASSERT THE OPPOSITE - that a missing golden prompt
        only WARNED, on the reasoning that it costs auto-scoring and that is the
        examiner's call.

        It is now a refusal, and the reasoning above is what makes the old
        behaviour wrong: the golden prompt IS this question's answer key. Without
        one the judge marks a candidate's prompt against the stimulus alone, so
        it invents the standard per candidate - two candidates writing the same
        prompt can be scored differently and nothing on the paper says why. Every
        objective kind already refused to publish without its key; the subjective
        kinds now match, so "a published question is a markable question" holds
        for all of them rather than most.
        """
        form, result = self._publish(
            self._prompt_item(media_url=self.media_url))
        self._refused(form, result, "golden prompt")

    def test_the_golden_prompt_becomes_the_rubric_and_solution(self):
        golden = "A cinematic close-up, shallow depth of field."
        form, result = self._publish(
            self._prompt_item(media_url=self.media_url, golden_answer=golden))
        question = self._published_one(form, result)
        self.assertIn(
            golden, question.subjective_rubric_json or "",
            "the golden prompt is what the judge grades against, so it must "
            "reach the rubric")
        self.assertIn(golden, question.solution_json or "")
        self.assertTrue(
            question.rubric_reviewed,
            "the examiner authored this key by hand; publishing is the "
            "sign-off, as it is for every other studio kind")

    # -- the optional rating axes --------------------------------------

    def test_no_axes_is_normal_and_still_worth_a_mark(self):
        """An empty option list is the NORMAL case for this kind.

        Every other option-carrying kind refuses it. Here the written prompt
        is the answer, so the question must publish and still be worth its
        free-text component mark.
        """
        form, result = self._publish(
            self._prompt_item(media_url=self.media_url,
                              golden_answer="A prompt."))
        question = self._published_one(form, result)
        self.assertFalse(
            question.question_dimension_ids,
            "no axes were authored, so none should be minted")
        marks, _raw = question._component_counts()
        self.assertEqual(
            marks, 1,
            "a prompt-writing question with no axes is still worth its "
            "LLM-graded answer - one mark, not zero")

    def test_an_authored_axis_is_keyed_and_adds_its_mark(self):
        form, result = self._publish(
            self._prompt_item(
                media_url=self.media_url,
                golden_answer="A prompt.",
                options=self._opts(("Good", True), ("Poor", False)),
            ))
        question = self._published_one(form, result)
        self.assertEqual(
            len(question.question_dimension_ids), 1,
            "an authored axis must mint exactly one dimension")
        dim = question.question_dimension_ids
        self.assertEqual(
            dim.option_line_ids.filtered("is_correct").mapped("name"),
            ["Good"],
            "the axis must carry the key the designer marked")
        marks, _raw = question._component_counts()
        self.assertEqual(
            marks, 2,
            "the keyed axis and the written prompt are two components, so "
            "the question is worth 2")

    def test_a_one_option_axis_is_refused(self):
        form, result = self._publish(
            self._prompt_item(
                media_url=self.media_url,
                golden_answer="A red barn at dusk, wide shot.",
                options=self._opts(("Good", True)),
            ))
        self._refused(form, result, "at least two options")

    def test_an_unkeyed_axis_is_refused(self):
        """An axis nobody marked correct counts in the denominator and can
        never be earned - the same unearnable-key defect, on this kind."""
        form, result = self._publish(
            self._prompt_item(
                media_url=self.media_url,
                golden_answer="A red barn at dusk, wide shot.",
                options=self._opts(("Good", False), ("Poor", False)),
            ))
        self._refused(form, result, "no correct option")

    def test_a_two_correct_axis_is_refused(self):
        form, result = self._publish(
            self._prompt_item(
                media_url=self.media_url,
                golden_answer="A red barn at dusk, wide shot.",
                options=self._opts(("Good", True), ("Poor", True)),
            ))
        self._refused(form, result, "only one answer can be chosen")
