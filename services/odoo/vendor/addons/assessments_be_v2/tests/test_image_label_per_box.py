"""A labelling answer is marked BOX BY BOX, and the boxes are stored raw.

WHAT THE UNIT IS. An `image_label` question is one component and therefore one
mark, whatever its box count - otherwise a 20-box labelling item would outweigh
five MCQs. What decides that mark is every box on its own:
`services/scoring._apply_image_label_boxes` writes the judge's 0-100 for EACH box
into `label_box_scores_json`, and `_label_marks` then thresholds each box
individually and tests the share that cleared against the same bar.

THE GUARANTEE THAT COSTS THE MOST TO LOSE: moving the assessment's threshold
re-decides a labelling answer with NO LLM CALL. That is why the per-box raws are
stored raw and nothing about pass or fail is written at scoring time - freezing
any part of the mark would force an admin correcting a mis-set threshold to
re-run the grader over every labelling answer in the cohort, which costs money
and is not reproducible.
`test_a_threshold_edit_re_decides_the_mark_with_no_llm_call` pins it by patching
the grader to blow up if it is reached at all.

WHAT `_apply_image_label_boxes` ENFORCES OVER THE JUDGE, each with a case below,
because each is a way the judge is known to be generous or wrong:

  * A box the candidate never attempted scores 0 whatever the judge said.
    Judges reward a plausible-looking blank surprisingly often, and a box with
    nothing in it cannot have been answered well. "Attempted" needs 2 non-space
    characters, so padding every box with "x" farms nothing.
  * A box outside the golden key is DROPPED. The judge does not get to invent
    boxes and score them - inventing generous ones would raise the mean.
  * A box the judge omitted scores 0 AND STILL COUNTS. The denominator is the
    question's own box count, so a judge that returns one box out of twenty
    cannot make a one-box answer read as complete.

The old whole-item coverage ceiling (clamping the score to 100*attempted/total)
is gone and is not missed: it was a proxy for "you cannot score on boxes you
never addressed", and scoring those boxes 0 says the same thing exactly.

`subjective_threshold` is PINNED on every fixture rather than left to
`DEFAULT_SUBJECTIVE_THRESHOLD`. It is both the per-box bar and the bar the
cleared-share is tested against, so reading a deployment's tuned default would
make these tests mean something different on every database.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.constants import DEFAULT_IMAGE_LABEL_COUNT
from odoo.addons.assessments_be_v2.services import scoring as scoring_svc
from odoo.addons.assessments_be_v2.services import vertex as vertex_svc


@tagged("-at_install", "post_install")
class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Generator = self.env["assessments.be.prompt"]
        self.Question = self.env["assessments.be.question"]
        self.Image = self.env["assessments.be.question.image"]
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.Generator.create(
            {"name": "UI labelling %s" % uuid4().hex[:6]})

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _label_question(self, boxes=DEFAULT_IMAGE_LABEL_COUNT, expected=0):
        """One image_label question whose golden key has `boxes` entries.

        The key lives on the question's `single` image as
        `behavioural_key_json`, which is where `_label_total_boxes` reads the
        box count from - and that count IS the denominator, so the fixture has
        to build it the way the platform does rather than assert a number.

        The default is `DEFAULT_IMAGE_LABEL_COUNT` rather than a literal 20 so
        that retuning the module default retunes the fixture with it.

        `expected` is the "any N of M" count. It is LEFT OFF the create vals
        when 0 rather than written as 0, so every case below that does not ask
        for a subset builds the identical row it built before the field
        existed - the point being that those cases must still be marked the
        old way, and a fixture that wrote the field would be quietly proving
        something weaker.
        """
        question = self.Question.create({
            "name": "Label the controls %s" % uuid4().hex[:6],
            "question_type": "image_label",
            "prompt": "Describe what each numbered control does.",
            "generator_id": self.generator.id,
        })
        image_vals = {
            "question_id": question.id,
            "label": "Screenshot",
            "slot": "single",
            "behavioural_key_json": json.dumps([
                {"number": n,
                 "element": "Control %d" % n,
                 "functionality": "Does thing %d" % n}
                for n in range(1, boxes + 1)
            ]),
        }
        if expected:
            image_vals["label_expected_count"] = expected
        self.Image.create(image_vals)
        return question

    def _assessment(self, question, threshold):
        return self.Assessment.create({
            "name": "Labelling paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, question.ids)],
            "subjective_threshold": threshold,
        })

    def _answer(self, assessment, question, answers, box_raws=None,
                scored=True):
        """One submitted labelling answer.

        `answers` is the candidate's {box number: text}, stored as JSON in
        `justification` exactly as the candidate path stores it - a labelling
        answer shares that column with written prose, which is why
        `image_label` is a LABELLING component and never also a subjective one.

        `box_raws` is the grader's per-box 0-100, written straight into
        `label_box_scores_json`. Writing it directly is the point of these
        tests: the mark has to be derivable from the stored raws alone.
        """
        applicant = self.Applicant.create({
            "partner_name": "Candidate %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:8],
        })
        evaluator = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        vals = {
            # `response_ids` on the evaluator is keyed on THIS field;
            # `evaluator_id` is the hr.applicant, not the assignment.
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "assessment_id": assessment.id,
            "state": "submitted",
            "justification": json.dumps(
                {str(k): v for k, v in answers.items()}),
        }
        if box_raws is not None:
            vals["label_box_scores_json"] = json.dumps(
                {str(k): v for k, v in box_raws.items()})
        if scored:
            # The item's own 0-100 is the MEAN of the box raws
            # (`composed_raw_100`). It is display/rollup only - never the mark -
            # so it is stamped for realism and asserted on nowhere.
            vals.update({
                "llm_state": "scored",
                "llm_raw_100": (
                    sum(box_raws.values()) / len(box_raws)
                    if box_raws else 0.0),
            })
        response = self.Response.create(vals)
        evaluator.state = "submitted"
        return evaluator, response

    @staticmethod
    def _full_answers(boxes):
        """Every box attempted with a real label (>= 2 non-space chars)."""
        return {n: "Control %d opens the menu" % n for n in range(1, boxes + 1)}


class TestLabelBoxRawsDecideTheMark(_Base):
    """The stored per-box raws are the mark's only source of truth."""

    BOXES = DEFAULT_IMAGE_LABEL_COUNT
    CLEARED = 18

    def _eighteen_of_twenty(self, threshold):
        """18 boxes graded 100, 2 graded 10 - a 0.9 share, at any bar in
        between. The cleared boxes sit at 100 on purpose: they must stay
        cleared when the bar moves to 95, so the FRACTION is constant across
        both cases and only the fraction's own threshold test flips.
        """
        question = self._label_question(self.BOXES)
        assessment = self._assessment(question, threshold)
        raws = {n: (100.0 if n <= self.CLEARED else 10.0)
                for n in range(1, self.BOXES + 1)}
        evaluator, response = self._answer(
            assessment, question, self._full_answers(self.BOXES), raws)
        return assessment, evaluator, response

    def test_the_cleared_share_is_the_fraction(self):
        _a, _ev, response = self._eighteen_of_twenty(60.0)

        self.assertAlmostEqual(
            response.label_fraction, 0.9, places=4, msg="18 of 20 boxes over the bar is a 0.9 share - the denominator is "
            "the question's box count, never the boxes the judge returned")
        self.assertEqual(response.llm_score, 1)
        self.assertEqual(
            response.final_mark, 1.0,
            "the labelling component is ONE mark however many boxes it has")
        self.assertEqual(response.final_max, 1)
        self.assertEqual(response.raw_max, 1)

    def test_a_threshold_edit_re_decides_the_mark_with_no_llm_call(self):
        """THE guarantee this file exists for.

        The same stored raws, read against a 60 bar and then a 95 bar, produce
        a mark of 1 and then a mark of 0 - and the grader is patched to raise
        if anything reaches it, so the flip demonstrably costs no LLM call.
        `llm_attempts` is asserted unchanged as the second, independent
        witness: `_store_scored` is the only thing that increments it, so a
        still-zero counter proves nothing re-scored.

        The FRACTION is identical in both readings. That is deliberate: it
        isolates the change to the fraction's own threshold test, so a
        regression that started re-deriving the fraction from something frozen
        at grading time shows up here rather than hiding behind a mark that
        happened to move for another reason.
        """
        assessment, _ev, response = self._eighteen_of_twenty(60.0)
        boom = AssertionError(
            "the grader was called while re-deciding a stored labelling "
            "answer - the per-box raws exist precisely so a threshold edit "
            "costs nothing")

        with patch.object(vertex_svc, "_call_vertex", side_effect=boom), \
                patch.object(scoring_svc, "_score_submission",
                             side_effect=boom), \
                patch.object(scoring_svc, "score_evaluator", side_effect=boom):
            self.assertAlmostEqual(response.label_fraction, 0.9, places=4)
            self.assertEqual(
                response.llm_score, 1,
                "a 0.9 share clears a 60 bar")

            assessment.subjective_threshold = 95.0

            self.assertAlmostEqual(
                response.label_fraction, 0.9, places=4,
                msg="the share of boxes that cleared must not move: every box "
                "that cleared 60 was graded 100 and clears 95 too")
            self.assertEqual(
                response.llm_score, 0,
                "a 0.9 share does not clear a 95 bar - the mark has to be "
                "re-decided from the stored raws, not read from something "
                "frozen when the judge ran")
            self.assertEqual(response.final_mark, 0.0)

        self.assertEqual(
            response.llm_attempts, 0,
            "llm_attempts moved, so something re-scored the answer")

    def test_the_raw_is_the_ungated_mean_of_the_box_raws(self):
        """Per-box raws summing to 12.5 (in 0-1 terms) over 20 boxes is 0.625.

        The raw is the twin of the mark, not a restatement of it: it is the
        mean of every box's own 0-100, divided by 100, with NO threshold
        anywhere in it. Ten boxes graded 100 and ten graded 25 sum to 1250 out
        of 2000 - a mean of 62.5 - and the answer's raw is 0.625 whatever bar
        the assessment is set to.
        """
        boxes = DEFAULT_IMAGE_LABEL_COUNT
        question = self._label_question(boxes)
        assessment = self._assessment(question, 60.0)
        raws = {n: (100.0 if n <= 10 else 25.0) for n in range(1, boxes + 1)}
        self.assertAlmostEqual(sum(raws.values()) / 100.0, 12.5, places=6)

        evaluator, response = self._answer(
            assessment, question, self._full_answers(boxes), raws)

        self.assertAlmostEqual(
            response.raw_score, 0.625, places=4,
            msg="the labelling raw is the ungated mean of the per-box raws")
        self.assertEqual(response.raw_max, 1)
        self.assertAlmostEqual(evaluator.raw_result, 0.625, places=3)
        self.assertAlmostEqual(evaluator.raw_percent, 62.5, places=2)

    def test_the_raw_does_not_move_when_the_threshold_does(self):
        """The mark and the raw are meant to disagree - that is why both exist.

        A raw that tracked the threshold would be a second copy of the mark,
        and the "by how much" column would answer the same question as the
        "did they clear it" column.
        """
        assessment, _ev, response = self._eighteen_of_twenty(60.0)
        before = response.raw_score

        assessment.subjective_threshold = 95.0

        self.assertEqual(response.llm_score, 0)
        self.assertAlmostEqual(response.raw_score, before, places=4)
        self.assertAlmostEqual(
            response.raw_score, (18 * 100.0 + 2 * 10.0) / 20 / 100.0, places=4)

    def test_the_denominator_is_the_questions_box_count(self):
        """Answering one box perfectly is 1/20, not 1/1.

        The stored raws carry only the box the judge scored; the mark is still
        taken over every box in the golden key, or a candidate who filled in
        one box and got it right would read as a perfect score.
        """
        boxes = DEFAULT_IMAGE_LABEL_COUNT
        question = self._label_question(boxes)
        assessment = self._assessment(question, 60.0)

        _ev, response = self._answer(
            assessment, question,
            {1: "The save button commits the form"}, {1: 100.0})

        self.assertAlmostEqual(response.label_fraction, 1.0 / boxes, places=4)
        self.assertEqual(response.llm_score, 0)
        self.assertAlmostEqual(response.raw_score, 1.0 / boxes, places=4)

    def test_an_ungraded_answer_earns_nothing_and_still_costs_its_mark(self):
        """`llm_state` short of 'scored' means there is no result to read.

        It must not be read as a zero-score result either: the component stays
        in `final_max`, so the paper's length is unchanged and the attempt
        stays pending rather than finalising a wrongful 0.
        """
        boxes = DEFAULT_IMAGE_LABEL_COUNT
        question = self._label_question(boxes)
        assessment = self._assessment(question, 60.0)

        _ev, response = self._answer(
            assessment, question, self._full_answers(boxes),
            {n: 100.0 for n in range(1, boxes + 1)}, scored=False)

        self.assertEqual(response.llm_score, 0)
        self.assertEqual(response.label_fraction, 0.0)
        self.assertEqual(response.final_max, 1)
        self.assertEqual(response.final_mark, 0.0)


