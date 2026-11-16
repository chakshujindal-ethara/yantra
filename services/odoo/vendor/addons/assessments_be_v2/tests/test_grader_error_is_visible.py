# -*- coding: utf-8 -*-
"""A grader error says WHY, not only that it happened.

THE DEFECT, found by walking the deployed stage build.

Stage showed "42 answer(s) hit a terminal grader error. These never retry on
their own ... Recovery is manual" beside a red "Scoring error" pill - and the
reason was invisible on every one of the 42. An operator deciding whether to
press Re-score could not tell a bad credential (pressing it again fails the same
way) from a transient timeout (pressing it works) from a malformed rubric
(pressing it never works until the question is fixed).

WHERE THE REASON ACTUALLY LIVES, and the trap this locks down.
`services.scoring._store_error` writes it to **`llm_feedback` on the response**.
There IS an `llm_error` field, but it is on `assessments.be.evaluator` - the
ATTEMPT - and it is a different value with a different lifecycle. The client's
`Response.llmError` therefore read a key no response row ever sent: a field that
parsed, compiled, and was always null. Reading the plausibly-named field instead
of the one the writer uses is exactly how this stayed invisible.

`response_row` is the shape the Responses table, its filters and its KPI tiles
are all built from, so the diagnostic has to be HERE - not only on a detail
route - or the table cannot show it.

ONLY ON THE FAILURE STATES, asserted below. `llm_feedback` doubles as the
judge's prose for a SCORED answer (the audit sheet renders that in full), and
leaking a compliment into a cell headed "Scoring" as though it were an error
would be a new defect, not a fix.
"""
from odoo.tests.common import TransactionCase

from odoo.addons.assessments_be_v2.controllers.api import serializers as S

# What `_store_error` really writes, suffix and all.
REASON = ("Vertex 429: quota exhausted."
          " (surfaced as a scoring error after 3 attempts)")


class TestGraderErrorIsVisible(TransactionCase):

    def setUp(self):
        super().setUp()
        generator = self.env["assessments.be.prompt"].create({"name": "Gen"})
        self.assessment = self.env["assessments.be"].create({
            "name": "Grader error probe",
            "generator_id": generator.id,
        })
        self.question = self.env["assessments.be.question"].create({
            "name": "Describe the fault",
            "question_type": "subjective_rubric",
            "prompt": "What went wrong?",
            "generator_id": generator.id,
            "assessment_ids": [(4, self.assessment.id)],
        })
        self.candidate = self.env["hr.applicant"].create({
            "partner_name": "Grader Error Candidate",
        })
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": self.candidate.id,
        })

    def _response(self, state, feedback):
        # A response is NOT NULL on `assessment_id`, so it needs the whole
        # sitting: assessment, candidate and evaluator. `justification` is its
        # free-text field - there is no `answer_text` on this model.
        #
        # A FRESH QUESTION EACH TIME. `assessments_be_response_uniq_eval_q_sess`
        # allows one response per (evaluator, question, session), which is
        # correct - a candidate answers a question once - so the tests below that
        # walk several states need a separate question per response rather than
        # several responses on one.
        question = self.env["assessments.be.question"].create({
            "name": "Describe the fault (%s)" % state,
            "question_type": "subjective_rubric",
            "prompt": "What went wrong?",
            "generator_id": self.question.generator_id.id,
            "assessment_ids": [(4, self.assessment.id)],
        })
        r = self.env["assessments.be.response"].create({
            "question_id": question.id,
            "assessment_id": self.assessment.id,
            "evaluator_id": self.candidate.id,
            "assessment_evaluator_id": self.evaluator.id,
            "justification": "The mast weld is cracked.",
        })
        r.write({"llm_state": state, "llm_feedback": feedback})
        r.invalidate_recordset()
        return r

    def test_a_terminal_error_carries_its_reason(self):
        row = S.response_row(self._response("error", REASON))
        self.assertEqual(row["llm_state"], "error")
        self.assertEqual(
            row.get("llm_error"), REASON,
            "the row the Responses table is built from must carry WHY, or the "
            "operator is choosing whether to re-score with no information")

    def test_a_retryable_failure_carries_it_too(self):
        """`failed` still retries on the cron, but an operator watching a stuck
        attempt needs the same reason."""
        row = S.response_row(self._response("failed", REASON))
        self.assertEqual(row.get("llm_error"), REASON)

    def test_a_SCORED_answer_leaks_no_judge_prose_into_the_diagnostic(self):
        """The guard that stops this fix becoming its own defect.

        `llm_feedback` is the judge's reasoning on a scored answer. Sending it
        under an error key would print "Clear, well-structured answer." in a cell
        headed Scoring, next to a green pill, as though something had failed.
        """
        row = S.response_row(
            self._response("scored", "Clear, well-structured answer."))
        self.assertEqual(row.get("llm_error"), "")

    def test_every_other_state_is_quiet(self):
        # The response's OWN selection: not_needed / pending / queued / scored /
        # failed / error. There is no `scoring` here - that one belongs to the
        # evaluator, and writing it to a response raises.
        for state in ("not_needed", "pending", "queued"):
            row = S.response_row(self._response(state, "some prose"))
            self.assertEqual(
                row.get("llm_error"), "",
                "%s is not a failure, so it must carry no diagnostic" % state)

    def test_the_key_is_always_PRESENT(self):
        """Absent and empty are different to the client: `jget` returns null for
        a missing key, and a null is what the old code could not tell from
        "no reason recorded"."""
        for state in ("error", "scored", "not_needed"):
            self.assertIn("llm_error", S.response_row(
                self._response(state, "x")))

    def test_an_error_with_no_recorded_reason_is_an_empty_string(self):
        """The grader can die without writing prose; the client renders its own
        "no reason recorded" line, so this must not be None."""
        row = S.response_row(self._response("error", ""))
        self.assertEqual(row.get("llm_error"), "")

    def test_the_reason_is_not_read_from_the_EVALUATOR_field(self):
        """The trap: `llm_error` exists on `assessments.be.evaluator` and is a
        DIFFERENT value. If a future edit re-points this at the attempt's field,
        a response whose own feedback names the fault would report nothing.
        """
        response = self._response("error", REASON)
        self.assertFalse(
            hasattr(response, "llm_error")
            and bool(getattr(response, "llm_error", False)),
            "the response model has no llm_error of its own - the reason is in "
            "llm_feedback, which is what `_store_error` writes")
        self.assertEqual(S.response_row(response).get("llm_error"), REASON)
