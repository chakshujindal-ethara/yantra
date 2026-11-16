"""A candidate added AFTER launch sits the paper the author arranged - SNo 103.

THE DEFECT. `action_start` honours `preserve_question_order` in both of its
branches. The late-add path in
`controllers/api/admin.py` did not: it called `random.shuffle(questions)`
unconditionally, so a candidate provisioned onto a RUNNING assessment was the one
person who got a shuffled paper.

WHY THAT MATTERS RATHER THAN BEING A CURIOSITY. The flag is set precisely when the
author's own sequence IS the instrument - a Form Studio publish sets it because the
examiner grouped items into sections and arranged them deliberately, and
`preserve_question_order`'s own field help says a shuffle "would silently discard
it". So the late candidate sat a structurally different exam from the cohort they
are compared against, and nothing anywhere said so.

REPRODUCED before fixing, on real data: assessment 5467 ("Customer Support QA
Certification (real bank)", preserve_question_order = True) has authored order
9587, 9588, 9589, ... and the late-add path produced 9590, 9601, 9594, ...

WHAT THESE TESTS PIN:
  * An ordered paper keeps its order for a late candidate, and it is the SAME
    order the cohort got - not merely "some deterministic order".
  * An UNORDERED paper still shuffles. The fix must not quietly turn every
    assessment into a fixed-order one, which would break the anti-collusion
    property shuffling exists for.
  * The shared draw read off the launch cohort is used as-is, whichever way
    the retired `same_questions_for_all` points (nothing reads it).
"""
import json

