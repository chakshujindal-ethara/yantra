""""Backfill onto questions" applies the generator's tags to its questions.

WHAT WAS BROKEN. The button existed, the route existed, and between them they
did nothing the label described. `/api/v1/generators/<id>/backfill_tags`
dispatched to `action_backfill_all_tags`, which is decorated `@api.model`: it
DISCARDS the recordset it is called on and instead searches every generator
with no tags at all, queueing tag EXTRACTION on them. So the button

  * touched no question, on any generator;
  * ignored the generator it was pressed from - the id was used only for the
    404 check;
  * and, because the client only renders it once a generator HAS tags, could
    not have acted on its own caller even if it had used the recordset.

Two features shared one method and neither of them was the one on the button.

`question.tag_ids` did not exist either, so there was nowhere for the tags to
land. That field and `action_backfill_tags_to_questions` are what this covers.

THE TWO RULES WORTH PINNING, because both are the kind that decay quietly:
a backfill UNIONS rather than replaces (a reviewer's hand-narrowed tag set is
an editorial decision, not drift to be flattened), and it is therefore
idempotent - the second run touches nothing.

TransactionCase rather than HttpCase, matching test_question_delete: the rule
under test is the model method the route delegates to, not the transport.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestBackfillTagsToQuestions(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Generator = self.env["assessments.be.prompt"]
        self.Question = self.env["assessments.be.question"]
        self.Tag = self.env["assessments.be.tag"]

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _tag(self, name):
        return self.Tag.create({"name": "%s-%s" % (name, uuid4().hex[:6])})

    def _generator(self, tags=None, name="Forklift SOP"):
        return self.Generator.create({
            "name": "%s %s" % (name, uuid4().hex[:6]),
            "tag_ids": [(6, 0, tags.ids)] if tags else False,
        })

    def _question(self, generator=None, name="Battery charging"):
        # `prompt` is required=True on the model - a question with no text is
        # not a question - so the fixture has to carry one.
        return self.Question.create({
            "name": "%s %s" % (name, uuid4().hex[:6]),
            "question_type": "mcq",
            "prompt": "What does the SOP require before charging a battery?",
            "generator_id": generator.id if generator else False,
        })

    # ------------------------------------------------------------------
    # The feature the button always claimed
    # ------------------------------------------------------------------
    def test_the_generators_tags_land_on_its_questions(self):
        tags = self._tag("domain:forklift") | self._tag("modality:image")
        generator = self._generator(tags=tags)
        q1 = self._question(generator)
        q2 = self._question(generator, name="Pedestrian crossing")

        generator.action_backfill_tags_to_questions()

        self.assertEqual(q1.tag_ids, tags)
        self.assertEqual(q2.tag_ids, tags)

    def test_it_is_scoped_to_the_generator_it_was_called_on(self):
        """The old dispatch searched the whole table. This one must not."""
        mine = self._generator(tags=self._tag("domain:forklift"))
        theirs = self._generator(tags=self._tag("domain:chemicals"))
        my_question = self._question(mine)
        their_question = self._question(theirs)

        mine.action_backfill_tags_to_questions()

        self.assertTrue(my_question.tag_ids)
        self.assertFalse(
            their_question.tag_ids,
            "another project's questions are not this button's business",
        )

    def test_an_orphan_question_is_untouched(self):
        generator = self._generator(tags=self._tag("domain:forklift"))
        orphan = self._question(generator=None)

        generator.action_backfill_tags_to_questions()

        self.assertFalse(orphan.tag_ids)

    # ------------------------------------------------------------------
    # The two rules that decay quietly
    # ------------------------------------------------------------------
    def test_a_hand_edited_tag_survives_the_backfill(self):
        """A UNION, never a replacement.

        A reviewer who added a tag by hand made an editorial decision, and a
        maintenance sweep that flattens it is worse than one that never runs.
        """
        from_sop = self._tag("domain:forklift")
        by_hand = self._tag("skill:hazard-spotting")
        generator = self._generator(tags=from_sop)
        question = self._question(generator)
        question.tag_ids = [(6, 0, by_hand.ids)]

        generator.action_backfill_tags_to_questions()

        self.assertIn(by_hand, question.tag_ids)
        self.assertIn(from_sop, question.tag_ids)

    def test_running_it_twice_changes_nothing(self):
        """Idempotent, which is what lets it be a plain button.

        An action that has to be pressed carefully is one that needs a
        confirmation sheet; this one does not, and that has to stay true.
        """
        generator = self._generator(tags=self._tag("domain:forklift"))
        question = self._question(generator)

        generator.action_backfill_tags_to_questions()
        first = question.tag_ids

        generator.action_backfill_tags_to_questions()

        self.assertEqual(question.tag_ids, first)

    # ------------------------------------------------------------------
    # Nothing to copy
    # ------------------------------------------------------------------
    def test_an_untagged_generator_says_so_rather_than_failing(self):
        """The order of operations, stated to whoever pressed too early.

        Extraction fills the generator; this copies it down. Reversing them is
        the obvious mistake, and "nothing happened" is not a useful answer to
        it.
        """
        generator = self._generator()
        question = self._question(generator)

        result = generator.action_backfill_tags_to_questions()

        self.assertFalse(question.tag_ids)
        self.assertIn("Extract skills", result["params"]["message"])
        self.assertEqual(result["params"]["type"], "warning")

    def test_a_retired_question_is_still_backfilled(self):
        """Retirement takes a question out of the BANK, not out of history.

        It can be restored, and a restored question that is the only untagged
        row in the bank is a confusing thing to have to explain.
        """
        generator = self._generator(tags=self._tag("domain:forklift"))
        question = self._question(generator)
        question.retired = True

        generator.action_backfill_tags_to_questions()

        self.assertTrue(question.tag_ids)

    # ------------------------------------------------------------------
    # The route
    # ------------------------------------------------------------------
    def test_the_route_points_at_the_per_generator_action(self):
        """The regression itself: which method the endpoint dispatches to.

        Read as source rather than exercised over HTTP, because the bug was a
        one-word mismatch between the route and the model - both halves worked
        perfectly, at different features.
        """
        import inspect

        from odoo.addons.assessments_be_v2.controllers.api import write

        source = inspect.getsource(write.EtpAssessmentApiWrite
                                   .generator_backfill_tags)
        self.assertIn("action_backfill_tags_to_questions", source)
        self.assertNotIn(
            '_sop_action(generator_id, "action_backfill_all_tags")',
            source,
            "that is the @api.model sweep; it ignores the generator",
        )
