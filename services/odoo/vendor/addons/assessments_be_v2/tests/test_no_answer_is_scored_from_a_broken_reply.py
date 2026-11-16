"""A mark is never taken from a judge reply that plainly did not arrive whole.

TWO DEFECTS, one theme: the platform read the ABSENCE of a score as the score
zero, which is indistinguishable from a candidate who earned nothing.

D-5 - A NULL SCORE BECAME A PERMANENT FAIL.
`_coerce_100` returns 0.0 for anything it cannot read, and `float(None)` raises
TypeError, so it lands in that branch. A judge emitting

    {"id": 41, "score": null, "verdict": "Strong answer"}

was stored as `scored` / 0.0, which `_compute_subjective_marks` turns into a
FAIL. Permanently: `scored` is terminal, the cron never revisits it, and the row
looks exactly like a genuine zero. `_store_error` states the principle this
broke - "an exhausted response resolves to a surfaced 'error', never a silent
scored-0" - and it had simply never been applied to a present-but-scoreless item.

D-4 - A TRUNCATED REPLY ZEROED BOXES THE CANDIDATE HAD ANSWERED.
Gemini-2.5 truncates long JSON, and the labelling lane asks for one entry per
box, so a 20-box answer routinely comes back with the first few scored and the
rest missing. Those were counted as zeros: a PERFECT 20-box answer with 3 boxes
returned scored 3/20 = 15% and failed, with nothing flagged.
`boxes_returned_by_judge` was already being computed - and used only to write a
sentence into `reasoning`.

WHAT THE FIX IS CAREFUL ABOUT, and what these tests pin:

  * IT ALWAYS SCORES IN THE END. A truncated reply is retried while attempts
    remain; on the last attempt it scores anyway. An answer that never scores is
    worse than one scored imperfectly - it strands a paper waiting for an admin
    who may never look.
  * THE DENOMINATOR NEVER MOVES. It stays the number of boxes the task asked
    for, so a judge cannot shrink it by returning fewer boxes. That property is
    asserted by `test_a_box_the_judge_omitted_scores_zero_and_still_counts` in
    test_image_label_per_box.py, which passes UNCHANGED - the retry decision
    lives in `_score_submission`, not in the pure scorer those tests drive.
  * A GENUINE ZERO IS STILL A ZERO. `score: 0` is a real mark and must not be
    mistaken for a missing one.
"""
import json

from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase

from odoo.addons.assessments_be_v2.services import scoring as scoring_svc
from odoo.addons.assessments_be_v2.services import vertex as vertex_svc