from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestALateCandidateSitsTheSamePaper(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Late add fixture %s" % uuid4().hex[:6]})
        # Ten questions with an explicit, meaningful sequence - the thing an
        # ordered paper is supposed to preserve.
        self.questions = self.Question.create([{
            "name": "Step %02d" % n,
            "question_type": "mcq",
            "prompt": "What comes after step %d?" % n,
            "sequence": n * 10,
            "generator_id": self.generator.id,
        } for n in range(1, 11)])
        for q in self.questions:
            self.env["assessments.be.question.dimension"].create({
                "question_id": q.id,
                "name": "Answer",
                "option_line_ids": [
                    (0, 0, {"name": "Right", "sequence": 10,
                            "is_correct": True}),
                    (0, 0, {"name": "Wrong", "sequence": 20,
                            "is_correct": False}),
                ],
            })

    def _assessment(self, *, preserve, same_for_all=False, state="in_progress"):
        asm = self.env["assessments.be"].create({
            "name": "Late add %s" % uuid4().hex[:5],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, self.questions.ids)],
            "question_limit": len(self.questions),
            "preserve_question_order": preserve,
            "same_questions_for_all": same_for_all,
        })
        asm.state = state
        return asm

    def _applicant(self, name):
        return self.env["hr.applicant"].create({"partner_name": name})

    def _late_add(self, asm, applicant):
        """Drive the ROUTE's own helper, not a reimplementation of it.

        The defect lived in this helper, so a test that recomputed the draw
        itself would pass against the bug. It is an unbound method on the
        controller class and touches no `request`, so it can be called directly
        with a bare instance - which keeps this a model-level test rather than
        one that has to stand up an HTTP session.
        """
        from odoo.addons.assessments_be_v2.controllers.api.admin import (
            EtpAssessmentApiAdmin,
        )
        # RETURNS (ids, refusals). The second half is the shortfall report added
        # when late-add stopped silently handing out shorter papers - see
        # `test_a_late_candidate_gets_a_full_paper`. This test is about the ORDER
        # of a full paper, so it takes the ids and ignores the refusals.
        provisioned, _refused = EtpAssessmentApiAdmin()._provision_late_candidates(
            asm, [applicant])
        return provisioned

    # ── an ordered paper stays ordered ────────────────────────────────

    def test_a_late_candidate_on_an_ordered_paper_keeps_the_order(self):
        """THE HEADLINE. The author's sequence is the instrument, so the late
        candidate must see it."""
        asm = self._assessment(preserve=True)
        applicant = self._applicant("Late Ordered Candidate")
        asm.evaluator_ids = [(4, applicant.id)]

        self._late_add(asm, applicant)

        row = self.env["assessments.be.evaluator"].search([
            ("assessment_id", "=", asm.id),
            ("applicant_id", "=", applicant.id),
        ], limit=1)
        self.assertTrue(row, "the late candidate must be provisioned")
        order = json.loads(row.question_order or "[]")
        self.assertEqual(
            order, self.questions.ids,
            "an ordered paper must reach a late candidate in the authored "
            "sequence - a shuffle here discards the sections the examiner "
            "arranged, for this candidate alone")

    def test_the_late_candidate_and_the_cohort_sit_the_same_order(self):
        """Not just "deterministic" - the SAME as everyone else's.

        A fix that produced a stable but different order would still put the
        late candidate on a different instrument from the cohort they are
        ranked against.
        """
        asm = self._assessment(preserve=True)
        early = self._applicant("Cohort Candidate")
        asm.evaluator_ids = [(4, early.id)]
        # Launch draws the cohort's order through action_start.
        asm.state = "draft"
        asm.action_start()

        late = self._applicant("Late Candidate")
        asm.evaluator_ids = [(4, late.id)]
        self._late_add(asm, late)

        rows = {
            r.applicant_id.id: json.loads(r.question_order or "[]")
            for r in asm.assessment_evaluator_ids
        }
        self.assertEqual(rows.get(late.id), rows.get(early.id),
                         "the late candidate must sit the cohort's paper")

    # ── an unordered paper still shuffles ─────────────────────────────

    def test_an_unordered_paper_is_still_shuffled(self):
        """THE NEGATIVE HALF, and the one that matters most.

        Shuffling exists so neighbouring candidates cannot read each other's
        screens in order. A fix that made every late add ordered would remove
        that silently for exactly the candidates provisioned last.

        Asserted over several candidates rather than one: any single draw can
        legitimately come out in sequence by chance (1 in 10! here, but a
        one-shot assertion would still be flaky in principle). At least one of
        five differing is what "is shuffled" actually means.
        """
        asm = self._assessment(preserve=False)
        orders = []
        for n in range(5):
            applicant = self._applicant("Unordered Candidate %d" % n)
            asm.evaluator_ids = [(4, applicant.id)]
            self._late_add(asm, applicant)
            row = self.env["assessments.be.evaluator"].search([
                ("assessment_id", "=", asm.id),
                ("applicant_id", "=", applicant.id),
            ], limit=1)
            orders.append(json.loads(row.question_order or "[]"))

        self.assertTrue(all(sorted(o) == sorted(self.questions.ids)
                            for o in orders),
                        "every candidate must get the whole paper")
        self.assertTrue(
            any(o != self.questions.ids for o in orders),
            "an unordered paper must still be shuffled for late candidates - "
            "that is what stops neighbours reading each other's screens")

    # ── the shared draw still wins ────────────────────────────────────

    def test_a_shared_paper_uses_the_cohort_draw_when_ordered(self):
        """A late candidate copies the launch cohort's order verbatim.
        `preserve_question_order` must not override that - the cohort's own
        draw IS the authored order on an ordered paper."""
        asm = self._assessment(preserve=True, same_for_all=True)
        early = self._applicant("Shared Cohort")
        asm.evaluator_ids = [(4, early.id)]
        asm.state = "draft"
        asm.action_start()
        cohort_order = json.loads(
            asm.assessment_evaluator_ids[:1].question_order or "[]")

        late = self._applicant("Shared Late")
        asm.evaluator_ids = [(4, late.id)]
        self._late_add(asm, late)

        row = self.env["assessments.be.evaluator"].search([
            ("assessment_id", "=", asm.id),
            ("applicant_id", "=", late.id),
        ], limit=1)
        self.assertEqual(json.loads(row.question_order or "[]"), cohort_order)

    def test_an_already_provisioned_candidate_is_not_redrawn(self):
        """A second late-add pass must not rewrite a paper somebody may already
        be sitting. `question_order` is what the exam paginates through, so
        changing it mid-sitting changes the exam under them."""
        asm = self._assessment(preserve=False)
        applicant = self._applicant("Already Provisioned")
        asm.evaluator_ids = [(4, applicant.id)]
        self._late_add(asm, applicant)
        row = self.env["assessments.be.evaluator"].search([
            ("assessment_id", "=", asm.id),
            ("applicant_id", "=", applicant.id),
        ], limit=1)
        first = row.question_order

        self._late_add(asm, applicant)
        row.invalidate_recordset()

        self.assertEqual(row.question_order, first,
                         "re-running the late add must not redraw a paper")
