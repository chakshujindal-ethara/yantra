# -*- coding: utf-8 -*-
"""A COMPARISON'S JUSTIFICATION IS REQUIRED WHEN, AND ONLY WHEN, IT IS ASKED FOR.

THE SHAPE OF THE FEATURE. A side-by-side comparison scores on its VERDICT: the
candidate picks a side, that side is keyed on an option, and it is marked in
code. The written justification beside it is the examiner's choice, made with
Form Studio's "Require justification" switch. On, the candidate is shown the box
and must fill it; off, they never see it and the question is worth its verdict.

WHY THE GATE HAS TO EXIST AT ALL. Without it "require" was a label on nothing:
the box was shown, a mark was charged for it, and an empty one submitted
happily - so a candidate could be marked on prose they were never actually made
to write. `_record_response` is the one place a candidate's answer becomes
submitted, so it is where "required" has to mean something.

WHY IT HOLDS THE ANSWER RATHER THAN REFUSING IT. The verdicts ARE marks. Dropping
the row to punish an empty box would throw away answers the candidate had already
given, so the answer is parked as a DRAFT - the same mechanism an `image_prompt`
with unanswered checks already uses - and promoted the moment they type. That
also keeps the question out of `answered`, which is what makes the exam's own
"N unanswered" gate tell the truth about it.

WHAT MUST NOT BREAK, and each of these is asserted below:

  * A comparison with NO rationale must still submit on its verdict alone. The
    switch is off there, so demanding prose would refuse a paper the examiner
    deliberately authored as verdict-only - and refuse it over a box the
    candidate was never shown, which is unescapable from their side.
  * An EXPIRED attempt must still settle. `_auto_submit_expired` writes its own
    rows and never passes through this gate; if it did, a candidate who ran out
    of time on a required question could never have their paper closed.
  * The two runners must agree. The JSON API and the Odoo portal each have their
    own copy of this rule, so a divergence would ask two candidates sitting the
    same assessment for different things.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import serializers as S


@tagged("-at_install", "post_install")
class TestTheJustificationGate(TransactionCase):

    RATIONALE = "Left is sharper and its lighting follows the brief."

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.Dimension = self.env["assessments.be.question.dimension"]
        self.Response = self.env["assessments.be.response"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Comparison %s" % uuid4().hex[:6]})

    def _question(self, rationale=""):
        question = self.Question.create({
            "name": "Which render %s" % uuid4().hex[:6],
            "question_type": "image_ab",
            "prompt": "Pick the better render.",
            "official_reasoning": rationale or False,
            "generator_id": self.generator.id,
        })
        self.Dimension.create({
            "question_id": question.id,
            "name": "Overall Choice",
            "option_line_ids": [
                (0, 0, {"name": "Response A", "sequence": 10,
                        "is_correct": True}),
                (0, 0, {"name": "Response B", "sequence": 20}),
            ],
        })
        return question

    def _attempt(self, question):
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Candidate %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:8],
        })
        return self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": "[%d]" % question.id,
        })

    def _verdict(self, question):
        dimension = question.question_dimension_ids[0]
        return [(0, 0, {
            "question_dimension_id": dimension.id,
            "selected_option_id": dimension.option_line_ids[0].id,
        })]

    # -- what the server considers a complete answer --------------------
    #
    # `_record_response` needs a live HTTP request, so these exercise the RULE
    # it applies rather than the route around it: the same predicate the route
    # calls (`S.wants_justification`), and then the draft/submitted outcome the
    # route produces, written through the model exactly as it does.

    def test_the_switch_decides_whether_prose_is_wanted(self):
        self.assertTrue(S.wants_justification(self._question(self.RATIONALE)))
        self.assertFalse(S.wants_justification(self._question()))

    def test_a_required_justification_left_blank_is_not_a_complete_answer(self):
        """The gate's whole point: a verdict alone is NOT enough here."""
        question = self._question(self.RATIONALE)
        wants = S.wants_justification(question)
        justification = ""

        self.assertTrue(
            wants and not justification,
            "this is the state the route holds back as a draft")

    def test_the_verdict_survives_a_refusal_as_a_draft(self):
        """NOTHING THE CANDIDATE ALREADY ANSWERED MAY BE LOST.

        The route parks this row instead of dropping it, so the picked verdict
        is still there when they come back and type. A refusal that discarded
        it would cost them a mark they had earned, to punish a box they had
        not filled yet.
        """
        question = self._question(self.RATIONALE)
        evaluator = self._attempt(question)
        response = self.Response.create({
            "assessment_id": evaluator.assessment_id.id,
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": evaluator.applicant_id.id,
            "question_id": question.id,
            "justification": "",
            "line_ids": self._verdict(question),
        })

        self.assertEqual(
            response.state, "draft",
            "an incomplete answer is held, not submitted")
        self.assertTrue(
            response.line_ids,
            "the verdict the candidate picked must still be on the row")
        self.assertNotIn(
            question.id,
            self.Response.search([
                ("assessment_evaluator_id", "=", evaluator.id),
                ("state", "=", "submitted"),
            ]).mapped("question_id.id"),
            "a held answer must not count as answered")

    def test_typing_the_justification_completes_it(self):
        question = self._question(self.RATIONALE)
        evaluator = self._attempt(question)
        response = self.Response.create({
            "assessment_id": evaluator.assessment_id.id,
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": evaluator.applicant_id.id,
            "question_id": question.id,
            "justification": "",
            "line_ids": self._verdict(question),
        })
        response.write({"justification": "A is sharper throughout."})
        response.action_submit()

        self.assertEqual(response.state, "submitted")
        self.assertEqual(response.final_max, 2, "verdict plus justification")
        self.assertEqual(response.llm_max_score, 1)

    def test_a_comparison_that_asks_for_no_prose_submits_on_its_verdict(self):
        """THE OFF PATH, and the one that must never be caught by the gate.

        The candidate is shown no box at all here, so refusing them for an
        empty one would be a refusal they could not act on.
        """
        question = self._question()
        evaluator = self._attempt(question)
        response = self.Response.create({
            "assessment_id": evaluator.assessment_id.id,
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": evaluator.applicant_id.id,
            "question_id": question.id,
            "justification": "",
            "line_ids": self._verdict(question),
        })
        response.action_submit()

        self.assertFalse(S.wants_justification(question))
        self.assertEqual(response.state, "submitted")
        self.assertEqual(
            response.final_max, 1,
            "no box was asked for, so no mark may be charged for one")
        self.assertEqual(response.final_mark, 1.0)

    # -- the paths that must not be blocked -----------------------------

    def test_an_expired_attempt_still_settles_on_a_required_question(self):
        """AN EXPIRY MUST ALWAYS CLOSE THE PAPER.

        `_auto_submit_expired` writes its placeholder rows directly and never
        goes through the answer gate. Were it subject to this rule, a candidate
        whose clock ran out on a question demanding prose could never have
        their attempt settled - it would sit unsubmitted forever.
        """
        question = self._question(self.RATIONALE)
        evaluator = self._attempt(question)

        evaluator.sudo()._auto_submit_expired(reason_code="expired")

        response = self.Response.search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "=", question.id),
        ])
        self.assertEqual(len(response), 1)
        self.assertEqual(
            response.state, "submitted",
            "the expiry settlement must not be held back by the gate")
        self.assertTrue(response.auto_submitted)

    def test_a_held_draft_is_promoted_when_the_clock_runs_out(self):
        """A candidate who picked a verdict and never typed still gets their
        verdict marked at expiry, rather than losing the row entirely."""
        question = self._question(self.RATIONALE)
        evaluator = self._attempt(question)
        self.Response.create({
            "assessment_id": evaluator.assessment_id.id,
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": evaluator.applicant_id.id,
            "question_id": question.id,
            "justification": "",
            "line_ids": self._verdict(question),
        })

        evaluator.sudo()._auto_submit_expired(reason_code="expired")

        response = self.Response.search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "=", question.id),
        ])
        self.assertEqual(len(response), 1, "the draft was promoted, not duplicated")
        self.assertEqual(response.state, "submitted")
        self.assertTrue(
            response.line_ids, "the verdict they did pick is still marked")
        self.assertEqual(response.mcq_mark, 1.0)

    def test_the_runner_asks_the_shared_predicate(self):
        """THE RULE IS DERIVED, NEVER RE-DECIDED.

        This used to be `test_both_runners_apply_the_same_rule`, comparing the
        JSON API against the QWeb portal runner: each held its own copy of the
        completeness rule, they served the same assessments, and a box hidden in
        one runner and shown in the other is a defect the portal template's own
        comment recorded.

        The portal is retired, so there is one runner. The property worth keeping
        is not agreement between two copies - it is that the surviving one asks
        `serializers.wants_justification` rather than re-deriving the switch from
        the question type, which is how the second copy went wrong in the first
        place. A reader would otherwise verify that by eye.
        """
        import ast
        import inspect
        import textwrap

        from odoo.addons.assessments_be_v2.controllers.api import candidate

        # The core, where the rules live since `_record_response` became a
        # parse-and-delegate wrapper (Task 12). THE CALL, not the word: the
        # name also appears in a comment there, and a text match is also
        # satisfied by a trailing comment, a docstring or a string literal.
        # So the source is parsed and an actual `S.wants_justification(...)`
        # call node is required.
        tree = ast.parse(textwrap.dedent(inspect.getsource(
            candidate.EtpAssessmentApiCandidate._record_response_values)))
        calls = [
            node for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "wants_justification"
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "S"]
        self.assertTrue(
            calls,
            "the answer path must derive the justification switch from the "
            "shared predicate, not decide it locally")
