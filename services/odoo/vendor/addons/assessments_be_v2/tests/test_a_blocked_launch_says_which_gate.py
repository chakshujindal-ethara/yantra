# -*- coding: utf-8 -*-
"""A refused launch has to name what refused it, and the record that caused
Sprint 3A's refusal has to be impossible to save in the first place.

Two fixes, one story. Assessment 55 pointed at generator 46 and carried a
shortlist of questions owned by generator 47. `action_start` builds the pool
from the generator and then narrows it by the shortlist, so the intersection was
empty and the launch was refused. Both halves of that were wrong for the
operator:

  * The refusal said "2 launch gate(s) failed" and stopped, while holding the
    label and reason of each one. The only way to learn which two was to read
    the database.
  * The record had been saveable in that state for as long as it existed. The
    mistake was made by duplicating an assessment and changing its generator,
    and nothing objected at the moment it was still one undo away.

So: the message names the gates, and the write refuses the mismatch.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import ValidationError
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import admin as admin_api
from odoo.addons.assessments_be_v2.controllers.api import common as api_common


class _StubRequest:
    """The slice of `odoo.http.request` the launch route touches."""

    def __init__(self, env, params=None):
        self.env = env
        self.params = dict(params or {})

    def make_json_response(self, payload, headers=None, status=200):
        return dict(payload, _status=status)


class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Generator = self.env["assessments.be.prompt"]
        self.env.ref(
            "assessments_be_v2.group_assessment_manager"
        ).sudo().write({"user_ids": [(4, self.env.user.id)]})

    def _generator(self, label="Gen"):
        return self.Generator.create(
            {"name": "%s %s" % (label, uuid4().hex[:6])})

    def _question(self, generator, name):
        """A KEYED mcq, so no fixture trips the answer-key gate and a failure
        here can only be about the thing under test."""
        question = self.Question.create({
            "name": name,
            "question_type": "mcq",
            "prompt": "Pick one.",
            "generator_id": generator.id,
        })
        self.QDim.create({
            "question_id": question.id,
            "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": opt, "sequence": i * 10, "is_correct": i == 0})
                for i, opt in enumerate(("Alpha", "Bravo"))
            ],
        })
        return question

    def _applicant(self):
        slug = uuid4().hex[:8]
        return self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % slug,
            "email_from": "cand_%s@example.com" % slug,
        })

    def _draft(self, generator, **vals):
        values = {
            "name": "Sprint %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "duration_minutes": 30,
            "evaluator_ids": [(6, 0, [self._applicant().id])],
        }
        values.update(vals)
        assessment = self.Assessment.create(values)
        assessment._sync_roster_rows()
        assessment.invalidate_recordset()
        return assessment

    def _launch(self, assessment, confirm=True):
        stub = _StubRequest(self.env, {"assessment_id": assessment.id,
                                       "confirm": confirm})
        controller = admin_api.EtpAssessmentApiAdmin()
        with patch.object(admin_api, "request", stub), \
                patch.object(api_common, "request", stub):
            return controller.assessment_launch(assessment.id)


@tagged("-at_install", "post_install")
class TestABlockedLaunchNamesTheGates(_Base):

    def _refusal(self):
        """A draft refused by exactly one gate: nobody is assigned."""
        generator = self._generator()
        self._question(generator, "Q %s" % uuid4().hex[:4])
        assessment = self._draft(generator)
        assessment.assessment_evaluator_ids.unlink()
        assessment.write({"evaluator_ids": [(5, 0, 0)]})
        assessment.invalidate_recordset()
        return self._launch(assessment)

    def test_the_message_names_the_gate_instead_of_counting_it(self):
        answer = self._refusal()

        message = answer["error"]["message"]
        self.assertNotIn(
            "launch gate(s) failed", message,
            "counting the gates is the defect: the operator cannot act on "
            "a number, and the reasons were already computed")
        self.assertIn(
            "candidate", message.lower(),
            "the failing gate must be named in the message the client toasts; "
            "got %r" % (message,))

    def test_the_message_carries_the_gate_s_own_reason(self):
        """The label says WHICH check; the reason says what it found. A label
        alone sends the operator to the right screen and no further."""
        answer = self._refusal()
        message = answer["error"]["message"]

        gate = next(g for g in answer["gates"] if g["code"] == "candidates")
        self.assertIn(gate["label"], message)
        self.assertIn(gate["reason"], message)

    def test_failed_gates_is_still_a_list_of_codes(self):
        """Prose is for people. A client branching on the refusal reads codes,
        and must not be made to parse the message to do it."""
        answer = self._refusal()

        self.assertEqual(answer["failed_gates"], ["candidates"])
        self.assertTrue(
            all(isinstance(code, str) for code in answer["failed_gates"]))

    def test_every_gate_is_still_returned_passing_ones_too(self):
        answer = self._refusal()

        self.assertGreaterEqual(len(answer["gates"]), 6)
        self.assertTrue(any(g["passed"] for g in answer["gates"]),
                        "the full verdict list is what the launch sheet renders")

    def test_a_launch_that_passes_is_untouched(self):
        generator = self._generator()
        self._question(generator, "Q %s" % uuid4().hex[:4])
        assessment = self._draft(generator)

        answer = self._launch(assessment)

        self.assertTrue(answer.get("ok"), "got %r" % (answer,))
        self.assertTrue(answer["data"]["launched"])


@tagged("-at_install", "post_install")
class TestAShortlistCannotPointAtAnotherGenerator(_Base):
    """Sprint 3A's record shape, refused at the write."""

    def test_a_question_from_another_generator_is_refused(self):
        mine, theirs = self._generator("Mine"), self._generator("Theirs")
        ours = self._question(mine, "Ours")
        foreign = self._question(theirs, "Foreign")
        assessment = self._draft(mine)

        with self.assertRaises(ValidationError) as caught:
            assessment.write({"question_ids": [(6, 0, [ours.id, foreign.id])]})

        self.assertIn("Foreign", str(caught.exception),
                      "the message must name the offending question - a count "
                      "leaves the operator hunting through the tick list")

    def test_changing_the_generator_under_a_shortlist_is_refused(self):
        """How it actually happened: duplicate an assessment, then repoint it."""
        mine, theirs = self._generator("Mine"), self._generator("Theirs")
        ours = self._question(mine, "Ours")
        assessment = self._draft(mine, question_ids=[(6, 0, [ours.id])])

        with self.assertRaises(ValidationError):
            assessment.write({"generator_id": theirs.id})

    def test_an_empty_shortlist_stays_valid(self):
        """It means "the whole generator" everywhere else in this module, and
        it is the normal case. A constraint that refused it would refuse every
        assessment nobody has ticked."""
        mine = self._generator("Mine")
        self._question(mine, "Ours")
        assessment = self._draft(mine)

        assessment.write({"question_ids": [(5, 0, 0)]})

        self.assertFalse(assessment.question_ids)

    def test_an_assessment_with_no_generator_is_left_alone(self):
        assessment = self.Assessment.create({
            "name": "No generator %s" % uuid4().hex[:6],
            "duration_minutes": 30,
        })

        self.assertFalse(assessment.generator_id)

    def test_repointing_the_generator_at_the_shortlist_s_owner_is_allowed(self):
        """The repair path has to work, or the constraint traps the record it
        is complaining about."""
        mine, theirs = self._generator("Mine"), self._generator("Theirs")
        ours = self._question(mine, "Ours")
        assessment = self._draft(mine, question_ids=[(6, 0, [ours.id])])

        theirs_question = self._question(theirs, "Theirs Q")
        assessment.write({"generator_id": theirs.id,
                          "question_ids": [(6, 0, [theirs_question.id])]})

        self.assertEqual(assessment.generator_id, theirs)

    def test_an_archived_foreign_question_is_still_caught(self):
        """An archived question drops out of the m2m read. Without
        `active_test=False` the one check meant to catch a foreign question
        would be blind to exactly the ones nobody is looking at."""
        mine, theirs = self._generator("Mine"), self._generator("Theirs")
        foreign = self._question(theirs, "Foreign")
        assessment = self._draft(mine)
        foreign.active = False

        with self.assertRaises(ValidationError):
            assessment.write({"question_ids": [(6, 0, [foreign.id])]})

    def test_launching_does_not_trip_the_constraint(self):
        """`action_start` writes `question_ids` itself. It draws from the
        generator, so the set it writes is always its own - but this is the
        test that says so, because a launch refused by this constraint would be
        the constraint causing the outage it was built to prevent."""
        mine = self._generator("Mine")
        self._question(mine, "A")
        self._question(mine, "B")
        assessment = self._draft(mine)

        answer = self._launch(assessment)

        self.assertTrue(answer.get("ok"), "got %r" % (answer,))
        self.assertTrue(assessment.question_ids)
        self.assertEqual(assessment.question_ids.generator_id, mine)