class TestApplyImageLabelBoxesOverridesTheJudge(_Base):
    """`_apply_image_label_boxes` is tested DIRECTLY, and has to be.

    Its whole job is disagreeing with the judge, so a test that went through
    the live grading path would be asserting on whatever the judge happened to
    return that day. Feeding it a hand-written judge result is the only way to
    pin "the judge said 95 and the platform says 0".
    """

    BOXES = 4

    def _resp(self, answers):
        question = self._label_question(self.BOXES)
        assessment = self._assessment(question, 60.0)
        _ev, response = self._answer(
            assessment, question, answers, scored=False)
        return response

    def test_an_unattempted_box_scores_zero_however_well_the_judge_graded_it(
            self):
        """Boxes 3 and 4 hold a single character and a space - not answers.

        A single letter is a slip, or a farm: letting "x" count would let a
        worker push coverage to 100% and collect the judge's generosity on
        boxes they never read. The judge here graded both highly, which is the
        realistic case rather than a contrived one.
        """
        response = self._resp({
            1: "Save button commits the form",
            2: "Cancel discards the draft",
            3: "x",
            4: "   ",
        })

        out = scoring_svc._apply_image_label_boxes(
            response, {"box_scores": {"1": 90, "2": 80, "3": 95, "4": 100}})

        self.assertEqual(
            out["box_scores"],
            {"1": 90.0, "2": 80.0, "3": 0.0, "4": 0.0},
            "a box with nothing in it cannot have been answered well, "
            "whatever the judge returned for it")
        self.assertEqual(out["label_scores"]["attempted_boxes"], 2)
        self.assertEqual(out["label_scores"]["total_boxes"], self.BOXES)
        self.assertAlmostEqual(
            out["composed_raw_100"], (90.0 + 80.0) / 4, places=4,
            msg="the unattempted boxes must be zeros IN the mean, not missing "
            "from it - dropping them would shrink the denominator")

    def test_a_box_outside_the_golden_key_is_dropped(self):
        """The judge does not get to invent boxes and score them.

        Box 5 and box 99 are not in a 4-box key. Keeping them would put
        invented marks in the numerator and, worse, would let a judge inflate
        an answer by inventing boxes it liked.
        """
        response = self._resp(self._full_answers(self.BOXES))

        out = scoring_svc._apply_image_label_boxes(response, {"box_scores": {
            "1": 50, "2": 50, "3": 50, "4": 50, "5": 100, "99": 100}})

        self.assertEqual(sorted(out["box_scores"]), ["1", "2", "3", "4"])
        self.assertNotIn("5", out["box_scores"])
        self.assertNotIn("99", out["box_scores"])
        self.assertAlmostEqual(
            out["composed_raw_100"], 50.0, places=4,
            msg="the invented boxes reached the mean")

    def test_a_box_the_judge_omitted_scores_zero_and_still_counts(self):
        """A one-box judge reply must not make a one-box answer look complete.

        The candidate attempted all four; the judge returned one. The other
        three are the judge's failure, but they cannot be dropped from the
        denominator - that would read as a perfect score on a quarter of the
        work.
        """
        response = self._resp(self._full_answers(self.BOXES))

        out = scoring_svc._apply_image_label_boxes(
            response, {"box_scores": {"1": 100}})

        self.assertEqual(
            out["box_scores"], {"1": 100.0, "2": 0.0, "3": 0.0, "4": 0.0})
        self.assertEqual(
            len(out["box_scores"]), self.BOXES,
            "the denominator is the question's box count, not the judge's")
        self.assertEqual(out["label_scores"]["boxes_returned_by_judge"], 1)
        self.assertAlmostEqual(out["composed_raw_100"], 25.0, places=4)

    def test_a_judge_that_returned_nothing_at_all_scores_every_box_zero(self):
        """The degenerate end of the case above, kept because it is the shape
        a truncated or unparsed judge reply actually arrives in."""
        response = self._resp(self._full_answers(self.BOXES))

        out = scoring_svc._apply_image_label_boxes(response, {})

        self.assertEqual(set(out["box_scores"].values()), {0.0})
        self.assertEqual(len(out["box_scores"]), self.BOXES)
        self.assertEqual(out["composed_raw_100"], 0.0)


