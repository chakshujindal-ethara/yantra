# -*- coding: utf-8 -*-
"""`shuffle_questions` is the operator's view of `preserve_question_order`.

WHY THIS FILE EXISTS. The stored field is `preserve_question_order`, and it was
never serialized and never writable over the API - so the operator's config
screen could neither show the current setting nor change it, and a paper was
shuffled or not with nothing on the wire saying which. The screen asks the
affirmative question ("shuffle the questions?"), so the API exposes the field
as its inverse rather than shipping a double-negative nobody reads correctly.

The alias is exact inversion, so the round trip is what has to be pinned: a
`shuffle_questions` sent in must come back the negation of what was stored, and
the stored column must be the negation of what was sent. Asserting only one
direction would pass while the inversion silently dropped a `not`.

WHY IT DRIVES THE ROUTE'S OWN HELPER. `_apply_shuffle_alias` is the exact hook
the create/update routes call to fold the payload key onto the field; the
serializer is the exact function the config screen reads. Exercising those two
against a real record is the round trip without binding a full HTTP request
stub - the alias logic under test is the shipped code, unmodified. NO schema
change: `preserve_question_order` is the single source of truth.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import serializers as S
from odoo.addons.assessments_be_v2.controllers.api.write import (
    _apply_shuffle_alias,
)


@tagged("-at_install", "post_install")
class TestShuffleQuestionsAlias(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Shuffle fixture %s" % uuid4().hex[:6]})

    def _write_values(self, **payload):
        """What the route builds: the picked field map with the alias folded in.

        The route runs `_picked(ASSESSMENT_FIELDS)` then `_apply_shuffle_alias`;
        the alias reads the raw payload through `arg`/`bool_arg`, so a request
        with `params` is bound for the fold, matching how the route runs.
        """
        from unittest.mock import patch
        from odoo.addons.assessments_be_v2.controllers.api import common as CM

        class _Req:
            params = dict(payload)

        values = {}
        with patch.object(CM, "request", _Req()):
            _apply_shuffle_alias(values)
        return values

    def _create(self, name, **payload):
        values = self._write_values(**payload)
        values["name"] = name
        record = self.Assessment.create(dict(values, generator_id=self.generator.id))
        return record

    # ------------------------------------------------------------------
    # The inversion, both directions
    # ------------------------------------------------------------------
    def test_shuffle_false_persists_preserve_true_and_reads_back_false(self):
        values = self._write_values(shuffle_questions=False)
        self.assertEqual(
            values, {"preserve_question_order": True},
            "shuffle_questions:false must fold to preserve_question_order=True")

        record = self._create("No shuffle", shuffle_questions=False)
        self.assertTrue(record.preserve_question_order)
        self.assertFalse(
            S.assessment_detail(record)["shuffle_questions"],
            "the serializer must echo the alias the operator sent")

    def test_shuffle_true_persists_preserve_false_and_reads_back_true(self):
        values = self._write_values(shuffle_questions=True)
        self.assertEqual(values, {"preserve_question_order": False})

        record = self._create("Shuffle", shuffle_questions=True)
        self.assertFalse(record.preserve_question_order)
        self.assertTrue(S.assessment_detail(record)["shuffle_questions"])

    def test_update_flips_the_field_both_ways(self):
        record = self._create("Flip", shuffle_questions=True)
        self.assertFalse(record.preserve_question_order)

        record.write(self._write_values(shuffle_questions=False))
        self.assertTrue(record.preserve_question_order)
        self.assertFalse(S.assessment_detail(record)["shuffle_questions"])

        record.write(self._write_values(shuffle_questions=True))
        self.assertFalse(record.preserve_question_order)
        self.assertTrue(S.assessment_detail(record)["shuffle_questions"])

    def test_an_absent_key_touches_nothing(self):
        """The partial-update contract: an update that never names the alias
        must produce no write for the ordering field."""
        self.assertEqual(
            self._write_values(name="rename only"), {},
            "a payload without shuffle_questions must not write "
            "preserve_question_order at all")

    def test_detail_always_carries_the_alias(self):
        record = self.Assessment.create(
            {"name": "Default", "generator_id": self.generator.id})
        data = S.assessment_detail(record)
        self.assertIn("shuffle_questions", data)
        self.assertEqual(
            data["shuffle_questions"], not record.preserve_question_order)


@tagged("-at_install", "post_install")
class TestTheOdooFormMirror(TransactionCase):
    """The same inversion again, for the ODOO FORM rather than the wire.

    WHY THIS EXISTS SEPARATELY FROM THE CLASS ABOVE. The alias above is a
    function the HTTP routes call; an Odoo form cannot call it, so the form got
    `shuffle_questions` as a computed, non-stored Boolean with an inverse
    setter. Both consoles now say "Shuffle Questions" and both fold onto the one
    stored column, but they get there through completely different code, so the
    round trip has to be pinned twice or the form half can invert wrongly while
    the wire half stays green.

    THE THIRD TEST IS THE ONE THAT MATTERS MOST. A mirror is only safe while
    nothing READS it: `action_start` decides each candidate's paper from
    `preserve_question_order`, and a future refactor that "tidied" that branch
    to read the friendlier `shuffle_questions` name would flip every paper's
    order without touching a line of the form. That is exactly the class of
    defect this whole arrangement exists to prevent, so it is asserted from the
    outside - launch a real cohort and look at what was actually served.
    """

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Mirror fixture %s" % uuid4().hex[:6]})
        # TEN questions with explicit, spaced sequences. `_order` on the bank is
        # "sequence, id", so this fixture has ONE unambiguous bank order, and a
        # shuffle has a 1-in-10! chance of reproducing it by accident - small
        # enough that "came back in bank order" is evidence and not luck.
        self.questions = self.env["assessments.be.question"]
        for n in range(1, 11):
            self.questions |= self._question(n)

    def _question(self, n):
        question = self.env["assessments.be.question"].create({
            "name": "Mirror Q%02d %s" % (n, uuid4().hex[:4]),
            "question_type": "mcq",
            "prompt": "Pick one.",
            "sequence": n * 10,
            "generator_id": self.generator.id,
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": question.id,
            "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": "Alpha", "sequence": 10, "is_correct": True}),
                (0, 0, {"name": "Bravo", "sequence": 20, "is_correct": False}),
            ],
        })
        return question

    # ------------------------------------------------------------------
    # the mirror reads the stored field
    # ------------------------------------------------------------------
    def test_the_mirror_reads_the_stored_field_both_ways(self):
        record = self.Assessment.create({
            "name": "Reads %s" % uuid4().hex[:5],
            "generator_id": self.generator.id,
            "preserve_question_order": True,
        })
        self.assertFalse(
            record.shuffle_questions,
            "keeping the authored order means NOT shuffling")

        record.preserve_question_order = False
        self.assertTrue(
            record.shuffle_questions,
            "the mirror must follow a write to the stored field, or the form "
            "shows a stale answer to the question the column already settled")

    # ------------------------------------------------------------------
    # the mirror writes the stored field
    # ------------------------------------------------------------------
    def test_the_mirror_writes_the_stored_field_both_ways(self):
        record = self.Assessment.create({
            "name": "Writes %s" % uuid4().hex[:5],
            "generator_id": self.generator.id,
        })

        record.shuffle_questions = False
        self.assertTrue(
            record.preserve_question_order,
            "unticking Shuffle Questions on the form must set the stored "
            "'keep the authored order' flag")

        record.shuffle_questions = True
        self.assertFalse(record.preserve_question_order)

    def test_creating_through_the_mirror_lands_on_the_stored_field(self):
        """A create, not a write - the inverse has to run on both paths."""
        record = self.Assessment.create({
            "name": "Created %s" % uuid4().hex[:5],
            "generator_id": self.generator.id,
            "shuffle_questions": False,
        })
        self.assertTrue(record.preserve_question_order)

    # ------------------------------------------------------------------
    # the defaults the Flutter client would have sent
    # ------------------------------------------------------------------
    def test_a_bare_create_matches_the_flutter_defaults(self):
        """What a NEW assessment is, on both consoles, with nothing chosen.

        The values are the Flutter create screen's own initial state
        (new_assessment_screen.dart: `_shuffleQuestions = true`,
        `_autoScore = false`), plus the retired `same_questions_for_all`
        column's default, True, which nothing reads now. An Odoo create that
        names none of the three must land on the same stored values the client
        would have posted - otherwise the console an assessment was created on
        silently decides how it is drawn and graded.
        """
        record = self.Assessment.create({
            "name": "Bare %s" % uuid4().hex[:5],
            "generator_id": self.generator.id,
        })
        self.assertTrue(
            record.same_questions_for_all,
            "Flutter opens 'Same questions for everybody' ON")
        self.assertTrue(
            record.shuffle_questions,
            "Flutter opens 'Shuffle Questions' ON")
        self.assertFalse(
            record.preserve_question_order,
            "shuffle on is stored as preserve_question_order off")
        self.assertFalse(
            record.llm_auto_score,
            "Flutter opens 'Grade subjective answers automatically' OFF")

    # ------------------------------------------------------------------
    # nothing downstream may read the mirror
    # ------------------------------------------------------------------
    def _launch(self, *, shuffle, candidates=2):
        """A real cohort, launched, with the order chosen THROUGH THE MIRROR.

        Going in through `shuffle_questions` is the point: it proves the value
        an operator sets on the form reaches the draw, and it leaves
        `action_start` reading only the stored field.
        """
        applicants = self.env["hr.applicant"]
        for _ in range(candidates):
            applicants |= self.env["hr.applicant"].create({
                "partner_name": "Mirror Cand %s" % uuid4().hex[:6],
                "email_from": "mir_%s@example.com" % uuid4().hex[:8],
            })
        assessment = self.Assessment.create({
            "name": "Launch %s" % uuid4().hex[:5],
            "generator_id": self.generator.id,
            "duration_minutes": 30,
            "question_ids": [(6, 0, self.questions.ids)],
            "question_limit": len(self.questions),
            "shuffle_questions": shuffle,
            "evaluator_ids": [(6, 0, applicants.ids)],
        })
        assessment.action_start()
        return [
            [int(q) for q in json.loads(row.question_order or "[]")]
            for row in assessment.assessment_evaluator_ids
        ]

    def test_action_start_branches_on_the_stored_field_not_the_mirror(self):
        """Shuffle OFF on the form must serve the bank order, unshuffled.

        Read the mirror here instead of `preserve_question_order` and the two
        branches invert: shuffle_questions is False, so the `elif` falls through
        to random.sample and `if not ...` shuffles what it drew. The served
        paper would come back in a random order and this assertion is what
        catches it.
        """
        served = self._launch(shuffle=False)
        self.assertTrue(served, "fixture: two candidates were provisioned")
        for order in served:
            self.assertEqual(
                order, self.questions.ids,
                "with Shuffle Questions off every candidate must sit the bank "
                "order - a shuffle here means a reader switched from "
                "preserve_question_order to its mirror")

    def test_shuffle_on_still_reaches_the_draw(self):
        """The other half, so the test above cannot pass by the draw being
        hard-wired to bank order.

        Not "the order is random" - a shuffle is allowed to return the bank
        order by chance. What is pinned is the STORED consequence of ticking
        the box, which is the seam the mirror owns.
        """
        assessment = self.Assessment.create({
            "name": "Shuffled %s" % uuid4().hex[:5],
            "generator_id": self.generator.id,
            "shuffle_questions": True,
        })
        self.assertFalse(
            assessment.preserve_question_order,
            "ticking Shuffle Questions must clear the stored keep-order flag, "
            "which is the only thing action_start looks at")
