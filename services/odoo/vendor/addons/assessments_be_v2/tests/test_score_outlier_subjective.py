"""The score-outlier flag reviews SUBJECTIVE marking, and nothing else.

WHAT THE FLAG IS FOR, in its own words: "the net for a prompt-injection that
dodged the answer gate and inflated a grader score". Injection is a
conversation with a model. An objective answer is compared against a stored
key, so there is no conversation to have and nothing to inflate.

It measured `score_percent` - the candidate's total across every question -
which made it fire twice over for reasons it was never meant to catch:

  - On a purely OBJECTIVE paper it could only ever mean "scored well". There
    is always a top scorer, so the strongest candidate in a cohort was flagged
    for integrity review on an assessment where no grader was ever asked
    anything. A signal that fires on the honest case is one people stop
    reading, and it takes the two real signals on that panel down with it.
  - On a MIXED paper it pointed at the wrong half. Someone who aced the
    objective questions and was ordinary on the subjective ones could clear
    the threshold, sending a reviewer to read answers that were never in
    question.

There was no test on this compute at all, which is how both survived.

THE SECOND TRAP, guarded by `test_the_measure_is_the_raw_grader_score`:
`llm_total_score / llm_max_score` is the obvious subjective aggregate and it
is still wrong. `llm_score` is an EQUAL MARK - 1 or 0 either side of the
subjective threshold - so a candidate whose answers were talked up from 60 to
95 earns exactly the same marks. Measured that way the flag would move for
nobody. `subjective_raw_percent` averages the grader's own 0-100, which is the
number an injection actually moves.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestScoreOutlierIsSubjectiveOnly(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Generator = self.env["assessments.be.prompt"]
        self.Question = self.env["assessments.be.question"]
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.Generator.create(
            {"name": "Forklift SOP %s" % uuid4().hex[:6]})
        # The default is 2.0; pinned so a deployment that tuned it cannot
        # quietly change what this test means.
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.score_outlier_sigma", "2.0")

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _subjective_question(self):
        return self.Question.create({
            "name": "Parking procedure %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Describe the state a forklift must be left in.",
            "generator_id": self.generator.id,
        })

    def _objective_question(self):
        q = self.Question.create({
            "name": "Battery charging %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "What does the SOP require before charging a battery?",
            "generator_id": self.generator.id,
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": q.id,
            "name": "Correctness",
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": i * 10, "is_correct": i == 0})
                for i, n in enumerate(("Chock it", "Ignore it", "Refuel"))
            ],
        })
        return q

    def _assessment(self, question, subjective_threshold=50.0):
        """`subjective_threshold` is PINNED, never left to the default.

        It is the bar an answer's raw 0-100 has to clear to earn its equal
        mark, so it decides which side of the mark every fixture score lands
        on. `test_the_measure_is_the_raw_grader_score` depends on the whole
        cohort landing on the SAME side - that is the point of it - and reading
        the deployment's default would make the test mean something different
        on a database that had tuned it.
        """
        return self.Assessment.create({
            "name": "Warehouse Safety %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
            "subjective_threshold": subjective_threshold,
        })

    def _cohort(self, assessment, question, raw_scores):
        """One submitted candidate per entry in `raw_scores`.

        Each answers the same single question.

        A SUBJECTIVE answer is stamped with the grader's raw 0-100 directly:
        this is a test of the statistic computed over those numbers, not of the
        grader that produces them.

        An OBJECTIVE answer is marked by the real `_compute_score`, which reads
        the chosen options off `line_ids` - `score` is computed and cannot be
        written. `raw >= 50` picks the correct option, anything lower picks a
        wrong one, so the cohort genuinely varies and the old whole-score
        measure would have had a real outlier to find.
        """
        subjective = question.question_type == "subjective_rubric"
        evaluators = self.Evaluator
        for i, raw in enumerate(raw_scores):
            applicant = self.Applicant.create({
                "partner_name": "Candidate %d" % i,
                "email_from": "cand_%s@example.com" % uuid4().hex[:8],
            })
            ev = self.Evaluator.create({
                "assessment_id": assessment.id,
                "applicant_id": applicant.id,
            })
            vals = {
                # `response_ids` on the evaluator is keyed on THIS field.
                # `evaluator_id` is the hr.applicant, not the assignment.
                "assessment_evaluator_id": ev.id,
                "evaluator_id": applicant.id,
                "question_id": question.id,
                "assessment_id": assessment.id,
                "state": "submitted",
            }
            if subjective:
                vals.update({
                    "justification": "An answer worth %s" % raw,
                    "llm_raw_100": float(raw),
                    "llm_state": "scored",
                })
            else:
                dimension = question.question_dimension_ids[0]
                correct = dimension.option_line_ids.filtered("is_correct")
                wrong = dimension.option_line_ids - correct
                chosen = correct[0] if raw >= 50 else wrong[0]
                vals["line_ids"] = [(0, 0, {
                    "question_dimension_id": dimension.id,
                    "selected_option_id": chosen.id,
                })]
            self.Response.create(vals)
            ev.state = "submitted"
            evaluators |= ev
        return evaluators

    # ------------------------------------------------------------------
    # The gate
    # ------------------------------------------------------------------
    def test_an_objective_only_paper_flags_nobody(self):
        """The regression. The top scorer on a keyed paper is just the top
        scorer - there is no grader to have talked to."""
        q = self._objective_question()
        assessment = self._assessment(q)
        # One candidate far above a tight cohort: an unmistakable outlier by
        # the old whole-score measure.
        cohort = self._cohort(assessment, q, [0, 0, 0, 0, 0, 100])

        self.assertFalse(
            any(cohort.mapped("score_outlier")),
            "an objective-only assessment flagged a candidate for integrity "
            "review - there is no subjective mark on this paper for an "
            "injection to have inflated")

    def test_a_subjective_paper_still_flags_its_outlier(self):
        """The gate must not have disabled the feature."""
        q = self._subjective_question()
        assessment = self._assessment(q)
        cohort = self._cohort(assessment, q, [50, 52, 48, 51, 49, 99])

        flagged = cohort.filtered("score_outlier")
        self.assertEqual(
            len(flagged), 1,
            "the one candidate sitting far above a tight cohort should be "
            "flagged")
        self.assertEqual(flagged.subjective_raw_percent, 99.0)

    def test_the_measure_is_the_raw_grader_score(self):
        """Equal marks cannot see inflation; the raw score can.

        Every candidate here clears the subjective threshold, so every one of
        them earns the same mark and `llm_total_score / llm_max_score` is
        identical across the cohort. Only the grader's raw 0-100 separates
        them - and separating them is the entire job.
        """
        q = self._subjective_question()
        assessment = self._assessment(q)
        cohort = self._cohort(assessment, q, [60, 61, 59, 60, 62, 99])

        marks = set(cohort.mapped("llm_total_score"))
        self.assertEqual(
            len(marks), 1,
            "fixture no longer holds: these answers must all earn the same "
            "equal mark, or the test is not measuring what it claims")
        self.assertTrue(
            any(cohort.mapped("score_outlier")),
            "inflation invisible to the marks went unflagged - the compute is "
            "reading llm_score again rather than subjective_raw_percent")

    # ------------------------------------------------------------------
    # The cohort
    # ------------------------------------------------------------------
    def test_a_cohort_under_the_minimum_flags_nobody(self):
        """Below the floor there is no stable mean to be unusual against."""
        q = self._subjective_question()
        assessment = self._assessment(q)
        cohort = self._cohort(assessment, q, [50, 50, 99])

        self.assertFalse(any(cohort.mapped("score_outlier")))

    def test_an_ungraded_candidate_is_not_compared(self):
        """A half-marked candidate scores low for a reason that has nothing to
        do with their answers. Counting them would drag the mean down and
        manufacture an outlier out of an ordinary cohort."""
        q = self._subjective_question()
        assessment = self._assessment(q)
        cohort = self._cohort(assessment, q, [50, 52, 48, 51, 49, 70])

        pending = cohort[-1]
        pending.response_ids.llm_state = "pending"

        self.assertTrue(
            pending.subjective_pending,
            "fixture no longer holds: the candidate must read as ungraded")
        self.assertFalse(
            pending.score_outlier,
            "a candidate still being graded was compared against peers who "
            "have finished")

    def test_a_flat_cohort_has_no_outlier(self):
        """Zero deviation must not divide by zero or flag everyone."""
        q = self._subjective_question()
        assessment = self._assessment(q)
        cohort = self._cohort(assessment, q, [70, 70, 70, 70, 70, 70])

        self.assertFalse(any(cohort.mapped("score_outlier")))

    def test_scoring_low_is_never_an_outlier(self):
        """The flag looks ABOVE the mean only. It is a net for someone who
        gained marks they should not have, not a report on who struggled."""
        q = self._subjective_question()
        assessment = self._assessment(q)
        cohort = self._cohort(assessment, q, [80, 82, 78, 81, 79, 1])

        self.assertFalse(
            any(cohort.mapped("score_outlier")),
            "the candidate far BELOW the cohort was flagged for integrity "
            "review")

    def test_the_flag_never_touches_the_result(self):
        """Advisory, and the whole panel promises so."""
        q = self._subjective_question()
        assessment = self._assessment(q)
        cohort = self._cohort(assessment, q, [50, 52, 48, 51, 49, 99])

        flagged = cohort.filtered("score_outlier")
        self.assertTrue(flagged)
        for ev in flagged:
            self.assertNotEqual(
                ev.result, "fail",
                "being flagged must not decide a result")
