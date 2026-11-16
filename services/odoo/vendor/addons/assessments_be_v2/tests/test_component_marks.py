"""The unit of scoring is the COMPONENT, not the question.

THE RULE THAT CHANGED, AND WHY THIS FILE EXISTS. A question used to be worth
exactly 1 mark however much was in it, and that mark was a conjunction across
its halves: an `image_ab` mark was `0.75 * mcq_mark + 0.25 * subj_mark` before
the blend was removed, and afterwards it needed EVERY verdict right AND the
justification over the bar. Both shapes had the same defect at the bottom of
them - a candidate who called three of four comparisons correctly scored the
same as one who called none, and a three-part MCQ answered two-thirds right
scored zero. The paper could not tell a near-miss from a blank.

The rule now: every component is worth exactly 1 mark and is won or lost on its
own. A component is a KEYED dimension (one with at least one `is_correct`
option - the same rule for mcq, for msq and for every image_ab verdict axis),
or the LLM-graded free-text answer, or a labelling box set taken as a whole.
A question is worth the sum of its components, so a 3-sub-question MCQ is worth
3 and an image_ab with four verdict axes plus a justification is worth 5.

WHAT THIS FILE GUARDS, case by case:

  * The DENOMINATOR grew with the numerator. `final_max` has to be the
    question's component count, not 1, or the finer numerator would be scored
    out of the old total and every multi-part question would read as 300%.
  * All-or-nothing survives WITHIN one sub-question and nowhere else. One
    missing or one extra option on an MSQ dimension scores THAT dimension 0 -
    partial credit inside a component is exactly what was never wanted - while
    the sibling dimensions are untouched. The two halves of that sentence pull
    in opposite directions, which is why both are pinned here.
  * A KEYLESS dimension is in neither the numerator nor the denominator. An
    author who never ticked a correct option has left a sub-question nothing
    can satisfy; counting it would mark every candidate wrong on it and read as
    a candidate failure rather than the authoring fault it is.
  * OBJECTIVE COMPONENTS HAVE NO RAW, on either side of the fraction. Partial
    credit was removed from them deliberately, so an objective raw would only
    restate the mark beside it - and leaving them in the raw's DENOMINATOR
    would make the raw read lower the more multiple-choice a paper contained,
    which is a property of the paper and not of the candidate.

WHAT THIS FILE DOES AND DOES NOT PROVE. Every case stamps `llm_raw_100`
directly, so it tests the COMPOSITION - how `_compute_final_marks` and
`_compute_subjective_marks` fold components into a mark - and nothing about
which scores the live grader can produce. `docs/ETP_KNOWLEDGE_BASE.md (4.6 Scoring, in engineering terms)` walks the
end-to-end path (and is itself behind this change at the time of writing).

`subjective_threshold` is PINNED on every fixture rather than left to
`DEFAULT_SUBJECTIVE_THRESHOLD`. It is the bar an answer's raw 0-100 must clear
to earn its component's mark, so it decides which side of the mark each fixture
score lands on; reading a deployment's tuned default would make these tests
mean something different on every database.

Superseded `test_normal_mark_all_or_nothing.py`, which pinned the removed
0.75/0.25 blend, the two blended-raw columns that carried it (both deleted with
it), and the all-or-nothing conjunction across a question's halves.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class _Base(TransactionCase):
    """Fixture factories shared by every case below.

    They build the real chain - Generator, Question, Dimensions/Options,
    Assessment, Evaluator, Response - and then let the ORM's own computes do
    all the marking. Nothing here writes a mark: `final_mark`, `final_max`,
    `mcq_mark`, `raw_score` and `raw_max` are computed and cannot be written,
    which is what makes an assertion on them an assertion about the rule.
    """

    THRESHOLD = 50.0
    OVER = 80.0
    UNDER = 20.0

    def setUp(self):
        super().setUp()
        self.Generator = self.env["assessments.be.prompt"]
        self.Question = self.env["assessments.be.question"]
        self.Dimension = self.env["assessments.be.question.dimension"]
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.Generator.create(
            {"name": "Render comparison %s" % uuid4().hex[:6]})

    def _question(self, qtype, name="Question"):
        return self.Question.create({
            "name": "%s %s" % (name, uuid4().hex[:6]),
            "question_type": qtype,
            "prompt": "Answer the parts of this question.",
            "generator_id": self.generator.id,
        })

    def _dimension(self, question, name, options=("A", "B", "C"), correct=(0,)):
        """One sub-question. `correct` is the indexes of the keyed options.

        An EMPTY `correct` makes the dimension KEYLESS on purpose - that is the
        authoring fault `test_a_keyless_dimension_is_not_a_component` is about,
        and it has to be constructible here to be testable at all.
        """
        return self.Dimension.create({
            "question_id": question.id,
            "name": name,
            "option_line_ids": [
                (0, 0, {"name": option, "sequence": i * 10,
                        "is_correct": i in correct})
                for i, option in enumerate(options)
            ],
        })

    def _assessment(self, questions, threshold=None):
        """`subjective_threshold` is PINNED - see the module docstring."""
        return self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, questions.ids)],
            "subjective_threshold": (
                self.THRESHOLD if threshold is None else threshold),
        })

    def _evaluator(self, assessment):
        applicant = self.Applicant.create({
            "partner_name": "Candidate %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:8],
        })
        return self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })

    def _response(self, evaluator, question, picks=(), justification="",
                  raw_100=None):
        """One submitted answer.

        `picks` is a list of (dimension, option) pairs and goes in as
        `line_ids` - the choices, never a score. The grader's raw 0-100 IS
        stamped directly when given: these are tests of composition, not of the
        grader that produces one of the inputs.
        """
        vals = {
            # `response_ids` on the evaluator is keyed on THIS field;
            # `evaluator_id` is the hr.applicant, not the assignment.
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": evaluator.applicant_id.id,
            "question_id": question.id,
            "assessment_id": evaluator.assessment_id.id,
            "state": "submitted",
            "line_ids": [
                (0, 0, {"question_dimension_id": dimension.id,
                        "selected_option_id": option.id})
                for dimension, option in picks
            ],
        }
        if justification:
            vals["justification"] = justification
        if raw_100 is not None:
            vals.update({"llm_raw_100": raw_100, "llm_state": "scored"})
        return self.Response.create(vals)

    @staticmethod
    def _pick(dimension, index):
        return dimension, dimension.option_line_ids.sorted("sequence")[index]


class TestObjectiveComponentMarks(_Base):
    """Each keyed sub-question is its own mark, and stands on its own."""

    def test_a_three_part_mcq_is_worth_three_and_two_right_scores_two(self):
        """THE headline case: 2 of 3 no longer scores the same as 0 of 3.

        Both sides of the fraction are asserted. A change that grew the
        numerator and left `final_max` at 1 would show a candidate scoring
        2 out of 1, and a change that grew the denominator without the
        numerator would fail everybody who was not perfect.
        """
        question = self._question("mcq", "Three parts")
        dims = [self._dimension(question, "Part %d" % i) for i in range(1, 4)]
        assessment = self._assessment(question)
        evaluator = self._evaluator(assessment)

        response = self._response(evaluator, question, picks=[
            self._pick(dims[0], 0),   # right
            self._pick(dims[1], 0),   # right
            self._pick(dims[2], 1),   # wrong
        ])

        self.assertEqual(
            response.final_max, 3,
            "a 3-sub-question MCQ has to be worth 3 - the whole point of "
            "marking per component is that the denominator grows with it")
        self.assertEqual(
            response.final_mark, 2.0,
            "two of three right scored 0 under the old whole-question rule; "
            "each sub-question now stands or falls on its own")
        self.assertEqual(response.mcq_mark, 2.0)
        self.assertEqual(response.objective_marks_max, 3)

    def test_every_part_right_scores_every_mark(self):
        """The positive control for the case above.

        Without it, a compute that returned 2 for everything would satisfy the
        2-of-3 assertion.
        """
        question = self._question("mcq", "Three parts")
        dims = [self._dimension(question, "Part %d" % i) for i in range(1, 4)]
        evaluator = self._evaluator(self._assessment(question))

        response = self._response(
            evaluator, question,
            picks=[self._pick(d, 0) for d in dims])

        self.assertEqual(response.final_mark, 3.0)
        self.assertEqual(response.final_max, 3)

    def test_a_keyless_dimension_is_not_a_component(self):
        """No correct option means nothing can be right, so it is not a mark.

        Counting it would put a sub-question in the denominator that no
        candidate can ever earn, marking the whole cohort down for an author
        who did not finish the key - a platform fault reported as a candidate
        failure. It has to be absent from BOTH sides, so a perfect candidate
        reads 1/1 rather than 1/2.
        """
        question = self._question("mcq", "One real part")
        keyed = self._dimension(question, "Keyed")
        keyless = self._dimension(question, "Keyless", correct=())
        evaluator = self._evaluator(self._assessment(question))

        self.assertEqual(
            question._keyed_dimension_count(), 1,
            "the keyless dimension was counted as markable")
        self.assertEqual(question._component_counts(), (1, 1))

        response = self._response(evaluator, question, picks=[
            self._pick(keyed, 0),      # right
            self._pick(keyless, 0),    # unmarkable either way
        ])

        self.assertEqual(response.final_max, 1)
        self.assertEqual(response.objective_marks_max, 1)
        self.assertEqual(
            response.final_mark, 1.0,
            "an unfinished answer key cost the candidate a mark")

    def test_objective_components_carry_a_raw_equal_to_their_mark(self):
        """`raw_score`/`raw_max` cover EVERY component, objective ones included.

        A keyed dimension's raw is its mark - there is no partial credit inside
        a dimension, so there is nothing else it could be. The point of
        including it is the DENOMINATOR: the raw and the mark now describe one
        paper out of one total. They used to be quoted out of two ("1.40 / 2"
        beside "3 / 5" for the same attempt), which read as a defect rather
        than a distinction, and a wholly objective paper showed no raw at all.
        """
        question = self._question("mcq", "Objective only")
        dims = [self._dimension(question, "Part %d" % i) for i in range(1, 4)]
        evaluator = self._evaluator(self._assessment(question))
        evaluator.state = "submitted"

        response = self._response(
            evaluator, question,
            picks=[self._pick(d, 0) for d in dims])

        self.assertEqual(response.raw_max, 3,
                         "an objective question's components must carry a raw")
        self.assertEqual(response.raw_score, 3.0,
                         "three exactly-right sub-questions are a raw of 3")
        self.assertEqual(question._component_counts(), (3, 3))

        # And at the attempt level: one denominator, two numerators that agree
        # because there is nothing graded here for them to disagree about.
        self.assertEqual(evaluator.score_marks_display, "3 / 3")
        self.assertEqual(evaluator.raw_max, 3)
        self.assertEqual(evaluator.raw_result, 3.0)
        self.assertEqual(evaluator.raw_percent, 100.0)
        self.assertEqual(
            evaluator.raw_percent, evaluator.score_percent,
            "on a wholly objective paper the two readings cannot differ")

    def test_a_wrong_objective_pick_scores_zero_in_the_raw_too(self):
        """The other half of the rule, and the one worth pinning separately.

        A dimension that was NOT exactly right contributes 0 to the raw as well
        as to the mark. Anything else would resurrect the old objective raw's
        no-penalty-for-wrong-picks behaviour, where ticking every option on an
        MSQ read as a perfect raw beside a mark of zero.
        """
        question = self._question("mcq", "Two right, one wrong")
        dims = [self._dimension(question, "Part %d" % i) for i in range(1, 4)]
        evaluator = self._evaluator(self._assessment(question))
        evaluator.state = "submitted"

        response = self._response(
            evaluator, question,
            picks=[self._pick(dims[0], 0), self._pick(dims[1], 0),
                   self._pick(dims[2], 1)])

        self.assertEqual(response.final_mark, 2.0)
        self.assertEqual(response.raw_score, 2.0,
                         "the wrong sub-question must not earn raw credit")
        self.assertEqual(response.raw_max, 3)


class TestMsqAllOrNothingWithinASubQuestion(_Base):
    """The one place all-or-nothing survives: inside a single dimension.

    An MSQ dimension's key is a SET, and the candidate's selection has to equal
    it exactly. One missing option is an incomplete answer and one extra is a
    guess spread across the options - the old objective raw's
    no-penalty-for-wrong-picks rule meant ticking every box read as 100, which
    is precisely why there is no partial credit inside a component now.

    What must NOT happen is that failure spreading: the sibling dimension in
    every case below is answered correctly and must keep its mark.
    """

    def _question_with_two_parts(self):
        """One msq: a 2-of-4 dimension to get wrong, and a 1-of-3 to get right."""
        question = self._question("msq", "Select all that apply")
        multi = self._dimension(
            question, "Hazards", options=("Fire", "Fumes", "Noise", "Glare"),
            correct=(0, 1))
        single = self._dimension(
            question, "Reporting", options=("Log it", "Ignore it"),
            correct=(0,))
        return question, multi, single

    def test_the_exact_key_earns_the_sub_question(self):
        """Positive control: without it, the two failure cases below prove
        only that this dimension never scores."""
        question, multi, single = self._question_with_two_parts()
        evaluator = self._evaluator(self._assessment(question))

        response = self._response(evaluator, question, picks=[
            self._pick(multi, 0), self._pick(multi, 1),
            self._pick(single, 0),
        ])

        self.assertEqual(response.final_max, 2)
        self.assertEqual(response.final_mark, 2.0)

    def test_one_missing_option_scores_that_sub_question_zero(self):
        question, multi, single = self._question_with_two_parts()
        evaluator = self._evaluator(self._assessment(question))

        response = self._response(evaluator, question, picks=[
            self._pick(multi, 0),          # one of the two keyed options
            self._pick(single, 0),
        ])

        self.assertEqual(
            response.final_mark, 1.0,
            "half of an MSQ key is not half a mark - the sub-question is "
            "all-or-nothing, and only the sibling dimension should have "
            "scored here")
        self.assertEqual(response.final_max, 2)

    def test_one_extra_option_scores_that_sub_question_zero(self):
        question, multi, single = self._question_with_two_parts()
        evaluator = self._evaluator(self._assessment(question))

        response = self._response(evaluator, question, picks=[
            self._pick(multi, 0), self._pick(multi, 1),
            self._pick(multi, 2),          # a wrong option on top of the key
            self._pick(single, 0),
        ])

        self.assertEqual(
            response.final_mark, 1.0,
            "ticking every option must not earn the mark - that was the "
            "no-penalty hole the component rule closes")
        self.assertEqual(response.final_max, 2)

    def test_the_failure_does_not_spread_to_the_sibling(self):
        """Named separately because it is the direction that regressed before.

        The old rule was a conjunction across the whole question, so a wrong
        MSQ dimension took the correctly-answered one down with it.
        """
        question, multi, single = self._question_with_two_parts()
        evaluator = self._evaluator(self._assessment(question))

        response = self._response(evaluator, question, picks=[
            self._pick(multi, 2), self._pick(multi, 3),   # both wrong
            self._pick(single, 0),                        # right
        ])

        self.assertEqual(response.mcq_mark, 1.0)
        self.assertEqual(response.final_mark, 1.0)


class TestImageAbIsVerdictsPlusJustification(_Base):
    """N verdict axes and a justification are N+1 components, not 1 question.

    This is the type the change is most visible on, and the type people get
    wrong. A wrong verdict used to cost the entire question - under the blend
    it cost 0.75 of it, and under the conjunction that replaced the blend it
    cost all of it. It now costs exactly 1 mark out of N+1, and the
    justification is an ordinary graded component that costs exactly 1 more.
    """

    AXES = ("Instruction Following", "Visual Quality", "Less AI Generated",
            "Overall Choice")

    def _ab_question(self):
        """`official_reasoning` IS THE JUSTIFICATION'S ANSWER KEY, so it is
        what makes the +1 component exist. Every case in this class grades a
        justification, so every fixture here carries one: an `image_ab`
        authored WITHOUT a standard has no gradable written half and is worth
        its verdict axes alone (`question._component_counts`). That case is
        pinned in `test_publish_demands_a_key.py`, not here.
        """
        question = self._question("image_ab", "Which render is better")
        question.official_reasoning = (
            "A is sharper and follows the brief; B has lighting artefacts.")
        dims = [self._dimension(question, axis, options=("A", "B"))
                for axis in self.AXES]
        return question, dims

    def _ab_answer(self, wrong_axes=(), raw_100=None):
        question, dims = self._ab_question()
        evaluator = self._evaluator(self._assessment(question))
        evaluator.state = "submitted"
        picks = [self._pick(d, 1 if i in wrong_axes else 0)
                 for i, d in enumerate(dims)]
        response = self._response(
            evaluator, question, picks=picks,
            justification="A defended call, worth %s." % raw_100,
            raw_100=raw_100)
        return evaluator, response

    def test_four_axes_and_a_justification_are_worth_five(self):
        question, _dims = self._ab_question()

        self.assertEqual(
            question._component_counts(), (5, 5),
            "an image_ab is its verdict axes PLUS its justification, and every "
            "one of those five components carries a raw")

    def test_everything_right_scores_every_mark(self):
        _ev, response = self._ab_answer(raw_100=self.OVER)

        self.assertEqual(response.final_max, 5)
        self.assertEqual(response.final_mark, 5.0)
        self.assertEqual(response.mcq_mark, 4.0)
        self.assertTrue(response.llm_passed)

    def test_one_wrong_verdict_costs_exactly_one_mark(self):
        """The regression this class exists for.

        Under both previous rules this answer scored 0. Anything other than 4
        here - 0, or a fraction - means the question has gone back to being
        marked as a unit.
        """
        _ev, response = self._ab_answer(wrong_axes=(1,), raw_100=self.OVER)

        self.assertEqual(
            response.final_mark, 4.0,
            "one wrong verdict must cost 1 mark out of 5, not the question")
        self.assertEqual(response.mcq_mark, 3.0)
        self.assertEqual(response.objective_marks_max, 4)

    def test_a_failed_justification_costs_exactly_one_mark(self):
        """The mirror image, and the half the old blend priced at 0.25.

        The verdicts are all correct and the writing is under the bar: that is
        4 out of 5, not 0 and not 3.75.
        """
        _ev, response = self._ab_answer(raw_100=self.UNDER)

        self.assertFalse(response.llm_passed)
        self.assertEqual(response.final_mark, 4.0)
        self.assertEqual(response.final_max, 5)

    def test_the_raw_covers_the_verdicts_and_the_justification(self):
        """All five components, and the justification is the only fractional one.

        Four verdict axes called correctly contribute 4.0; the justification
        contributes the grader's 0-100 as a fraction. `raw_percent` is
        therefore dragged BELOW 100 by exactly the justification's shortfall,
        which is the only thing on this question that admits a degree.
        """
        evaluator, response = self._ab_answer(raw_100=self.OVER)

        self.assertEqual(response.raw_max, 5)
        self.assertAlmostEqual(
            response.raw_score, 4.0 + self.OVER / 100.0, places=4)
        self.assertAlmostEqual(
            evaluator.raw_percent, (4.0 + self.OVER / 100.0) / 5 * 100,
            places=2)

    def test_a_wrong_verdict_costs_the_same_in_the_raw_as_in_the_mark(self):
        """A verdict axis has no degrees, so its raw is its mark.

        Pinned separately because it is the invariant a future "improvement"
        would break: any attempt to give a near-miss verdict partial raw credit
        resurrects the behaviour where ticking everything read as quality.
        """
        evaluator, response = self._ab_answer(
            wrong_axes=(1,), raw_100=self.OVER)

        self.assertEqual(response.final_mark, 4.0)
        self.assertAlmostEqual(
            response.raw_score, 3.0 + self.OVER / 100.0, places=4,
            msg="one wrong verdict must cost a full 1.0 of the raw")
        self.assertEqual(response.raw_max, 5)

    def test_the_marks_display_is_always_two_integers(self):
        """Every component awards 1 or 0, so neither side can be fractional.

        `_marksPart` in the Flutter app parses each side with `int.tryParse`:
        the old blend could produce '0.75 / 1', which parsed to null, so the
        app dropped the server's own figure and re-derived the score locally
        from whatever answers the screen happened to be holding. Nothing on
        this side of the wire enforces the shape, so it is pinned here.

        The numbers are LARGER than they used to be - the denominator is the
        paper's component count now, not its question count - but the shape the
        client parses is unchanged.
        """
        for wrong_axes, raw in (((), self.OVER), ((), self.UNDER),
                                ((0,), self.OVER), ((0, 2), self.UNDER)):
            with self.subTest(wrong_axes=wrong_axes, raw=raw):
                evaluator, _response = self._ab_answer(wrong_axes, raw)
                earned, sep, possible = \
                    evaluator.score_marks_display.partition("/")
                self.assertEqual(sep, "/")
                self.assertEqual(int(earned.strip()),
                                 int(float(earned.strip())))
                self.assertEqual(int(possible.strip()), 5)


class TestAComparisonThatAsksForNoJustificationIsItsVerdictsAlone(_Base):
    """A comparison with "Require justification" OFF is worth N, not N+1.

    THE MARK FOLLOWS THE GRADING. Every other case in this file gives the
    comparison a written standard, because the justification component only
    exists when there is something to mark it against: `prompts/scoring.md`
    grades `candidate_justification` AGAINST `official_reasoning`, so with no
    standard there is no judgement to make, no LLM call worth paying for, and
    therefore no mark. Charging one anyway would put a component on the paper
    that no candidate could earn and no grader could award - the question
    would read "1 / 2" with the missing half unreachable.

    THE ABSENT `official_reasoning` IS THE SWITCH BEING OFF. Form Studio's
    "Require justification" switch is stored nowhere: publish demands a
    rationale when it is on and discards one when it is off, so "no standard"
    and "no justification was asked for" are the same state
    (`test_publish_demands_a_key.py` pins that equivalence). The candidate is
    shown no box at all here, which is why charging for one would be
    indefensible rather than merely harsh.

    THIS IS NOT A HOLE IN THE DENOMINATOR RULE. An unanswered subjective still
    costs its mark; the rule keys on AUTHORING, never on what the candidate
    did. A comparison that DOES ask for a justification charges its mark
    whether or not the box was filled - and the candidate cannot submit it
    empty in the first place (`test_justification_gate.py`).
    """

    def _bare_ab_question(self, axes=("Overall Choice",)):
        """Deliberately NO `official_reasoning`: the switch is off."""
        question = self._question("image_ab", "Which render is better")
        dims = [self._dimension(question, axis, options=("A", "B"))
                for axis in axes]
        return question, dims

    def test_one_verdict_and_no_standard_is_worth_one(self):
        question, _dims = self._bare_ab_question()

        self.assertFalse(question.official_reasoning)
        self.assertEqual(
            question._component_counts(), (1, 1),
            "the keyed verdict is the whole question when nothing was "
            "authored for the judge to mark the justification against")

    def test_authoring_a_standard_later_adds_the_mark_back(self):
        """THE COMPUTES MUST BE WIRED TO `official_reasoning`, not just read
        it. Turning "Require justification" on for a published comparison
        writes the rationale, and the justification mark has to appear with it;
        a missing `@api.depends` would leave `final_max` stale at the old count
        and the justification permanently unmarked. Editing the rationale
        directly - over the API (`write.py`) or on the back-office form - is
        the same edit, and must behave the same way.
        """
        question, _dims = self._bare_ab_question()
        evaluator = self._evaluator(self._assessment(question))
        evaluator.state = "submitted"
        response = self._response(
            evaluator, question,
            picks=[self._pick(question.question_dimension_ids[0], 0)],
            justification="A is sharper.", raw_100=self.OVER)

        self.assertEqual(response.final_max, 1)

        question.official_reasoning = "A is sharper and follows the brief."

        self.assertEqual(
            response.final_max, 2,
            "the justification mark has to appear the moment a standard "
            "exists to grade it against")
        self.assertEqual(response.llm_max_score, 1)

    def test_the_written_half_is_not_marked_and_not_counted(self):
        """A candidate who wrote a justification is not marked on it.

        Both sides of the fraction, and `llm_max_score` with them: a raw
        stamped on the row must not create a mark the question does not have.
        `_compute_subjective_marks` has to zero it for the same reason
        `_component_counts` drops it, or the two disagree and the answer
        reports a mark out of a total nobody could earn.
        """
        question, dims = self._bare_ab_question()
        evaluator = self._evaluator(self._assessment(question))
        evaluator.state = "submitted"
        response = self._response(
            evaluator, question, picks=[self._pick(dims[0], 0)],
            justification="A is sharper.", raw_100=self.OVER)

        self.assertEqual(response.final_max, 1)
        self.assertEqual(response.final_mark, 1.0)
        self.assertEqual(response.llm_max_score, 0)
        self.assertEqual(response.llm_score, 0)
        self.assertFalse(response.llm_passed)
        self.assertEqual(response.raw_max, 1)
        self.assertAlmostEqual(response.raw_score, 1.0, places=4)

    def test_a_wrong_verdict_still_costs_exactly_its_own_mark(self):
        """Dropping the written component must not change how verdicts mark."""
        question, dims = self._bare_ab_question(
            axes=("Visual Quality", "Overall Choice"))
        evaluator = self._evaluator(self._assessment(question))
        evaluator.state = "submitted"
        response = self._response(
            evaluator, question,
            picks=[self._pick(dims[0], 1),    # wrong
                   self._pick(dims[1], 0)],   # right
            justification="A is sharper.", raw_100=self.OVER)

        self.assertEqual(response.final_max, 2)
        self.assertEqual(response.final_mark, 1.0)
        self.assertEqual(response.mcq_mark, 1.0)

    def test_the_scoring_lane_closes_the_component_instead_of_waiting(self):
        """A STANDARD-LESS COMPARISON MUST REACH A TERMINAL `llm_state`.

        `needs_llm` is true here - the candidate picked a verdict - so the
        awaiting-scoring counters and the attempt's own state watch this row.
        `_image_ab_uses_llm` sends it down `_store_ab_verdict_only`, which
        settles it without an LLM call. Were it left at "pending" the whole
        attempt would wait on a score that is never coming.
        """
        question, dims = self._bare_ab_question()
        evaluator = self._evaluator(self._assessment(question))
        evaluator.state = "submitted"
        response = self._response(
            evaluator, question, picks=[self._pick(dims[0], 0)],
            justification="A is sharper.")

        self.assertTrue(
            response.needs_llm,
            "a verdict was picked, so the row is in the scoring population")
        self.assertFalse(
            response._image_ab_uses_llm(),
            "with no standard there is nothing for the judge to mark against")

        from odoo.addons.assessments_be_v2.services import scoring as svc
        svc._store_ab_verdict_only(response)

        self.assertEqual(
            response.llm_state, "scored",
            "the component has to CLOSE, or the attempt hangs at pending")
        self.assertEqual(response.llm_max_score, 0)
        self.assertEqual(response.final_max, 1)
        self.assertEqual(response.final_mark, 1.0)


class TestTheRawAndTheMarkShareADenominator(_Base):
    """The mixed paper from the bug report, pinned end to end.

    THE REPORTED SYMPTOM. An attempt on a 5-question paper - three
    multiple-choice, two written - showed "Raw score 1.40 / 2" beside a mark of
    "3 / 5". Both figures were correct under the rules of the day and together
    they were unreadable: the three multiple-choice questions were absent from
    the raw's numerator AND denominator, so two numbers describing one paper
    were quoted out of two different totals, with the multiple-choice rows
    showing a bare dash in the RAW column.

    Every number in this class is the one that screen must now show.
    """

    THRESHOLD = 60.0

    def _mixed_paper(self, mcq_correct=(False, True, False), raws=(80.0, 60.0)):
        """Three single-part MCQs and two written answers, on one paper.

        `mcq_correct` says which of the three were answered exactly right;
        `raws` are the grader's 0-100 for the two written answers.
        """
        mcqs = []
        for i, _right in enumerate(mcq_correct, start=1):
            question = self._question("mcq", "Objective %d" % i)
            self._dimension(question, "Part 1")
            mcqs.append(question)
        written = [self._question("subjective_rubric", "Written %d" % i)
                   for i in range(1, len(raws) + 1)]

        paper = self.Question.browse(
            [q.id for q in mcqs] + [q.id for q in written])
        evaluator = self._evaluator(
            self._assessment(paper, threshold=self.THRESHOLD))
        evaluator.state = "submitted"

        for question, right in zip(mcqs, mcq_correct):
            dimension = question.question_dimension_ids
            self._response(evaluator, question,
                           picks=[self._pick(dimension, 0 if right else 1)])
        for question, raw in zip(written, raws):
            self._response(evaluator, question,
                           justification="An answer worth %s." % raw,
                           raw_100=raw)
        return evaluator

    def test_the_reported_attempt_now_reads_two_point_four_out_of_five(self):
        """The exact figures from the screenshot, in one assertion block.

        Marks 3 / 5 is unchanged - this change never touched what a candidate
        earns. The raw moves from "1.40 / 2" to "2.40 / 5": the same 1.40 from
        the two written answers, plus the 1.00 the one correct multiple-choice
        question was always worth, over the paper's real length.
        """
        evaluator = self._mixed_paper()

        self.assertEqual(evaluator.score_marks_display, "3 / 5")
        self.assertAlmostEqual(evaluator.raw_result, 2.40, places=3)
        self.assertEqual(evaluator.raw_max, 5)
        self.assertAlmostEqual(evaluator.raw_percent, 48.0, places=2)

    def test_the_two_denominators_are_the_same_number(self):
        """The invariant behind the fix, stated without reference to a paper.

        Asserted for several shapes rather than one, because the failure this
        guards against is a component type that grows the marks and forgets the
        raw - which would reappear as a raw out of the wrong total on exactly
        the papers that contain it.
        """
        for mcq_correct, raws in (((True, True, True), (90.0, 90.0)),
                                  ((False, False, False), (10.0, 10.0)),
                                  ((False, True, False), (80.0, 60.0))):
            with self.subTest(mcq=mcq_correct, raws=raws):
                evaluator = self._mixed_paper(mcq_correct, raws)
                _marks, raw_possible = evaluator._paper_component_totals()
                possible = int(
                    evaluator.score_marks_display.partition("/")[2].strip())
                self.assertEqual(
                    raw_possible, possible,
                    "the raw and the mark must be quoted out of one total")
                self.assertEqual(evaluator.raw_max, possible)

    def test_each_answer_row_carries_the_raw_the_table_prints(self):
        """The RAW column, per row: a decimal on the component scale.

        The screen used to print the grader's 0-100 for a written answer and a
        dash for everything else. It now prints `raw_score`, so the column adds
        up to the total above it - which the two previous shapes could not.
        """
        evaluator = self._mixed_paper()
        by_name = {r.question_id.name.split()[0]: r
                   for r in evaluator.response_ids}
        raws = sorted(round(r.raw_score, 2) for r in evaluator.response_ids)

        self.assertEqual(raws, [0.0, 0.0, 0.6, 0.8, 1.0])
        self.assertAlmostEqual(
            sum(r.raw_score for r in evaluator.response_ids),
            evaluator.raw_result, 3,
            "the column must sum to the total printed above it")
        self.assertTrue(
            all(r.raw_max == r.final_max for r in evaluator.response_ids),
            "every answer's raw is out of its own component count")
        self.assertEqual(by_name["Objective"].raw_max, 1)

    def test_a_written_answer_is_where_the_two_readings_diverge(self):
        """And the only place they can.

        A written answer graded 80 against a threshold of 60 earns its mark AND
        records 0.80. That 0.20 gap is the entire reason the raw exists; if the
        two numbers ever agreed everywhere, one of them would be redundant.
        """
        evaluator = self._mixed_paper(mcq_correct=(True, True, True),
                                      raws=(80.0, 60.0))

        self.assertEqual(evaluator.score_marks_display, "5 / 5")
        self.assertAlmostEqual(evaluator.raw_result, 4.40, places=3)
        self.assertGreater(
            evaluator.score_percent, evaluator.raw_percent,
            "a paper that cleared every bar without perfect quality must read "
            "lower on the raw than on the marks")
