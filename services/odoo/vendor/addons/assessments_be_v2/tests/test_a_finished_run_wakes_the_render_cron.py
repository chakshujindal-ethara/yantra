# -*- coding: utf-8 -*-
"""A finished generation run starts its renders now, not at the next tick.

THE GAP (#10). The SOP cron finished a run with drafts waiting on images, and
the render cron only looked at them on its next 5-minute tick. The run now
`_trigger()`s the render cron (and the Veo poll cron for clips) when it
finishes with media pending, and only then. Batch size and interval are
untouched: the one cron slot per pod also runs scoring.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger

from ..services import vertex


@tagged("-at_install", "post_install")
class TestAFinishedRunWakesTheRenderCron(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Prompt = self.env["assessments.be.prompt"]
        self.Draft = self.env["assessments.be.prompt.question"]
        self.generator = self.Prompt.create(
            {"name": "Wake %s" % uuid4().hex[:6]})
        self.render = self.env.ref(
            "assessments_be_v2.ir_cron_render_pending_images").sudo()
        self.video = self.env.ref(
            "assessments_be_v2.ir_cron_poll_video_ops").sudo()
        (self.render | self.video).active = True

    def _triggers(self, cron):
        return self.env["ir.cron.trigger"].sudo().search_count(
            [("cron_id", "=", cron.id)])

    def _finish_a_run(self, **draft_vals):
        """Run the SOP cron once over this generator, authoring one draft."""
        self.Prompt.search([
            ("sop_gen_state", "in", ("queued", "generating")),
            ("id", "!=", self.generator.id)]).write({"sop_gen_state": "idle"})
        self.generator.write({"sop_gen_state": "queued"})

        def author(env, prompt, **kw):
            kw["report"].update(returned=1, created=1, rejected=0, reasons=[])
            return [self.Draft.create(dict({
                "prompt_id": prompt.id, "name": "Draft",
                "question_type": "mcq"}, **draft_vals)).id]

        before = self._triggers(self.render), self._triggers(self.video)
        with patch.object(vertex, "generate_questions_from_sop",
                          side_effect=author), \
                patch.object(self.env.cr, "commit", self.env.flush_all), \
                patch.object(self.env.cr, "rollback", lambda: None), \
                mute_logger("odoo.addons.assessments_be_v2.models.prompt"):
            self.Prompt._cron_generate_from_sop()
        self.assertEqual(self.generator.sop_gen_state, "done")
        return (self._triggers(self.render) - before[0],
                self._triggers(self.video) - before[1])

    def test_pending_images_trigger_the_render_cron(self):
        self.assertEqual(
            self._finish_a_run(question_type="image_prompt",
                               image_state="pending"), (1, 0))

    def test_pending_clips_trigger_the_video_cron(self):
        self.assertEqual(
            self._finish_a_run(question_type="video_prompt",
                               video_state="pending"), (0, 1))

    def test_nothing_pending_triggers_nothing(self):
        self.assertEqual(self._finish_a_run(), (0, 0))

    def test_an_inactive_cron_is_left_alone(self):
        self.render.active = False
        self.assertEqual(
            self._finish_a_run(question_type="image_prompt",
                               image_state="pending"), (0, 0))

    # ── R10 (15 Oct): Generate starts now; a batch that renders chains ──

    def test_generate_wakes_the_generation_cron(self):
        """It waited up to a full tick (3m51s measured on stage)."""
        cron = self.env.ref(
            "assessments_be_v2.ir_cron_generate_from_sop").sudo()
        cron.active = True
        self.generator.source_text = "A SOP body."
        before = self._triggers(cron)
        self.generator.action_generate_from_sop()
        self.assertEqual(self._triggers(cron) - before, 1)

    def _render_a_batch(self, renders):
        """Three drafts pending, one batch of the render cron over them."""
        self.Draft.search([("image_state", "=", "pending")]).write(
            {"image_state": "failed"})
        for n in range(3):
            self.Draft.create({
                "prompt_id": self.generator.id, "name": "Draft %d" % n,
                "question_type": "image_prompt", "image_state": "pending",
                "image_brief_json": '[{"slot": "single", "prompt": "a cat"}]'})

        def render(draft):
            if renders:
                draft.image_state = "rendered"
            return renders

        before = self._triggers(self.render)
        with patch.object(type(self.Draft), "_render_all_images",
                          autospec=True, side_effect=render), \
                patch.object(self.env.cr, "commit", self.env.flush_all), \
                patch.object(self.env.cr, "rollback", lambda: None), \
                mute_logger("odoo.addons.assessments_be_v2.models.prompt"):
            self.Draft._cron_render_pending_images()
        return self._triggers(self.render) - before

    def test_a_batch_that_renders_wakes_the_next_batch(self):
        self.assertEqual(self._render_a_batch(renders=True), 1)

    def test_a_batch_that_renders_nothing_waits_for_the_tick(self):
        """No hot loop: a 429 or a failure waits the 5 minutes."""
        self.assertEqual(self._render_a_batch(renders=False), 0)