class TestAnyNOfMIsMarkedOutOfN(_Base):
    """"Mark any THREE of these five" has to be marked out of three.

    THE DEFECT. `annotation_expected_count` has been on the task template all
    along and reached the generation directive - the model was told "a complete
    answer marks 3 item(s)" - but nothing carried it any further. By the time a
    candidate's answer was marked, the only count in reach was
    `_label_total_boxes`, so a candidate who marked exactly the three they were
    asked for was divided by all five and scored 0.6: a fail against any bar
    above 60, earned by doing the task exactly right.

    WHAT DECIDES IT NOW. `label_expected_count` on the `single` image is the
    denominator, and the candidate chooses WHICH boxes fill it: their best N by
    raw, taken from the boxes they actually attempted. Both halves of that
    follow from what the task said. It invited them to pick, so a fourth box
    they labelled badly is extra work rather than a wrong answer and must not
    be able to cost them anything. And it asked for N, so attempting two of
    three is a short answer - the missing one scores 0 and STAYS in the
    denominator, or leaving boxes blank would shrink the paper.

    "ATTEMPTED" IS NOT REDEFINED HERE. It is `_label_attempted_box_numbers`,
    the same >= 2 non-space characters rule `_apply_image_label_boxes` zeroes
    boxes with. A second definition would drift from the first and the two
    would disagree about one answer.

    Unset (0) is every question authored before this existed, and those must
    be marked exactly as they were - which is the first case below.
    """

    BOXES = 5
    EXPECTED = 3

    def _answers(self, numbers):
        """The candidate's answer for `numbers` and nothing in the rest.

        Each label is a real one (>= 2 non-space characters), so what these
        cases vary is HOW MANY boxes were attempted - never whether the
        attempt rule fired.
        """
        return {n: "Control %d opens the menu" % n for n in numbers}

    def test_an_unset_count_still_divides_by_the_whole_key(self):
        """The pin on today's behaviour, restating the 18-of-20 case above.

        `TestLabelBoxRawsDecideTheMark` asserts these same numbers on a
        question that never had the field. This asserts them again from the
        other side - that the resolver hands back the key's own box count when
        nobody asked for a subset - because the two are the same guarantee and
        only the resolver can be got wrong by a later edit.
        """
        boxes = DEFAULT_IMAGE_LABEL_COUNT
        question = self._label_question(boxes)
        assessment = self._assessment(question, 60.0)

        self.assertEqual(
            scoring_svc._label_expected_boxes(question, boxes), boxes,
            "an unset count must derive the denominator from the key, which "
            "is every box in it")

        raws = {n: (100.0 if n <= 18 else 10.0) for n in range(1, boxes + 1)}
        _ev, response = self._answer(
            assessment, question, self._full_answers(boxes), raws)

        self.assertAlmostEqual(response.label_fraction, 0.9, places=4)
        self.assertEqual(response.llm_score, 1)
        self.assertAlmostEqual(
            response.raw_score, (18 * 100.0 + 2 * 10.0) / boxes / 100.0,
            places=4)

    def test_marking_exactly_the_three_asked_for_is_full_marks(self):
        """THE case the whole change exists for.

        Five boxes on the image, three requested, three marked, all three
        graded 100. That is a complete answer and it has to read as one: under
        the old denominator it was 3/5 = 0.6 and failed every bar above 60.
        """
        question = self._label_question(self.BOXES, expected=self.EXPECTED)
        assessment = self._assessment(question, 70.0)

        _ev, response = self._answer(
            assessment, question, self._answers([1, 2, 3]),
            {1: 100.0, 2: 100.0, 3: 100.0})

        self.assertAlmostEqual(
            response.label_fraction, 1.0, places=4,
            msg="three of three requested boxes cleared - the two boxes the "
            "task did not ask about are not part of the denominator")
        self.assertEqual(response.llm_score, 1)
        self.assertEqual(response.final_mark, 1.0)
        self.assertAlmostEqual(response.raw_score, 1.0, places=4)

    def test_a_short_answer_keeps_the_full_expected_denominator(self):
        """Two of the three asked for. The third is UNANSWERED, not excused.

        The denominator stays 3, so this is 2/3 - not the 2/2 it would be if
        the missing box shrank the paper. That distinction is the whole reason
        the denominator is `expected` and not "however many they attempted":
        the latter hands full marks to anyone who answers one box well and
        leaves the rest blank.
        """
        question = self._label_question(self.BOXES, expected=self.EXPECTED)
        assessment = self._assessment(question, 60.0)

        _ev, response = self._answer(
            assessment, question, self._answers([1, 2]),
            {1: 100.0, 2: 100.0})

        self.assertAlmostEqual(
            response.label_fraction, 2.0 / 3.0, places=4,
            msg="the box they never attempted has to stay in the denominator")
        self.assertNotAlmostEqual(
            response.label_fraction, 1.0, places=4,
            msg="attempting fewer boxes must never shrink the denominator to "
            "the number attempted")
        self.assertAlmostEqual(
            response.raw_score, 2.0 / 3.0, places=4,
            msg="the raw is the mean over `expected`, so the shortfall is a "
            "zero in it rather than missing from it")

        # And the shortfall has to COST something. 0.667 clears a 60 bar and
        # does not clear a 70 one, which is the same stored answer read twice -
        # the guarantee this file exists for, exercised on the new path.
        assessment.subjective_threshold = 70.0

        self.assertEqual(
            response.llm_score, 0,
            "two of the three boxes asked for is a 0.667 share, which does "
            "not clear a 70 bar")

    def test_the_best_three_decide_it_and_a_bad_extra_box_costs_nothing(self):
        """The task said "any three", so a fourth box is extra work.

        Two answers to the same question: one marks exactly the three asked
        for, the other marks all five and makes a mess of the extra two. The
        mark, the fraction and the raw must be identical. If labelling more
        than you were asked to could lower your mark, the honest reading of
        "any three of these five" would be a trap.
        """
        question = self._label_question(self.BOXES, expected=self.EXPECTED)
        assessment = self._assessment(question, 60.0)

        _ev, exact = self._answer(
            assessment, question, self._answers([1, 2, 3]),
            {1: 100.0, 2: 100.0, 3: 100.0})
        _ev2, generous = self._answer(
            assessment, question, self._answers([1, 2, 3, 4, 5]),
            {1: 100.0, 2: 100.0, 3: 100.0, 4: 0.0, 5: 5.0})

        self.assertAlmostEqual(generous.label_fraction, 1.0, places=4)
        self.assertEqual(generous.llm_score, 1)
        self.assertAlmostEqual(
            generous.label_fraction, exact.label_fraction, places=4,
            msg="labelling two extra boxes badly changed the fraction")
        self.assertAlmostEqual(
            generous.raw_score, exact.raw_score, places=4,
            msg="labelling two extra boxes badly changed the raw")
        self.assertEqual(generous.final_mark, exact.final_mark)

    def test_the_raw_uses_the_same_best_three_as_the_mark(self):
        """The raw is the ungated twin of the mark, not a different answer.

        All five boxes attempted, graded 100/90/80/20/0. The best three are
        100/90/80, so the raw is 0.9. The mean over all five would be 0.58 and
        the mean over the three attempted worst would be lower still - both
        are asserted against, because a raw that selected differently from the
        mark would put two disagreeing numbers on one answer and nobody could
        say which was the truth.
        """
        question = self._label_question(self.BOXES, expected=self.EXPECTED)
        assessment = self._assessment(question, 60.0)

        _ev, response = self._answer(
            assessment, question, self._answers([1, 2, 3, 4, 5]),
            {1: 100.0, 2: 90.0, 3: 80.0, 4: 20.0, 5: 0.0})

        self.assertAlmostEqual(
            response.raw_score, (100.0 + 90.0 + 80.0) / 3 / 100.0, places=4,
            msg="the raw must be the mean of the SAME best three the mark was "
            "decided on")
        self.assertNotAlmostEqual(
            response.raw_score, (100.0 + 90.0 + 80.0 + 20.0) / 5 / 100.0,
            places=4,
            msg="the raw fell back to the mean over every box in the key")
        self.assertAlmostEqual(
            response.label_fraction, 1.0, places=4,
            msg="all three of the best boxes cleared the 60 bar")

    def test_an_expected_count_larger_than_the_key_is_clamped_to_it(self):
        """A template asking for 5 marks on a 3-box question.

        That is an authoring slip, and the candidate must not pay for it: an
        unclamped denominator of 5 caps a perfect answer at 0.6 and makes the
        question unpassable at any sensible bar. The boxes are the harder fact
        - they are drawn on the image in front of the candidate - so the count
        gives way to them.
        """
        question = self._label_question(3, expected=5)
        assessment = self._assessment(question, 70.0)

        self.assertEqual(
            scoring_svc._label_expected_boxes(question, 3), 3,
            "the denominator cannot exceed the boxes that exist")

        _ev, response = self._answer(
            assessment, question, self._answers([1, 2, 3]),
            {1: 100.0, 2: 100.0, 3: 100.0})

        self.assertAlmostEqual(
            response.label_fraction, 1.0, places=4,
            msg="full marks have to be reachable on a question whose expected "
            "count was authored above its own box count")
        self.assertEqual(response.llm_score, 1)
        self.assertAlmostEqual(response.raw_score, 1.0, places=4)


