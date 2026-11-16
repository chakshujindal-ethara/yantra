"""An empty media ROW must not satisfy a question's media requirement.

THE DEFECT. Both guards answered by counting rows:

    def _has_required_images(self):  ...  return bool(self.image_ids)
    def _has_required_videos(self):  ...  return bool(self.video_ids)

An `assessments.be.question.image` row carries an `image` binary and an
`image_url`, and BOTH can be empty - a render that failed, a URL an examiner
cleared, a row created by an import that never attached anything. The row still
exists, so `bool(...)` is True and the question passes every gate that asks.

WHY THAT REACHES A CANDIDATE. These two are not cosmetic checks. Six callers
share them, and they are the ONLY thing standing between a medialess media
question and a live exam:

  * `models/assessment.py:764` - the launch draw
  * `controllers/api/admin.py:198, 683, 700, 1036` - the launch gate, the
    late-add pool and the preview
  * `models/question.py:261` - the servability compute

So an `image_prompt` whose render failed is drawn into a paper, and the
candidate is asked to write the prompt that would produce a picture they cannot
see. It is marked out of the same total as everyone else's.

`image_ab` was already stricter - it requires slots `a` and `b` - but only that
the SLOTS are named, so two rows with no bytes and no URL passed it too.

THE FIX asks what every consumer actually needs: a source to render from. A row
with neither binary nor URL is no more use than no row at all.

Tracker: SNo 100 (image side) and the video twin, which no row named - found by
review, and the one confirmed total gap in test coverage.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAQuestionWithNoMediaIsNotServable(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.Image = self.env["assessments.be.question.image"]
        self.Video = self.env["assessments.be.question.video"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Media guard fixture %s" % uuid4().hex[:6]})

    # A 1x1 PNG. Real bytes, because "has a source" is the thing under test and
    # a placeholder string would not prove the binary branch works.
    _PNG_B64 = (
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8"
        "z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")

    def _question(self, qtype):
        return self.Question.create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": qtype,
            "prompt": "Look at the media and answer.",
            "difficulty": "easy",
            "generator_id": self.generator.id,
        })

    # ── the video side ────────────────────────────────────────────────

    def test_a_video_row_with_no_clip_does_not_satisfy_the_guard(self):
        """THE HEADLINE. The row exists; there is no clip in it."""
        q = self._question("video_prompt")
        self.Video.create({"question_id": q.id, "slot": "single",
                           "label": "Clip"})
        self.assertTrue(q.video_ids, "fixture: the row must exist")
        self.assertFalse(
            q._has_required_videos(),
            "an empty video row satisfied the guard, so a video question with "
            "no clip is drawn into a paper and the candidate is asked about a "
            "clip they cannot watch")

    def test_a_video_row_with_a_url_does_satisfy_it(self):
        """The other half: a real clip must still pass.

        Without this, a guard that simply returned False would look 'fixed'.
        """
        q = self._question("video_prompt")
        self.Video.create({"question_id": q.id, "slot": "single",
                           "label": "Clip",
                           "video_url": "https://cdn.example.test/clip.mp4"})
        self.assertTrue(q._has_required_videos())

    def test_a_video_row_carrying_bytes_satisfies_it_too(self):
        """`video_url` is preferred in production, but the Binary is a
        supported dev fallback - so it has to count."""
        q = self._question("video_prompt")
        self.Video.create({"question_id": q.id, "slot": "single",
                           "label": "Clip", "video": self._PNG_B64})
        self.assertTrue(q._has_required_videos())

    def test_a_whitespace_url_is_not_a_clip(self):
        """A cleared field often lands as spaces rather than NULL."""
        q = self._question("video_prompt")
        self.Video.create({"question_id": q.id, "slot": "single",
                           "label": "Clip", "video_url": "   "})
        self.assertFalse(q._has_required_videos())

    # ── the image side (SNo 100) ──────────────────────────────────────

    def test_an_image_row_with_no_picture_does_not_satisfy_the_guard(self):
        """Same hole, same consequence: a labelling question with no plate."""
        q = self._question("image_label")
        self.Image.create({"question_id": q.id, "slot": "single",
                           "label": "Plate"})
        self.assertTrue(q.image_ids, "fixture: the row must exist")
        self.assertFalse(
            q._has_required_images(),
            "an empty image row satisfied the guard, so a labelling question "
            "with no plate reaches a candidate")

    def test_an_image_row_with_a_source_does_satisfy_it(self):
        q = self._question("image_label")
        self.Image.create({"question_id": q.id, "slot": "single",
                           "label": "Plate", "image": self._PNG_B64})
        self.assertTrue(q._has_required_images())

    def test_an_annotated_overlay_alone_counts_as_a_source(self):
        """`annotated_image` / `annotated_image_url` is what a UI-mode
        labelling question actually SERVES, so a row carrying only the overlay
        is renderable and must pass."""
        q = self._question("image_label")
        self.Image.create({
            "question_id": q.id, "slot": "single", "label": "Plate",
            "annotated_image_url": "https://cdn.example.test/overlay.png"})
        self.assertTrue(q._has_required_images())

    def test_image_ab_needs_a_picture_in_BOTH_slots_not_just_the_slots(self):
        """`image_ab` already required slots a and b - but only that they were
        NAMED. Two empty rows named a and b passed, and the candidate was asked
        to compare two blank plates."""
        q = self._question("image_ab")
        self.Image.create({"question_id": q.id, "slot": "a", "label": "A",
                           "image": self._PNG_B64})
        self.Image.create({"question_id": q.id, "slot": "b", "label": "B"})
        self.assertFalse(
            q._has_required_images(),
            "an A/B comparison passed with an empty B, so the candidate is "
            "asked to choose between one picture and a blank")

    def test_image_ab_with_both_plates_filled_passes(self):
        q = self._question("image_ab")
        for slot in ("a", "b"):
            self.Image.create({"question_id": q.id, "slot": slot,
                               "label": slot.upper(),
                               "image": self._PNG_B64})
        self.assertTrue(q._has_required_images())

    # ── the questions these guards must not touch ─────────────────────

    def test_a_text_question_is_unaffected(self):
        """Neither guard applies to a question with no media requirement. A fix
        that returned False for everything would break every text paper."""
        q = self._question("subjective_rubric")
        self.assertTrue(q._has_required_images())
        self.assertTrue(q._has_required_videos())

    # ── what the guard actually gates ─────────────────────────────────

    def test_the_examiner_is_warned_about_a_medialess_question(self):
        """The consequence an examiner can actually see.

        `missing_media_warning` (`question.py:242`, computed at `:250-266`) is
        the field that reads both guards, and its own text promises the question
        "will be skipped by every assessment until you add it" - which is only
        true if the guard notices. So this asserts the promise, not the helper.

        There is no `servable` field on this model; the warning is the
        user-visible surface, and the launch draw at `assessment.py:764` calls
        the two guards directly.
        """
        good = self._question("image_label")
        self.Image.create({"question_id": good.id, "slot": "single",
                           "label": "Plate", "image": self._PNG_B64})
        bad = self._question("image_label")
        self.Image.create({"question_id": bad.id, "slot": "single",
                           "label": "Plate"})

        self.assertFalse(
            good.missing_media_warning,
            "a question with a real plate must not be warned about")
        self.assertTrue(
            bad.missing_media_warning,
            "a question whose only image row is empty draws no warning, so "
            "nothing tells the examiner and the launch draw still takes it")
        self.assertIn("no image", bad.missing_media_warning.lower())
