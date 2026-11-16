"""A paper with nothing to answer is reported as broken, never as finished.

THE DEFECT (P-7). `_question_payload` answered the `complete` gate whenever the
live question order came back empty:

    order = self._live_order(evaluator)
    if not order:
        return S.exam_state_envelope(GATE_COMPLETE, evaluator, ...)

`_live_order` drops ids whose question has since been deleted, so an empty order
means one of two real situations:

  * the paper was launched with no questions at all, or
  * every question was deleted under a candidate who was mid-sitting.

Either way the candidate was shown the finished screen for an exam they never
saw a single item of, and the attempt then scores zero off zero answers. On the
dashboard that row is indistinguishable from a candidate who sat the paper and
got everything wrong - the same shape of defect as D-5, where a missing score
became a real zero. `etp_local` carried 5 such attempts.

WHY `closed` IS THE RIGHT GATE. `GateScreen` renders from `kind` alone and its
`closed` copy is "the link is valid but the assessment is not currently
running" - honest for a broken paper, and critically it does NOT tell the
candidate they finished. `complete` is the only outcome that makes a false
claim about the candidate's own work, which is what made this worth fixing.

THE CARVE-OUT THAT MATTERS. A candidate who has ALREADY ANSWERED still
completes. They did the work; questions being deleted afterwards must not
retract it. `test_a_candidate_who_answered_still_completes` pins that, and it is
the assertion that would fail if someone "simplified" the fix to a bare
`if not order: closed`.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import candidate as cand_api


class _StubRequest:
    """The slice of `odoo.http.request` `_question_payload` touches.

    It reads `request.env` only - to resolve live question ids and to look up
    the candidate's stored responses. A stub keeps this a TransactionCase,
    matching `test_authored_question_marks` and the rest of the house.
    """

    def __init__(self, env):
        self.env = env
        self.params = {}


@tagged("-at_install", "post_install")
class TestAnEmptyPaperIsBrokenNotFinished(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Generator = self.env["assessments.be.prompt"]
        self.controller = cand_api.EtpAssessmentApiCandidate()

    # ── fixtures ──────────────────────────────────────────────────────

    def _question(self, gen, i=0):
        q = self.Question.create({
            "name": "Q%d %s" % (i, uuid4().hex[:4]),
            "question_type": "mcq",
            "prompt": "Pick one",
            "difficulty": "easy",
            "generator_id": gen.id,
        })
        self.QDim.create({
            "question_id": q.id,
            "name": "Dim %d" % i,
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": j * 10, "is_correct": j == 0})
                for j, n in enumerate(("Alpha", "Bravo"))
            ],
        })
        return q

    def _sitting(self, question_count=2, order_override=None):
        """A launched, started sitting with `question_count` real questions."""
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        questions = [self._question(gen, i) for i in range(question_count)]
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:4],
            "email_from": "c_%s@example.com" % uuid4().hex[:8],
        })
        assessment = self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": gen.id,
            "question_ids": [(6, 0, [q.id for q in questions])],
        })
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": order_override if order_override is not None
            else "[%s]" % ", ".join(str(q.id) for q in questions),
        })
        return assessment, evaluator, questions

    def _payload(self, evaluator):
        """`_question_payload` with `request` stubbed - the real code path."""
        stub = _StubRequest(self.env)
        with patch.object(cand_api, "request", stub):
            return self.controller._question_payload(
                evaluator, evaluator.access_token)

    # ── the fixture must really produce an empty order ────────────────

    def test_the_fixture_reproduces_a_healthy_paper(self):
        """GUARD THE GUARD. If the fixture stopped producing a servable
        question, 'closed' below would pass for the wrong reason."""
        _, evaluator, _ = self._sitting(question_count=2)
        out = self._payload(evaluator)
        self.assertEqual(
            out.get("outcome"), "question",
            "a paper with live questions must serve one; got %r" % (out,))

    def test_a_deleted_question_really_leaves_the_order_empty(self):
        """The mechanism the defect rides on: `_live_order` drops dead ids."""
        _, evaluator, questions = self._sitting(question_count=1)
        for q in questions:
            q.unlink()
        stub = _StubRequest(self.env)
        with patch.object(cand_api, "request", stub):
            self.assertEqual(
                self.controller._live_order(evaluator), [],
                "a deleted question must drop out of the live order")

    # ── the fix ───────────────────────────────────────────────────────

    def test_a_paper_launched_with_no_questions_is_closed_not_complete(self):
        """THE HEADLINE. An empty draw is a broken paper."""
        _, evaluator, _ = self._sitting(question_count=0, order_override="[]")

        out = self._payload(evaluator)

        self.assertNotEqual(
            out.get("outcome"), "complete",
            "a candidate shown no questions must not be told they finished")
        self.assertEqual(out.get("outcome"), "closed")

    def test_every_question_deleted_mid_sitting_is_closed_too(self):
        """The other route to an empty order, and the likelier one in practice:
        an author tidying the bank under a live cohort."""
        _, evaluator, questions = self._sitting(question_count=2)
        for q in questions:
            q.unlink()

        out = self._payload(evaluator)

        self.assertEqual(out.get("outcome"), "closed")
        self.assertNotEqual(out.get("outcome"), "complete")

    def test_the_reason_tells_the_candidate_it_is_not_their_fault(self):
        """An exam screen that blames the candidate for a broken paper is the
        part that actually costs trust."""
        _, evaluator, _ = self._sitting(question_count=0, order_override="[]")

        reason = (self._payload(evaluator).get("reason") or "").lower()

        self.assertTrue(reason, "a closed paper must say why")
        self.assertIn("no questions", reason)
        self.assertIn("marked you down", reason,
                      "it must say the candidate has not been penalised")

    # ── the carve-out: answered work is never retracted ───────────────

    def test_a_candidate_who_answered_still_completes(self):
        """THE GUARD ON THE FIX.

        A candidate whose order is empty but who HAS answers did the work, and
        their attempt is finished. Reporting `closed` here would tell someone
        who sat the paper that it never opened - and this is the assertion that
        fails if the fix is flattened to a bare `if not order: closed`.

        THE EMPTY ORDER IS REACHED BY CLEARING `question_order`, NOT BY
        DELETING THE QUESTION, and that distinction is the whole reason this
        test reads the way it does. `response.question_id` is
        ondelete="cascade" (models/assessment.py:3200), so deleting a question
        DESTROYS the answers to it: an earlier version of this test deleted the
        question and then asserted the answer still counted, which is a state
        that cannot physically exist. Measured on a clone - a scored response
        carrying a released 91.0 mark was erased by the unlink, leaving the
        sitting `submitted` with zero answers.

        Clearing the order is a real and reachable state (verified: question
        survives, answer survives, order reads `[]`), and it is the one that
        exercises this branch honestly.
        """
        _, evaluator, questions = self._sitting(question_count=1)
        self.env["assessments.be.response"].create({
            "assessment_id": evaluator.assessment_id.id,
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": evaluator.applicant_id.id,
            "question_id": questions[0].id,
            "justification": "A real answer that was really given.",
            "state": "submitted",
        })
        evaluator.write({"question_order": "[]"})

        out = self._payload(evaluator)

        self.assertEqual(
            out.get("outcome"), "complete",
            "answered work must not be retracted by an empty order")