class TestTheExpectedCountReachesTheQuestion(_Base):
    """The count is useless on the template; these are the two hops it makes.

    `annotation_expected_count` lived on `assessments.be.task.template` and got
    as far as the generation directive, and no further. Scoring reads
    `label_expected_count` off the bank question's `single` image, so the count
    has to travel template -> draft -> question or the rule above never fires
    on a real paper - which is exactly the state this change found the module
    in.
    """

    def _template(self, **extra):
        return self.env["assessments.be.task.template"].create(dict({
            "name": "Mark any three %s" % uuid4().hex[:6],
            "response": "annotate_image",
            "structure_json": [
                {"title": "S",
                 "items": [{"kind": "shortText", "title": "Mark them."}]}],
        }, **extra))

    def test_an_explicit_count_is_carried_onto_the_resolved_shape(self):
        template = self._template(
            annotation_targets="A\nB\nC\nD\nE",
            annotation_expected_count=3)
        shape = "template:%d" % template.id

        specs = vertex_svc._resolve_template_shapes(self.env, {shape: 1})

        self.assertEqual(
            specs[shape]["annotation_expected_count"], 3,
            "the examiner's own 'any three of these five' has to reach the "
            "draft builder, not just the model's directive")

    def test_a_targets_only_template_carries_no_count(self):
        """The contract fills a blank count in from the target list. That is
        the right thing to TELL the model and the wrong thing to grade
        against: listing five targets is not asking for a subset, and stamping
        5 on the draft would move the denominator off the question's own boxes
        for every template that never asked for one. Only a number the
        examiner typed means "fewer than all of them".
        """
        template = self._template(annotation_targets="A\nB\nC")
        shape = "template:%d" % template.id

        specs = vertex_svc._resolve_template_shapes(self.env, {shape: 1})

        self.assertEqual(
            template.answer_contract()["annotation_expected_count"], 3,
            "the directive still tells the model how many marks to author")
        self.assertEqual(
            specs[shape]["annotation_expected_count"], 0,
            "a derived count must not become a grading denominator")

    def _draft(self, **extra):
        return self.env["assessments.be.prompt.question"].create(dict({
            "prompt_id": self.generator.id,
            "name": "Label any three %s" % uuid4().hex[:6],
            "question_prompt": "Mark any three of the five controls.",
            "question_type": "image_label",
            "images_json": json.dumps(
                [{"slot": "single", "label": "Screenshot"}]),
            "behavioural_key_json": json.dumps([
                {"number": n, "element": "Control %d" % n,
                 "functionality": "Does thing %d" % n}
                for n in range(1, 6)]),
        }, **extra))

    def _approve(self, draft):
        # `skip_image_ready_guard` because the draft here carries no rendered
        # image - the guard exists to stop an admin publishing a question with
        # a missing picture, which is not what is under test.
        draft.with_context(skip_image_ready_guard=True).action_approve()
        return draft.approved_question_id

    def test_approving_a_draft_carries_the_count_onto_the_image(self):
        question = self._approve(self._draft(label_expected_count=3))

        image = question.image_ids.filtered(lambda i: i.slot == "single")
        self.assertEqual(
            image.label_expected_count, 3,
            "the count has to land on the `single` image - that is the only "
            "place scoring looks for it")
        self.assertEqual(
            scoring_svc._label_expected_boxes(
                question, scoring_svc._label_total_boxes(question)), 3,
            "a five-box question authored from an 'any three' template is "
            "marked out of three")

    def test_a_draft_with_no_count_leaves_the_key_deciding(self):
        """Every draft in the bank today. Approving one must not start writing
        a denominator onto questions that never asked for one."""
        question = self._approve(self._draft())

        image = question.image_ids.filtered(lambda i: i.slot == "single")
        self.assertEqual(image.label_expected_count, 0)
        self.assertEqual(
            scoring_svc._label_expected_boxes(question, 5), 5,
            "with no count carried the denominator is still every box in the "
            "key")
