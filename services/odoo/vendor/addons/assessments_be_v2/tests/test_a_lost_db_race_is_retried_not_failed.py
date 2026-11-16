# -*- coding: utf-8 -*-
"""A cron that loses a transient DB race retries next tick; it never fails.

THE PRODUCTION DEFECT (2026-09-29). `_cron_render_pending_images` rendered a
draft (paid Vertex work, S3 upload), then the savepoint's flush raised
`SerializationFailure`. `except Exception` rolled back and marked the draft
`failed`, so it never retried - and `rendered` had already been counted, so the
log said "rendered 1/1". `_cron_extract_tags` failed the generator the same way
and `_cron_detect_image_labels` burned one of its three attempts.

Pinned for all three: the row is left for the next tick (state and attempts
unchanged), nothing is counted as done, and a WARNING names the other writer
(`write_uid`), read on a fresh cursor.
"""
import base64
import json
import logging
from unittest.mock import patch
from uuid import uuid4

from psycopg2.errors import (
    DeadlockDetected, LockNotAvailable, SerializationFailure,
    TransactionRollbackError)

from odoo.tests.common import TransactionCase, tagged

from ..models import prompt as prompt_mod
from ..services import vertex

_LOGGER = "odoo.addons.assessments_be_v2.models"


@tagged("-at_install", "post_install")
class TestALostDbRaceIsRetriedNotFailed(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Race %s" % uuid4().hex[:6],
             "source_text": "A SOP body."})
        # The other writer: whoever last wrote the row the cron lost.
        self.racer = self.env["res.users"].create({
            "name": "Racer", "login": "racer_%s" % uuid4().hex[:8]})

    def _run(self, cron, commit_raises=True):
        """Run ``cron`` as the scheduler would, with its FIRST commit losing
        the race - where the savepoint flush or commit surfaces a 40001.

        Commit/rollback are redirected at the test's transaction (the test
        cursor refuses both), and the registry is in test mode so the fresh
        cursor the warning reads on sees this test's rows.
        """
        cr = self.env.cr
        lost = []

        def commit():
            if commit_raises and not lost:
                lost.append(True)
                raise SerializationFailure(
                    "could not serialize access due to concurrent update")
            self.env.flush_all()

        # logging.INFO, never "INFO": Odoo names its RUNBOT level "INFO".
        with self.enter_registry_test_mode(), \
                patch.object(cr, "commit", commit), \
                patch.object(cr, "rollback", cr.clear), \
                self.assertLogs(_LOGGER, level=logging.INFO) as logs:
            cron()
        return logs.output

    def _warned(self, output, record):
        warnings = [line for line in output if line.startswith("WARNING")
                    and str(record.id) in line
                    and "write_uid=%d" % self.racer.id in line]
        self.assertTrue(warnings, "no WARNING naming the other writer:\n%s"
                        % "\n".join(output))

    def test_the_image_render_cron_leaves_the_draft_pending(self):
        Draft = self.env["assessments.be.prompt.question"]
        Draft.search([("image_state", "=", "pending")]).write(
            {"image_state": "failed"})
        draft = Draft.create({
            "prompt_id": self.generator.id, "name": "Draft",
            "question_type": "image_prompt", "image_state": "pending",
            "image_render_attempts": 1,
            "image_brief_json": '[{"slot": "single", "brief": "a cat"}]'})
        draft.with_user(self.racer).sudo().write({"name": "Draft (edited)"})

        with patch.object(type(Draft), "_render_all_images",
                          return_value=True):
            output = self._run(Draft._cron_render_pending_images)

        draft.invalidate_recordset()
        self.assertEqual(draft.image_state, "pending")
        self.assertEqual(draft.image_render_attempts, 1)
        self.assertTrue(any("rendered 0/1" in line for line in output),
                        "a render that was not committed was counted:\n%s"
                        % "\n".join(output))
        self._warned(output, draft)

    def _render_losing_the_race(self, meanwhile=None):
        """One pending draft rendered by the cron, its first commit lost.

        The lost commit really undoes the work (back to a savepoint taken
        before the cron), as a lost commit does; clearing the cache alone
        would leave the row written and pass without the retry. `meanwhile`
        is the other writer's change, committed while the render ran.
        """
        Draft = self.env["assessments.be.prompt.question"]
        Draft.search([("image_state", "=", "pending")]).write(
            {"image_state": "failed"})
        draft = Draft.create({
            "prompt_id": self.generator.id, "name": "Draft",
            "question_type": "image_prompt", "image_state": "pending",
            "image_brief_json": '[{"slot": "single", "prompt": "a cat"}]'})
        image = {"slot": "single", "label": "",
                 "url": "https://example.com/cat.png"}
        self.env.flush_all()
        cr = self.env.cr
        cr.execute("SAVEPOINT race")
        lost, staged_keys = [], []

        def commit():
            self.env.flush_all()
            if not lost:
                lost.append(True)
                staged_keys.extend(prompt_mod._STAGED_RENDERS)
                cr.execute("ROLLBACK TO SAVEPOINT race")
                if meanwhile:
                    cr.clear()
                    meanwhile(draft)
                    self.env.flush_all()
                    cr.execute("RELEASE SAVEPOINT race")
                    cr.execute("SAVEPOINT race")
                raise SerializationFailure(
                    "could not serialize access due to concurrent update")
            cr.execute("RELEASE SAVEPOINT race")
            cr.execute("SAVEPOINT race")

        def rollback():
            cr.execute("ROLLBACK TO SAVEPOINT race")
            cr.clear()

        with self.enter_registry_test_mode(), \
                patch.object(cr, "commit", commit), \
                patch.object(cr, "rollback", rollback), \
                patch.object(vertex, "render_draft_images",
                             return_value=[image]) as paid, \
                self.assertLogs(_LOGGER, level=logging.INFO) as logs:
            Draft._cron_render_pending_images()

        draft.invalidate_recordset()
        self.assertEqual(lost, [True], "the race was never lost")
        self.assertEqual(paid.call_count, 1)
        self.assertIn((cr.dbname, draft.id), staged_keys,
                      "staged renders are keyed by database and draft")
        return draft, image, logs.output

    def test_a_paid_render_is_kept_through_the_race(self):
        """R10 (15 Oct): the render was paid for, so the lost commit is
        re-written once instead of re-paid next tick."""
        draft, image, output = self._render_losing_the_race()
        self.assertEqual(draft.image_state, "rendered")
        self.assertEqual(json.loads(draft.images_json), [image])
        self.assertTrue(any("kept the paid render through a lost race" in line
                            for line in output), "\n".join(output))
        self.assertTrue(any("rendered 1/1" in line for line in output),
                        "\n".join(output))

    def test_an_upload_committed_during_the_render_is_kept(self):
        """The replay overwrote an admin's upload that landed while Vertex
        was rendering; only a row still as the render found it is replayed."""
        png = base64.b64encode(b"\x89PNG\r\n\x1a\n admin").decode()

        def upload(draft):
            draft.write({"upload_image": png, "upload_slot": "single"})
            draft.action_apply_uploaded_image()

        draft, _image, output = self._render_losing_the_race(upload)
        self.assertEqual(draft.image_state, "uploaded")
        self.assertEqual([i["data"] for i in json.loads(draft.images_json)],
                         ["data:image/png;base64,%s" % png])
        self.assertFalse(any("kept the paid render" in line
                             for line in output), "\n".join(output))

    def test_a_brief_rewritten_during_the_render_is_not_overwritten(self):
        def rewrite(draft):
            draft.write({"image_brief_json":
                         '[{"slot": "single", "prompt": "a dog"}]'})

        draft, _image, output = self._render_losing_the_race(rewrite)
        self.assertEqual(draft.image_state, "pending")
        self.assertIn("a dog", draft.image_brief_json)
        self.assertFalse(draft.images_json and json.loads(draft.images_json))
        self.assertFalse(any("kept the paid render" in line
                             for line in output), "\n".join(output))

    def test_the_tag_extract_cron_requeues_the_generator(self):
        Prompt = self.env["assessments.be.prompt"]
        Prompt.search([("tag_extract_state", "in", ("queued", "generating"))]
                      ).write({"tag_extract_state": "done"})
        self.generator.write({"tag_extract_state": "queued"})

        def lose(env, prompt, **_kw):
            # The SOP-gen cron writes the same row after this one's
            # 'generating' commit, and this transaction loses to it.
            prompt.with_user(self.racer).sudo().write({"sop_title": "T"})
            self.env.flush_all()
            raise SerializationFailure(
                "could not serialize access due to concurrent update")

        with patch.object(vertex, "extract_tags_from_sop", side_effect=lose):
            output = self._run(Prompt._cron_extract_tags, commit_raises=False)

        self.generator.invalidate_recordset()
        self.assertEqual(self.generator.tag_extract_state, "queued")
        self.assertFalse(self.generator.tag_extract_error)
        self._warned(output, self.generator)

    def test_the_detect_cron_burns_no_attempt(self):
        Image = self.env["assessments.be.question.image"]
        Image.search([("question_type", "=", "image_label")]).write(
            {"detection_attempts": 3})
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6], "question_type": "image_label",
            "prompt": "Label it."})
        image = Image.create({
            "question_id": question.id, "label": "Plate", "slot": "single",
            "image_url": "https://example.com/plate.png"})
        image.with_user(self.racer).sudo().write({"label": "Plate 1"})

        with patch.object(type(Image), "_detect_and_annotate",
                          return_value=True):
            output = self._run(Image._cron_detect_image_labels)

        image.invalidate_recordset()
        self.assertEqual(image.detection_attempts, 0)
        self.assertTrue(any("annotated 0/1" in line for line in output),
                        "\n".join(output))
        self._warned(output, image)

    # ── The SOP-gen cron: every transient error, not only 40001 ──────────
    #
    # It re-queued a 40001 and marked the run `failed` on a deadlock (40P01),
    # a lock timeout (55P03) or the rest of the 40xxx class.

    def _sop_queued(self):
        Prompt = self.env["assessments.be.prompt"]
        Prompt.search([("sop_gen_state", "in", ("queued", "generating"))]
                      ).write({"sop_gen_state": "idle"})
        self.generator.write({"sop_gen_state": "queued"})
        return Prompt

    def test_the_sop_gen_cron_requeues_on_every_transient_error(self):
        for exc_class in (DeadlockDetected, LockNotAvailable,
                          SerializationFailure, TransactionRollbackError):
            with self.subTest(exc_class.__name__):
                Prompt = self._sop_queued()

                def lose(env, prompt, **_kw):
                    prompt.with_user(self.racer).sudo().write(
                        {"sop_title": "T"})
                    self.env.flush_all()
                    raise exc_class("lost a race")

                with patch.object(vertex, "generate_questions_from_sop",
                                  side_effect=lose):
                    output = self._run(Prompt._cron_generate_from_sop,
                                       commit_raises=False)

                self.generator.invalidate_recordset()
                self.assertEqual(self.generator.sop_gen_state, "queued")
                self.assertFalse(self.generator.sop_gen_error)
                self.assertFalse(self.generator.sop_gen_finished_at)
                self._warned(output, self.generator)

    def test_a_race_lost_after_the_drafts_are_committed_is_not_rerun(self):
        """`finalizing` means the drafts exist: re-queueing would send the SOP
        to Vertex again and duplicate them (H-8), so the row is left alone."""
        Prompt = self._sop_queued()
        generator = self.generator

        def lose(self_, prompt, draft_count, report=None):
            prompt.with_user(self.racer).sudo().write({"sop_title": "T"})
            self.env.flush_all()
            raise DeadlockDetected("deadlock detected")

        with patch.object(vertex, "generate_questions_from_sop",
                          return_value=[]) as generate, \
                patch.object(type(Prompt), "_finalize_sop_gen_state", lose):
            output = self._run(Prompt._cron_generate_from_sop,
                               commit_raises=False)

        generator.invalidate_recordset()
        self.assertEqual(generator.sop_gen_state, "finalizing")
        self.assertEqual(generate.call_count, 1)
        self._warned(output, generator)

    def test_the_finalize_retries_a_deadlock_in_place(self):
        """A deadlock on the verdict write is retried like a 40001, not raised
        on the first one."""
        cr = self.env.cr
        lost = []

        def commit():
            if not lost:
                lost.append(True)
                raise DeadlockDetected("deadlock detected")
            self.env.flush_all()

        self.generator.write({"sop_gen_state": "finalizing"})
        with patch.object(cr, "commit", commit), \
                patch.object(cr, "rollback", cr.clear), \
                patch("time.sleep"), \
                self.assertLogs(_LOGGER, level=logging.WARNING):
            self.env["assessments.be.prompt"]._finalize_sop_gen_state(
                self.generator, 1, report={})

        self.generator.invalidate_recordset()
        self.assertEqual(self.generator.sop_gen_state, "done")
