"""A video-only draft must not wait forever for an image - SNo 116.

THE DEFECT. `vertex.generate_questions_from_sop` stamped the media states with

    if vals.get("image_brief_json") or vals.get("video_brief_json"):
        vals["image_state"] = "pending"

so a VIDEO-ONLY draft was marked as waiting for an image it can never have:
`_build_image_draft_fields` returns early on `video_prompt` carrying only
`video_brief_json` (services/vertex.py:3298-3306), and the render cron requires
BOTH `image_state = 'pending'` AND `image_brief_json != False`
(models/prompt.py:3956-3958). Nothing ever claimed the row, so nothing ever
cleared the flag.

THE VISIBLE DAMAGE is `generation_status`, computed `in_progress` while
`image_state == "pending"` (models/prompt.py:2140): a video draft whose clip had
finished rendering reported itself as still rendering, forever. A reviewer waited
on work that was already done and the batch never looked complete.

NO MIGRATION SHIPS WITH THIS, deliberately. Measured on etp_local and etp_walk2:
zero rows are stranded, because neither database contains a single `video_prompt`
draft. A migration would be a data fix for data that does not exist, and a
migration nobody can point at a row for is a migration nobody can verify.

The rule now lives in `vertex.media_states_for_briefs`, extracted for one reason:
it decides whether a render cron ever looks at a row, and inline inside a function
that calls Vertex the only way to test it was to mock the model.

WHAT THESE TESTS PIN. The two states are INDEPENDENT, which is what having two
fields has always meant - and independence has to hold in all four combinations,
not just the one that was broken.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.services import vertex


@tagged("-at_install", "post_install")
class TestAVideoDraftIsNotWaitingForAnImage(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Media state fixture %s" % uuid4().hex[:6]})

    def _states(self, qtype, specs):
        """The media states a draft of this shape starts in.

        DRIVEN THROUGH BOTH REAL FUNCTIONS, composed the way generation composes
        them: `_build_image_draft_fields` decides which briefs the item carries,
        and `media_states_for_briefs` decides what that means for the two state
        fields. A test that hand-built the briefs would prove the second half
        while assuming the first, and the first half is where the asymmetry lives
        (video_prompt returns early with no image brief at all).
        """
        briefs = vertex._build_image_draft_fields(
            self.env, qtype,
            {"image_specs": specs, "name": "Draft %s" % uuid4().hex[:4]},
        ) if qtype in vertex._IMAGE_OR_VIDEO_TYPES else {}
        states = vertex.media_states_for_briefs(briefs)
        return states.get("image_state"), states.get("video_state")

    # ── the bug ───────────────────────────────────────────────────────

    def test_a_video_only_draft_does_not_wait_for_an_image(self):
        """THE HEADLINE. A video_prompt item yields a video brief and no image
        brief, so nothing about it is pending on an image."""
        image_state, video_state = self._states("video_prompt", {
            "videos": [{"slot": "single", "prompt": "A 5s clip of a forklift "
                                                    "reversing near a person"}],
            "answer_key": {"ideal_prompt": "Name the hazard and the distance"},
        })

        self.assertEqual(video_state, "pending",
                         "the clip genuinely does have to render")
        self.assertNotEqual(
            image_state, "pending",
            "there is no image brief on a video_prompt draft, and the render "
            "cron requires one - so `image_state = pending` here is a flag "
            "nothing can ever clear, and generation_status reads in_progress "
            "for ever")

    def test_the_draft_reports_itself_finished_once_its_clip_lands(self):
        """THE PRODUCT FACT the flag broke. `generation_status` is what a
        reviewer reads to know whether a batch is done."""
        draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": self.generator.id,
            "name": "Author the prompt for this clip",
            "question_type": "video_prompt",
            "question_prompt": "What prompt would produce this clip?",
        })
        image_state, _ = self._states("video_prompt", {
            "videos": [{"slot": "single", "prompt": "A 5s clip"}],
        })
        draft.write({
            "image_state": image_state or "none",
            "video_state": "rendered",
        })
        draft.invalidate_recordset()

        self.assertEqual(
            draft.generation_status, "finished",
            "a video draft whose clip has rendered is DONE - it reported "
            "in_progress for ever because image_state sat at pending")

    # ── the other three combinations ──────────────────────────────────

    def test_an_image_only_draft_still_waits_for_its_image(self):
        """The fix must not stop stamping the state that IS load-bearing: the
        render cron's whole domain is `image_state = 'pending'`."""
        image_state, video_state = self._states("image_prompt", {
            "images": [{"slot": "single",
                        "prompt": "A warehouse aisle with a spill"}],
            "answer_key": {"ideal_prompt": "Name the spill and the aisle"},
        })

        self.assertEqual(image_state, "pending",
                         "an image brief must still queue the render cron")
        self.assertNotEqual(video_state, "pending",
                            "there is no clip to wait for")

    def test_a_labelling_draft_still_waits_for_its_plate(self):
        """image_label is the type that carries the most media machinery, and it
        goes down a different branch of the builder."""
        image_state, _ = self._states("image_label", {
            "images": [{"slot": "single",
                        "prompt": "A dashboard with three broken controls"}],
            "answer_key": {"ideal_labels": {"1": "Broken toggle"}},
        })

        self.assertEqual(image_state, "pending")

    def test_a_text_draft_waits_for_nothing(self):
        """A question with no media at all must not be stamped on either axis -
        that is the `none` default, and `generation_status` reads it as
        finished."""
        image_state, video_state = self._states("mcq", {})

        self.assertNotEqual(image_state, "pending")
        self.assertNotEqual(video_state, "pending")
