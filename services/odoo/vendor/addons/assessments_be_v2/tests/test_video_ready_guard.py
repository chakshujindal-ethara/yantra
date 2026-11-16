"""A video question must not be published before its clip exists.

THE DEFECT, reported from stage 2026-08-26: the Responses screen rendered
"No video yet for this question." over a submitted, graded answer. The
candidate had answered questions about a clip; the reviewer auditing that
score could not see it either.

ROOT CAUSE - an asymmetry, not a broken feature. `action_approve` has always
refused an IMAGE question whose picture had not rendered:

    if r.question_type in IMAGE_QUESTION_TYPES and not r._current_images():
        raise UserError(...)

There was no video equivalent, and no `_current_videos()` helper to build one
from. So a `video_prompt` draft approved while Veo was still generating went
through: `_video_files()` returned [], `_materialize_videos` created zero
`question.video` rows, and nothing ever backfilled them - materialisation runs
once, at approve time. The question was permanently clipless.

Both halves are pinned here: the helper reports staged clips, and approve
refuses when there are none.
"""
import json

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase

from ..constants import IMAGE_QUESTION_TYPES, VIDEO_QUESTION_TYPES


class TestVideoReadinessGuard(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Prompt = self.env["assessments.be.prompt"]
        self.Draft = self.env["assessments.be.prompt.question"]
        self.generator = self.Prompt.create({"name": "video guard probe"})

    def _draft(self, files=None):
        return self.Draft.create({
            "prompt_id": self.generator.id,
            "name": "Describe what happens in the clip",
            "question_prompt": "Describe what happens in the clip.",
            "question_type": "video_prompt",
            "state": "draft",
            "video_files_json": json.dumps(files) if files is not None else False,
        })

    # ---- the helper -------------------------------------------------
    def test_current_videos_is_empty_while_rendering(self):
        self.assertEqual(self._draft()._current_videos(), [])

    def test_current_videos_reports_a_staged_clip(self):
        draft = self._draft([{"slot": "single", "label": "The clip",
                              "url": "https://cdn.example.com/a.mp4"}])

        self.assertEqual(len(draft._current_videos()), 1)

    def test_current_videos_agrees_with_the_materialiser(self):
        """Both must read the same source or they can disagree about ready."""
        draft = self._draft([{"slot": "single", "url": "https://x/a.mp4"}])

        self.assertEqual(draft._current_videos(), draft._video_files())

    def test_malformed_json_reads_as_not_ready(self):
        draft = self._draft()
        draft.video_files_json = "{not json"

        self.assertEqual(draft._current_videos(), [],
                         "unparseable staging must fail CLOSED, not open")

    # ---- the guard --------------------------------------------------
    def test_approving_a_clipless_video_question_is_refused(self):
        draft = self._draft()

        with self.assertRaises(UserError) as caught:
            draft.action_approve()

        self.assertIn("no clip yet", str(caught.exception).lower())

    def test_the_refusal_names_the_draft(self):
        """An operator with 20 drafts needs to know WHICH one to wait for."""
        draft = self._draft()

        with self.assertRaises(UserError) as caught:
            draft.action_approve()

        self.assertIn("Describe what happens in the clip",
                      str(caught.exception))

    def test_a_draft_with_a_clip_approves(self):
        draft = self._draft([{"slot": "single", "label": "The clip",
                              "url": "https://cdn.example.com/a.mp4"}])

        draft.action_approve()

        self.assertEqual(draft.state, "approved")

    def test_the_escape_hatch_still_works(self):
        draft = self._draft()

        draft.with_context(skip_image_ready_guard=True).action_approve()

        self.assertEqual(draft.state, "approved")

    def test_a_non_video_question_is_unaffected(self):
        mcq = self.Draft.create({
            "prompt_id": self.generator.id,
            "name": "A plain question",
            "question_prompt": "Pick one.",
            "question_type": "mcq",
            "state": "draft",
            "options_json": json.dumps(
                [{"name": "right", "is_correct": True},
                 {"name": "wrong", "is_correct": False}]),
        })

        mcq.action_approve()

        self.assertEqual(mcq.state, "approved")

    def test_the_two_media_guards_are_symmetric(self):
        """The bug WAS the asymmetry - pin that both types are covered."""
        self.assertTrue(IMAGE_QUESTION_TYPES)
        self.assertTrue(VIDEO_QUESTION_TYPES)
        for qtype in VIDEO_QUESTION_TYPES:
            self.assertNotIn(qtype, IMAGE_QUESTION_TYPES,
                             "a type cannot be guarded by both branches")
