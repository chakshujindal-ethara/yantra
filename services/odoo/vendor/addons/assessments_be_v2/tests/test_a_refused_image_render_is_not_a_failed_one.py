# -*- coding: utf-8 -*-
"""A refusal to spend is not a failed image render.

`render_draft_images` caught every exception per slot. A missing Vertex
configuration therefore burned the draft's three render attempts and left it
`failed` with only a log line; a spend cap did the same, and a killed
generator's refusal never reached the cron's `cancelled` branch.

  * not configured: `failed` at once, no attempt spent, and the reason in
    `image_error` - the field the review card already shows;
  * spend cap: left `pending`, no attempt spent, like a 429;
  * kill: `cancelled`, as the cron always meant, keeping a slot that had
    already rendered (it is paid for).
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import serializers as S
from ..services import vertex


@tagged("-at_install", "post_install")
class TestARefusedImageRenderIsNotAFailedOne(TransactionCase):

    def setUp(self):
        super().setUp()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Render %s" % uuid4().hex[:6]})
        self.draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": generator.id,
            "name": "Draft %s" % uuid4().hex[:6],
            "question_type": "image_prompt",
            "question_prompt": "Describe the picture.",
            "image_brief_json": json.dumps(
                [{"slot": "single", "prompt": "A red bicycle."}]),
            "image_state": "pending",
        })
        # Only this draft is waiting: the cron takes a batch.
        self.env["assessments.be.prompt.question"].search([
            ("id", "!=", self.draft.id), ("image_state", "=", "pending"),
        ]).write({"image_state": "none"})

    def _cron(self, refusal):
        # The cron commits per draft; a test cursor forbids it.
        with patch.object(self.env.cr, "commit", self.env.flush_all), \
                patch.object(self.env.cr, "rollback", lambda: None), \
                patch.object(vertex, "generate_image",
                             side_effect=refusal):
            self.env["assessments.be.prompt.question"] \
                ._cron_render_pending_images()
        self.draft.invalidate_recordset()

    def test_no_configuration_fails_at_once_and_says_why(self):
        self._cron(vertex.VertexNotConfiguredError(
            vertex._NOT_CONFIGURED % "no API key is set"))

        self.assertEqual(self.draft.image_state, "failed")
        self.assertEqual(self.draft.image_render_attempts, 0)
        self.assertIn("Settings > Assessments v2 > Vertex AI",
                      self.draft.image_error)
        self.assertEqual(S.draft_row(self.draft)["image_error"],
                         self.draft.image_error)

    def test_a_failure_with_no_stored_reason_sends_null(self):
        """The review card falls back to its own text on null; "" blanked it."""
        self.draft.image_state = "failed"
        self.assertIsNone(S.draft_row(self.draft)["image_error"])

    def test_a_spend_cap_waits_without_spending_an_attempt(self):
        self._cron(vertex.VertexBudgetError("Daily LLM spend cap reached"))

        self.assertEqual(self.draft.image_state, "pending")
        self.assertEqual(self.draft.image_render_attempts, 0)

    def test_a_kill_cancels_the_render(self):
        self._cron(vertex.VertexCancelledError("killed by an admin"))

        self.assertEqual(self.draft.image_state, "cancelled")
        self.assertEqual(self.draft.image_render_attempts, 0)

    def test_a_kill_between_two_slots_keeps_the_first(self):
        self.draft.image_brief_json = json.dumps(
            [{"slot": "a", "prompt": "A red bicycle."},
             {"slot": "b", "prompt": "A blue bicycle."}])
        self._cron([("aGk=", "image/png"),
                    vertex.VertexCancelledError("killed by an admin")])

        self.assertEqual(self.draft.image_state, "cancelled")
        self.assertEqual([img["slot"] for img in
                          json.loads(self.draft.images_json)], ["a"])

    def test_a_retry_clears_the_reason(self):
        self.draft.write({"image_state": "failed",
                          "image_error": "The AI model is not configured."})

        self.draft.action_retry_image_render()

        self.assertEqual(self.draft.image_state, "pending")
        self.assertFalse(self.draft.image_error)

    def test_an_uploaded_image_clears_the_reason(self):
        """The upload replaces the failed render, but the old reason was
        still sent and the review card kept saying why it failed."""
        self.draft.write({"image_state": "failed",
                          "image_error": "The AI model is not configured.",
                          "upload_slot": "single",
                          "upload_image": "iVBORw0KGgo="})

        self.draft.action_apply_uploaded_image()

        self.assertEqual(self.draft.image_state, "uploaded")
        self.assertFalse(self.draft.image_error)
        self.assertIsNone(S.draft_row(self.draft)["image_error"])

    def test_a_refusal_while_re_rendering_for_flaw_checks_ends_the_check(self):
        """The flaw check re-renders a side whose flaw is not visible. A spend
        cap or a kill refused there now ends that side's check as
        `unavailable` - what a refused verify call already did - instead of
        failing the whole verification."""
        images = [{"slot": "a", "label": "A",
                   "data": "data:image/png;base64,iVBORw0KGgo="}]
        absent = {"verdicts": [{"flaw": "a bent spoke", "present": False}],
                  "all_present": False}
        for refusal in (vertex.VertexBudgetError("cap"),
                        vertex.VertexCancelledError("killed")):
            with self.subTest(type(refusal).__name__), \
                    patch.object(vertex, "verify_planted_flaws",
                                 return_value=absent), \
                    patch.object(vertex, "render_draft_images",
                                 side_effect=refusal):
                kept, record = vertex.verify_and_regenerate_ab_images(
                    self.env, [{"slot": "a", "prompt": "A bicycle."}],
                    images, {"a": ["a bent spoke"]})
            self.assertEqual(kept, images)
            self.assertTrue(record["sides"]["a"]["unavailable"])
            self.assertFalse(record["needs_review"])
