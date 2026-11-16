# -*- coding: utf-8 -*-
"""The question count and the ticked questions must not disagree.

Two halves of one complaint:

  * B - a launch refused with "Requested N but only M are servable" named no
    question, so the operator had to find the dropped ones by hand. It now
    names each ticked question the pool left out, and why.
  * C - an older client created an assessment with ticked questions and no
    count (or a count above the ticks), which only failed later, at launch.
    Create now takes the count from the ticks in both cases.
"""
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import tagged

from ..controllers.api import write as write_api
from ._paging_harness import call_route, status_of
from .test_a_blocked_launch_says_which_gate import _Base


@tagged("-at_install", "post_install")
class TestTheCountFollowsTheTickedQuestions(_Base):

    def _blank_plate(self, generator, name):
        """An image question with no image: the draw drops it."""
        return self.Question.create({
            "name": name, "question_type": "image_prompt",
            "prompt": "Write the prompt.", "generator_id": generator.id})

    # ── B: the refusal names what dropped ─────────────────────────────────

    def test_the_refusal_names_each_dropped_question_and_why(self):
        generator = self._generator()
        keeper = self._question(generator, "Keeper")
        blank = self._blank_plate(generator, "Blank plate")
        archived = self._question(generator, "Old one")
        assessment = self._draft(
            generator, question_limit=3,
            question_ids=[(6, 0, [keeper.id, blank.id, archived.id])])
        archived.active = False

        gate = self._launch(assessment)["error"]["message"]
        with self.assertRaises(UserError) as raised:
            assessment.action_start()

        for message in (gate, str(raised.exception)):
            with self.subTest(message=message):
                self.assertIn(
                    "Not servable: Blank plate (no image), Old one "
                    "(archived).", message)
                self.assertNotIn("Keeper", message)

    def test_a_long_list_stops_at_ten(self):
        generator = self._generator()
        blanks = [self._blank_plate(generator, "Blank %02d" % i)
                  for i in range(12)]
        assessment = self._draft(
            generator, question_ids=[(6, 0, [b.id for b in blanks])])

        note = assessment._dropped_shortlist_note(self.Question)

        self.assertEqual(note.count("(no image)"), 10)
        self.assertTrue(note.endswith(" +2 more."), note)

    def test_nothing_ticked_adds_nothing(self):
        assessment = self._draft(self._generator())
        self.assertEqual(
            assessment._dropped_shortlist_note(self.Question), "")

    # ── C: create takes the count from the ticks ──────────────────────────

    def _create(self, **params):
        response = call_route(
            write_api, write_api.EtpAssessmentApiWrite(), "assessment_create",
            self.env, name="Paper %s" % uuid4().hex[:6], **params)
        self.assertEqual(status_of(response), 200, response)
        return self.Assessment.browse(response["data"]["id"])

    def test_ticked_questions_set_a_missing_or_larger_count(self):
        generator = self._generator()
        ids = [self._question(generator, "Q%d" % i).id for i in range(3)]
        for sent, expected in ((None, 3), (0, 3), (10, 3), (2, 2)):
            with self.subTest(sent=sent):
                params = {"generator_id": generator.id, "question_ids": ids}
                if sent is not None:
                    params["question_limit"] = sent
                self.assertEqual(
                    self._create(**params).question_limit, expected)

    def test_nothing_ticked_keeps_the_count_sent(self):
        generator = self._generator()
        for ticked in (None, []):
            with self.subTest(ticked=ticked):
                params = {"generator_id": generator.id, "question_limit": 7}
                if ticked is not None:
                    params["question_ids"] = ticked
                self.assertEqual(self._create(**params).question_limit, 7)