class TestNoAnswerIsScoredFromABrokenReply(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})

    def _rubric_response(self):
        """A plain subjective response, ready for the judge."""
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Explain your reasoning.",
            "generator_id": self.generator.id,
        })
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "c_%s@example.com" % uuid4().hex[:8],
        })
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": "[%d]" % question.id,
        })
        return self.env["assessments.be.response"].create({
            "assessment_id": assessment.id,
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "justification": "A real, substantial written answer.",
            "state": "submitted",
            "llm_state": "pending",
        })

    def _grade(self, resp, item):
        """Drive the REAL store path with a hand-written judge reply.

        `_call_vertex` is the seam: it returns the raw model text, which
        `_parse_results` then turns into items. Stubbing there - rather than
        further in - keeps every line of the parse and store path under test,
        which is where both defects lived.
        """
        reply = json.dumps({"results": [item]})
        with patch.object(vertex_svc, "_call_vertex", return_value=reply):
            return scoring_svc._score_submission(self.env, resp)

    # ── D-5: a missing score is an error, not a zero ──────────────────

    def test_a_null_score_is_surfaced_not_stored_as_zero(self):
        resp = self._rubric_response()
        self._grade(resp, {"id": resp.id, "score": None,
                           "verdict": "Strong answer"})

        self.assertNotEqual(
            resp.llm_state, "scored",
            "a scoreless result must never be stored as a finished mark")
        self.assertIn(resp.llm_state, ("failed", "error"))
        self.assertTrue(resp.llm_attempts >= 1, "it must count as an attempt")

    def test_a_missing_score_key_is_treated_the_same(self):
        resp = self._rubric_response()
        self._grade(resp, {"id": resp.id, "verdict": "Strong answer"})
        self.assertNotEqual(resp.llm_state, "scored")

    def test_a_GENUINE_zero_is_still_stored_as_a_zero(self):
        """THE GUARD ON THE GUARD.

        `0` is a real mark - an answer that earned nothing. Treating it as
        "missing" would push every legitimately-failed answer into the error
        lane and make the whole fix worse than the bug.
        """
        resp = self._rubric_response()
        self._grade(resp, {"id": resp.id, "score": 0,
                           "verdict": "Nothing correct here."})

        self.assertEqual(resp.llm_state, "scored")
        self.assertEqual(resp.llm_raw_100, 0.0)

    def test_a_deductions_array_is_a_usable_score_without_a_score_key(self):
        """The drop-2 contract derives the mark as 100 + sum(points).

        `_store_scored` prefers that recompute anyway, so refusing these would
        error on results that are COMPLETE by the current contract.
        """
        resp = self._rubric_response()
        self._grade(resp, {
            "id": resp.id,
            "deductions": [{"points": -20, "why": "missed a step"}],
            "verdict": "Mostly right.",
        })

        self.assertEqual(resp.llm_state, "scored")
        self.assertAlmostEqual(resp.llm_raw_100, 80.0, places=1)

    def test_a_normal_score_is_unaffected(self):
        resp = self._rubric_response()
        self._grade(resp, {"id": resp.id, "score": 72, "verdict": "Good."})
        self.assertEqual(resp.llm_state, "scored")
        self.assertAlmostEqual(resp.llm_raw_100, 72.0, places=1)

    # ── D-4: the shortfall is reported, and reported honestly ─────────
    def _label_response(self, boxes, answers):
        """An image_label response with `boxes` in the key and `answers` typed."""
        question = self.env["assessments.be.question"].create({
            "name": "Label %s" % uuid4().hex[:6],
            "question_type": "image_label",
            "prompt": "Name every marked region.",
            "generator_id": self.generator.id,
        })
        self.env["assessments.be.question.image"].create({
            "question_id": question.id,
            "slot": "single",
            "label": "Scene",
            # THE REAL SHAPE: `[{number, element, functionality}]`, which is
            # what the DOM lane writes and what `_label_boxes` sends the judge.
            # Keyed on anything else the question has no numbered box at all,
            # and is now counted as keyless rather than marked out of a key the
            # grader was never shown (qa-grading-edge-1).
            "behavioural_key_json": json.dumps(
                [{"number": n, "element": "Control %d" % n,
                  "functionality": chr(96 + n)}
                 for n in range(1, boxes + 1)]),
        })
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "t_%s@example.com" % uuid4().hex[:8],
        })
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": "[%d]" % question.id,
        })
        return self.env["assessments.be.response"].create({
            "assessment_id": assessment.id,
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "justification": json.dumps(answers),
            "state": "submitted",
            "llm_state": "pending",
        })

    def test_a_truncated_reply_is_RETRIED_not_scored_at_15_percent(self):
        """THE HEADLINE FOR D-4, asserted through the real store path.

        Four boxes answered, one returned. Before the fix this stored
        `scored` with a 25% mark; a real 20-box answer scored 15% and FAILED.
        """
        resp = self._label_response(4, {"1": "alpha region", "2": "beta region",
                                        "3": "gamma region", "4": "delta zone"})
        self._grade(resp, {"id": resp.id, "score": 100,
                           "box_scores": {"1": 100}})

        self.assertNotEqual(
            resp.llm_state, "scored",
            "a visibly truncated reply must not fix a mark on the first try")
        self.assertEqual(resp.llm_state, "failed",
                         "failed is requeued by the drainer, so it gets another go")

    def test_but_the_LAST_attempt_scores_anyway_so_nothing_is_left_unscored(self):
        """An answer that never scores strands the paper. The ceiling is three
        honest tries, not refuse-forever."""
        resp = self._label_response(4, {"1": "alpha region", "2": "beta region",
                                        "3": "gamma region", "4": "delta zone"})
        # Two attempts already spent; llm_max_attempts defaults to 3.
        resp.llm_attempts = 2
        self._grade(resp, {"id": resp.id, "score": 100,
                           "box_scores": {"1": 100}})

        self.assertEqual(
            resp.llm_state, "scored",
            "on the last attempt it must score rather than strand the answer")

    def test_a_complete_label_reply_scores_first_time(self):
        """The healthy case must not be dragged through a retry."""
        resp = self._label_response(2, {"1": "alpha region", "2": "beta region"})
        self._grade(resp, {"id": resp.id, "score": 90,
                           "box_scores": {"1": 90, "2": 80}})

        self.assertEqual(resp.llm_state, "scored")


    def test_the_pure_scorer_reports_boxes_the_judge_skipped(self):
        """`_apply_image_label_boxes` stays a pure scorer.

        It reports the shortfall and decides nothing - whether to retry needs
        the attempt count, which only the caller has. That separation is what
        leaves the four tests in test_image_label_per_box.py driving this
        function directly, unchanged.
        """
        question = self.env["assessments.be.question"].create({
            "name": "Label %s" % uuid4().hex[:6],
            "question_type": "image_label",
            "prompt": "Name every marked region.",
            "generator_id": self.generator.id,
        })
        image = self.env["assessments.be.question.image"].create({
            "question_id": question.id,
            "slot": "single",
            "label": "Scene",
            "behavioural_key_json": '[{"number": 1, "element": "a"},'
                                    ' {"number": 2, "element": "b"},'
                                    ' {"number": 3, "element": "c"},'
                                    ' {"number": 4, "element": "d"}]',
        })
        self.assertTrue(image)

        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "l_%s@example.com" % uuid4().hex[:8],
        })
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": "[%d]" % question.id,
        })
        # All four boxes answered properly.
        resp = self.env["assessments.be.response"].create({
            "assessment_id": assessment.id,
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "justification": '{"1": "alpha region", "2": "beta region", '
                             '"3": "gamma region", "4": "delta region"}',
            "state": "submitted",
            "llm_state": "pending",
        })

        # The judge returned ONE of the four - a truncated reply.
        out = scoring_svc._apply_image_label_boxes(
            resp, {"box_scores": {"1": 100}})

        stats = out["label_scores"]
        self.assertEqual(stats["boxes_returned_by_judge"], 1)
        self.assertEqual(
            stats["unscored_attempted"], [2, 3, 4],
            "the boxes the candidate answered and the judge skipped")
        # And the denominator has NOT moved - the property the existing test
        # guards, re-asserted here so a future change cannot quietly trade one
        # fix for the other.
        self.assertEqual(stats["total_boxes"], 4)
        self.assertEqual(len(out["box_scores"]), 4)

    def test_a_complete_reply_reports_no_shortfall(self):
        """The healthy case must stay silent, or the retry would fire forever."""
        question = self.env["assessments.be.question"].create({
            "name": "Label %s" % uuid4().hex[:6],
            "question_type": "image_label",
            "prompt": "Name every marked region.",
            "generator_id": self.generator.id,
        })
        self.env["assessments.be.question.image"].create({
            "question_id": question.id,
            "slot": "single",
            "label": "Scene",
            "behavioural_key_json": '[{"number": 1, "element": "a"},'
                                    ' {"number": 2, "element": "b"}]',
        })
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "m_%s@example.com" % uuid4().hex[:8],
        })
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": "[%d]" % question.id,
        })
        resp = self.env["assessments.be.response"].create({
            "assessment_id": assessment.id,
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "justification": '{"1": "alpha region", "2": "beta region"}',
            "state": "submitted",
            "llm_state": "pending",
        })

        out = scoring_svc._apply_image_label_boxes(
            resp, {"box_scores": {"1": 90, "2": 80}})

        self.assertEqual(out["label_scores"]["unscored_attempted"], [])
        self.assertAlmostEqual(out["composed_raw_100"], 85.0, places=2)
