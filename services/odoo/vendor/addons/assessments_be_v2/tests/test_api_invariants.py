"""The first unit tests for assessments_be_v2.

WHY THESE FOUR. The addon had 82 routes, ~6,100 lines and no test at all, so
every regression had to be caught by a live-server probe against a running
Odoo - which means it was caught late, by a person, if at all. Rather than
chase coverage, these cover the four things whose failure is *unrecoverable*
in front of a customer:

  1. the answer key never reaches an in-progress candidate  (INVARIANT 1)
  2. a score is never visible before a human releases it    (INVARIANT 3)
  3. releasing one candidate does not release the cohort
  4. subjective answers actually reach the grading queue

Each one has already been a real defect in this codebase, which is the reason
it is the thing being pinned rather than something merely plausible.

They are TransactionCase, not HttpCase: each asserts on the serializer or the
model the route delegates to, so the assertion is about behaviour rather than
about transport, and the suite stays fast enough to run on every change.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import serializers as S
from odoo.tools import mute_logger


@tagged("-at_install", "post_install")
class _Base(TransactionCase):
    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Generator = self.env["assessments.be.prompt"]

    def _applicant(self, name):
        slug = "%s_%s" % (name.lower().replace(" ", "_"), uuid4().hex[:8])
        email = "%s@example.com" % slug
        portal = self.env.ref("base.group_portal")
        user = self.env["res.users"].with_context(
            no_reset_password=True).create({
                "name": name, "login": email, "email": email,
                "group_ids": [(6, 0, [portal.id])],
            })
        return self.env["hr.applicant"].create({
            "partner_name": name,
            "email_from": email,
            "partner_id": user.partner_id.id,
            "be_candidate_user_id": user.id,
        })

    def _mcq(self, name="Q", correct_idx=0):
        """An mcq with a real key: three options, exactly one correct."""
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        q = self.Question.create({
            "name": name,
            "question_type": "mcq",
            "prompt": "Pick the right one",
            "difficulty": "easy",
            "generator_id": gen.id,
        })
        dim = self.QDim.create({
            "question_id": q.id,
            "name": "Dim %s" % name,
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": i * 10,
                        "is_correct": i == correct_idx})
                for i, n in enumerate(("Alpha", "Bravo", "Charlie"))
            ],
        })
        return q, dim.option_line_ids.sorted("sequence")


class TestAnswerKeyNeverLeaks(_Base):
    """INVARIANT 1 - nothing tells a candidate the answer mid-exam.

    The regression this pins: `/exam/<token>/review`, the pre-submit
    checklist, used to build its rows with what is now
    `released_answer_review_row`. For mcq/msq that emits `correct` - the NAMES
    of the right options - plus a live Correct/Incorrect verdict, to a
    candidate who has not submitted. It was gated only by a write guard, which
    an in-progress attempt passes by definition.
    """

    def test_released_row_carries_the_key_and_is_named_for_it(self):
        """The post-release builder DOES emit the key - that is its job.

        Asserted so the rename cannot be quietly undone: if this row ever stops
        carrying `correct`, the release view has silently lost its answer key
        and the test below stops proving anything.
        """
        q, opts = self._mcq(correct_idx=1)
        row = S.released_answer_review_row(1, q, self.Response.browse(), "tok")
        self.assertIn("correct", row)
        self.assertEqual(row["correct"], ["Bravo"],
                         "the released row must name the correct option")

    def test_mid_exam_question_cannot_represent_correctness(self):
        """The serializer a candidate actually receives, checked by SHAPE.

        `question_for_candidate` is what /state and /answer return. The check
        is on the whole payload rather than one field, because the original bug
        was a generic name picked up by the wrong caller - a test bound to one
        field would not have caught it.
        """
        forbidden = {"correct", "verdict", "kind", "score_raw", "feedback",
                     "deductions", "credit", "is_correct", "solution",
                     "official_reasoning", "grading"}
        q, opts = self._mcq(correct_idx=2)
        payload = S.question_for_candidate(q, "tok", 1, 1)

        self.assertFalse(
            forbidden & set(payload),
            "a mid-exam question payload leaked: %s"
            % sorted(forbidden & set(payload)))

        # And one level down: the options are where the key would hide.
        for dim in payload.get("dimensions", []):
            for opt in dim.get("options", []):
                self.assertNotIn(
                    "is_correct", opt,
                    "an option carried its correct flag to the candidate")

        # Positive control: the option the test marked correct IS present by
        # name, so the assertion above is about the FLAG being absent rather
        # than the option having been dropped.
        names = [o["name"] for d in payload.get("dimensions", [])
                 for o in d.get("options", [])]
        self.assertIn("Charlie", names)

    def test_the_leaky_name_is_gone(self):
        """`answer_review_row` must not exist under its old generic name.

        The rename to `released_answer_review_row` IS the fix: the name is the
        control. A future caller reaching for `answer_review_row` should get an
        AttributeError rather than the answer key.
        """
        self.assertFalse(
            hasattr(S, "answer_review_row"),
            "the generic name is back; a pre-submit caller can pick it up "
            "again exactly as /review once did")


class TestScoringMachineryStaysAdminOnly(_Base):
    """A candidate is told what they did. Never how the platform weighs it.

    The admin surfaces print the lane weights on purpose - a mark nobody can
    check is a mark nobody can defend, and an admin is the person who has to
    defend it. The candidate review is the opposite case. `key closeness 0.60`,
    `SOP coverage 0.25`, the per-component marks and maxima, the per-box
    labelling raws and the subjective threshold are the scoring machinery, and
    a candidate who learns how the paper is weighed learns which half of it to
    game rather than how to do the work.

    THE MACHINERY GOT MORE REVEALING, NOT LESS, when scoring moved to
    per-component marks. `final_max` and `objective_marks_max` map out how a
    question is built; `label_box_scores_json` says which individual labelling
    box the grader marked down, which is a list of exactly what to copy next
    sitting. Both are in FORBIDDEN_KEYS for that reason.

    `released_answer_review_row` is the ONLY builder behind the candidate's
    review, so the guarantee lives or dies here. It is asserted by SHAPE, not
    by hunting for a field name, because the way this breaks is somebody adding
    the judge's audit block wholesale to "give candidates more detail".
    """

    # The response columns that carry the machinery. Each is real and populated;
    # none may reach the candidate row under any key.
    FORBIDDEN_KEYS = {
        "reasoning", "llm_reasoning",       # the full internal scoring audit
        "key_closeness", "llm_key_closeness",
        "sop_coverage", "llm_sop_coverage",
        "clarity", "llm_clarity",
        "ab_verdict_pct", "ab_justification_pct", "ab_final_pct",
        "ab_mcq_pct", "subscores", "ab_scores",
        # The per-component marks. The two blended-raw columns that used to sit
        # here were deleted with the 0.75/0.25 blend they carried; scoring is
        # per component now. What replaced them is MORE revealing, not less -
        # `final_max` and `objective_marks_max` are a map of how the paper is
        # built, and `label_fraction` / `label_box_scores_json` say which
        # individual labelling boxes the grader marked down. A candidate who
        # learns that learns which boxes to copy next sitting.
        "final_mark", "final_max", "mcq_mark", "objective_marks_max",
        "raw_score", "raw_max", "label_fraction", "label_box_scores_json",
        # THE COLUMN NAMES STAY FORBIDDEN, and that is not a technicality the
        # sanctioned pair sneaks past. The line is WHAT the number says, not
        # what it is called:
        #
        #   * `marks_earned` / `marks_available` ARE sent, deliberately - they
        #     are the candidate's own result on their own answer, the same fact
        #     `score_marks` has always given them for the attempt as a whole.
        #     `test_the_candidate_gets_their_own_marks_as_a_pair` pins that.
        #   * `label_fraction` and `label_box_scores_json` are NOT, and must
        #     never be, whatever they are renamed to. They say which INDIVIDUAL
        #     boxes the grader marked down, which is the answer key read
        #     backwards: a candidate who learns box 7 scored 0 learns what to
        #     write in box 7 next sitting.
        #   * `raw_score` / `raw_max` are NOT: the raw is the ungated quality
        #     signal admins rank on, and it is not the candidate's mark.
        "llm_result_json", "llm_flags_json", "result_json",
        "grading", "judge", "judge_model", "llm_judge_model",
        "score_percent", "pass_threshold", "subjective_threshold",
        "transcription_threshold",
    }

    def _scored_answer(self):
        """One graded answer with EVERY audit column filled in.

        Populated, not blank: a row whose internals are all empty would satisfy
        a "did not leak" assertion by having nothing to leak, and would pass
        this test on the day the audit block was added.
        """
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        question = self.Question.create({
            "name": "Describe the defect",
            "question_type": "subjective_rubric",
            "prompt": "What is wrong with this render?",
            "generator_id": gen.id,
        })
        assessment = self.Assessment.create({
            "name": "Review leak %s" % uuid4().hex[:6],
            "generator_id": gen.id,
            "question_ids": [(6, 0, question.ids)],
            "subjective_threshold": 70.0,
        })
        applicant = self._applicant("Leak Candidate")
        evaluator = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        response = self.Response.create({
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "assessment_id": assessment.id,
            "state": "submitted",
            "justification": "The sofa is the wrong colour.",
            "llm_raw_100": 82.0,
            "llm_state": "scored",
            "llm_feedback": "You named the sofa precisely. Next time say why.",
            "llm_verdict": "Correct call, thinly argued.",
            "llm_reasoning": "internal: 3 of 4 components earned, raw 82.0",
            "llm_key_closeness": 61.0,
            "llm_sop_coverage": 44.0,
            "llm_clarity": "mixed",
            "llm_judge_model": "gemini-internal-only",
        })
        return question, response

    def _scored_label_answer(self):
        """A labelling answer with its PER-BOX raws filled in.

        A second fixture rather than a second field on the first, because
        `label_box_scores_json` and `label_fraction` only ever populate on an
        `image_label` question - a rubric answer would satisfy a "did not leak"
        assertion by having nothing in those columns to leak.

        The box the grader marked down (box 3, raw 10) is the leak that matters
        most: told which box was wrong, a candidate needs to fix one label
        rather than learn the screen.
        """
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        question = self.Question.create({
            "name": "Label the controls",
            "question_type": "image_label",
            "prompt": "Say what each numbered control does.",
            "generator_id": gen.id,
        })
        self.env["assessments.be.question.image"].create({
            "question_id": question.id,
            "label": "Screenshot",
            "slot": "single",
            "behavioural_key_json": json.dumps([
                {"number": n, "element": "Control %d" % n,
                 "functionality": "Does thing %d" % n}
                for n in range(1, 5)
            ]),
        })
        assessment = self.Assessment.create({
            "name": "Label leak %s" % uuid4().hex[:6],
            "generator_id": gen.id,
            "question_ids": [(6, 0, question.ids)],
            "subjective_threshold": 70.0,
        })
        applicant = self._applicant("Label Candidate")
        evaluator = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        response = self.Response.create({
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "assessment_id": assessment.id,
            "state": "submitted",
            "justification": json.dumps({
                "1": "Saves the draft", "2": "Cancels the edit",
                "3": "Opens the printer", "4": "Signs the user out"}),
            "label_box_scores_json": json.dumps(
                {"1": 100.0, "2": 90.0, "3": 10.0, "4": 95.0}),
            "llm_raw_100": 73.75,
            "llm_state": "scored",
            "llm_feedback": "Three of four read correctly.",
        })
        return question, response

    def test_the_candidate_review_carries_no_scoring_machinery(self):
        question, response = self._scored_answer()
        row = S.released_answer_review_row(1, question, response, "tok")

        leaked = self.FORBIDDEN_KEYS & set(row)
        self.assertFalse(
            leaked,
            "the candidate answer review leaked scoring machinery: %s. These "
            "belong on the admin surfaces (response_audit / attempt detail), "
            "which is where the weights are printed so a mark can be checked."
            % sorted(leaked))

    def test_the_candidate_gets_their_own_marks_as_a_pair(self):
        """The candidate's OWN result on their OWN answer is theirs to read.

        This is the other half of the invariant and it needs a test of its own,
        because a rule expressed only as a deny-list drifts one cautious
        omission at a time until the candidate is told nothing at all. The line
        is: what you scored, yes; how the platform decided it, no.

        A PAIR, NOT A NUMBER. `marks_earned` alone is unreadable now that a
        question can be worth more than 1 - "2" is a pass on a 2-mark question
        and a fail on a 5-mark one. The panel that groups these by skill needs
        the denominator to weight them, which is exactly what it lacked: it
        counted every question as 1, so a 3-mark question and a 1-mark question
        pulled a category average equally hard.
        """
        question, response = self._scored_answer()
        row = S.released_answer_review_row(1, question, response, "tok")

        self.assertIn("marks_earned", row)
        self.assertIn("marks_available", row)
        self.assertEqual(row["marks_earned"], response.final_mark)
        self.assertEqual(row["marks_available"], response.final_max)
        self.assertGreaterEqual(
            row["marks_available"], 1,
            "a question the candidate sat is worth at least one mark; a 0 "
            "denominator would make the category panel divide by zero")
        self.assertLessEqual(
            row["marks_earned"], row["marks_available"],
            "a candidate cannot earn more than the question is worth")

    def test_the_candidate_review_carries_no_per_box_labelling_scores(self):
        """The same guarantee on the columns that carry the most detail.

        `label_box_scores_json` is a per-box scoresheet and `label_fraction` is
        the share that cleared: between them they tell a candidate exactly
        which box to change. The row DOES carry their own answers back
        (`label_answers`) - that is the review - and the positive control below
        keeps this test honest about the difference.
        """
        question, response = self._scored_label_answer()
        row = S.released_answer_review_row(1, question, response, "tok")

        self.assertTrue(
            response.label_box_scores_json and response.label_fraction,
            "the fixture has nothing to leak, so the assertion below is empty")

        leaked = self.FORBIDDEN_KEYS & set(row)
        self.assertFalse(
            leaked,
            "the candidate answer review leaked scoring machinery: %s"
            % sorted(leaked))

        blob = " ".join(str(v) for v in row.values())
        self.assertNotIn(
            response.label_box_scores_json, blob,
            "the per-box scoresheet reached the candidate under another key")

        # Positive control: the candidate's OWN labels are still returned, so
        # the assertions above are about the SCORES being absent rather than
        # the review having been emptied.
        self.assertEqual(row["label_answers"]["3"], "Opens the printer")

    def test_the_internal_audit_prose_is_not_the_candidate_feedback(self):
        """`reasoning` carries the arithmetic; `feedback` is the coaching.

        These are two different columns for one reason, and a row that quietly
        fell back to `llm_reasoning` when `llm_feedback` was empty would hand
        the candidate the blend it was written to hide.
        """
        question, response = self._scored_answer()
        row = S.released_answer_review_row(1, question, response, "tok")

        self.assertEqual(row["feedback"], response.llm_feedback)
        for value in row.values():
            self.assertNotIn(
                response.llm_reasoning, str(value),
                "the internal scoring audit reached the candidate row")

    def test_no_value_on_the_row_names_a_weight(self):
        """By CONTENT, not by key - the leak that a key check cannot see.

        Nothing stops the grader writing "your justification is only weighted
        25%" into `feedback`, which IS candidate-facing, and no shape assertion
        would notice. prompts/scoring.md forbids it; this proves the serializer
        is not the thing putting it there.
        """
        question, response = self._scored_answer()
        row = S.released_answer_review_row(1, question, response, "tok")
        blob = " ".join(str(v) for v in row.values()).lower()

        for term in ("0.75", "0.25", "0.60", "key closeness", "sop coverage",
                     "weight", "threshold"):
            self.assertNotIn(
                term, blob,
                "the candidate review names %r - the weighting is not the "
                "candidate's to know" % term)


class TestReleaseGate(_Base):
    """INVARIANT 3 - a score is never revealed without a deliberate human act."""

    def _submitted_attempt(self, assessment, name="Candidate"):
        ev = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": self._applicant(name).id,
        })
        ev.write({"state": "submitted"})
        return ev

    def _assessment(self):
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        return self.Assessment.create({
            "name": "A %s" % uuid4().hex[:6],
            "generator_id": gen.id,
        })

    def test_candidate_result_hides_the_score_until_released(self):
        a = self._assessment()
        ev = self._submitted_attempt(a)
        self.assertFalse(ev.results_released)
        out = S.candidate_result(ev, S.attempt_bucket(ev))
        self.assertFalse(
            out.get("released"),
            "an unreleased attempt reported itself as released")
        self.assertNotIn(
            "score_percent", out,
            "the internal percentage reached a candidate payload")

    def test_releasing_one_leaves_the_others_alone(self):
        """The bug this pins is a CLIENT one, but the server contract is what
        makes the fix possible, so the contract is what is asserted.

        `releaseOne` in the Flutter store sent no `evaluator_ids`, and an empty
        list means "release the whole cohort" - so a per-candidate Release
        button published everybody. If `action_release_results` ever stops
        being per-record, that fix silently regresses.
        """
        a = self._assessment()
        one = self._submitted_attempt(a, "Alpha")
        two = self._submitted_attempt(a, "Bravo")

        one.action_release_results()

        self.assertTrue(one.results_released)
        self.assertFalse(
            two.results_released,
            "releasing one attempt released another - the release action is "
            "no longer per-record")


class TestGradingQueue(_Base):
    """The starvation that made LLM grading a no-op for nine days.

    `llm_auto_score` defaults to False. The scoring cron only ever drains
    evaluators carrying `scoring_requested`, and that flag is only set on the
    submit transition when the assessment has the toggle on. With it off,
    subjective answers sit `pending` with zero attempts and no error recorded
    anywhere - so nothing surfaces it. These pin the wiring in both directions.
    """

    def _assessment(self, auto):
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        return self.Assessment.create({
            "name": "A %s" % uuid4().hex[:6],
            "generator_id": gen.id,
            "llm_auto_score": auto,
        })

    def _subjective_question(self):
        """A question whose answer needs the grader.

        The queueing condition is narrower than "the toggle is on": it also
        requires the candidate to actually HAVE a subjective answer still
        awaiting a score. That is deliberate and better than the alternative -
        queueing a candidate whose paper was entirely objective would occupy a
        cron slot to grade nothing. The first draft of this test missed it and
        was the thing that failed, not the code.
        """
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        return self.Question.create({
            "name": "Subjective %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Explain your reasoning.",
            "difficulty": "medium",
            "generator_id": gen.id,
        })

    def _submit_objective(self, assessment):
        """A submitted attempt whose every answer is objective."""
        applicant = self._applicant("Objective")
        ev = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        q, opts = self._mcq()
        self.Response.create({
            "assessment_id": assessment.id,
            "assessment_evaluator_id": ev.id,
            "evaluator_id": applicant.id,
            "question_id": q.id,
            "state": "submitted",
        })
        ev.invalidate_recordset()
        ev.write({"state": "submitted"})
        ev.invalidate_recordset()
        return ev

    def _submit(self, assessment):
        applicant = self._applicant("Cand")
        ev = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        q = self._subjective_question()
        self.Response.create({
            "assessment_id": assessment.id,
            "assessment_evaluator_id": ev.id,
            "evaluator_id": applicant.id,
            "question_id": q.id,
            "justification": "A written answer the grader has to read.",
            "state": "submitted",
        })
        ev.invalidate_recordset()
        ev.write({"state": "submitted"})
        return ev

    def test_toggle_on_queues_the_candidate(self):
        ev = self._submit(self._assessment(True))
        self.assertTrue(
            ev.scoring_requested,
            "submit did not queue the candidate even though the assessment "
            "has auto-grading on - the grader will never see this answer")

    def test_toggle_off_does_not_queue(self):
        """The documented behaviour, asserted so the default is a CHOICE.

        Off is legitimate - an admin runs grading by hand - but it must be the
        stated behaviour rather than an accident, because the failure mode is
        silence rather than an error.
        """
        ev = self._submit(self._assessment(False))
        self.assertFalse(ev.scoring_requested)

    def test_an_objective_only_paper_is_not_reported_as_waiting(self):
        """The /scoring pipeline must not invent a queue.

        `evaluator.llm_state` has no `not_needed` value - only the RESPONSE
        model does - so an entirely objective paper keeps the field default,
        `pending`, forever. Counting that as pipeline work reported every
        mcq-only attempt as waiting to be graded on a fully finished system,
        and pinned the console's starvation warning on permanently. This is the
        domain the route uses; both directions are asserted, because a filter
        that fixes the false positive by hiding real work is the worse bug.
        """
        Ev = self.Evaluator
        waiting = [("state", "=", "submitted"),
                   ("llm_state", "=", "pending"),
                   ("response_ids.needs_llm", "=", True)]

        # An objective-only attempt: submitted, llm_state at its default.
        objective = self._submit_objective(self._assessment(True))
        self.assertEqual(objective.llm_state, "pending",
                         "precondition: the default is what causes the lie")
        self.assertNotIn(
            objective, Ev.search(waiting),
            "an attempt with nothing to grade was reported as waiting")

        # A subjective attempt must still be seen.
        subjective = self._submit(self._assessment(True))
        self.assertIn(
            subjective, Ev.search(waiting),
            "genuine subjective work was hidden by the filter")

    def test_the_shard_query_only_sees_queued_candidates(self):
        """The cron's own selection, which is where the starvation showed up."""
        queued = self._submit(self._assessment(True))
        idle = self._submit(self._assessment(False))
        picked = self.Assessment._scoring_shard_evaluators(0, 1)
        self.assertIn(queued, picked)
        self.assertNotIn(idle, picked)


class TestQuestionEditing(_Base):
    """Editing a question, and the two things editing must never do.

    Odoo's draft and bank forms are fully editable - option rows are
    `editable="bottom"` and `is_correct` is a toggle - so a reviewer fixes a
    generated question in place instead of throwing it away. These pin the
    guards that make the same thing safe over HTTP.
    """

    def _bank_mcq(self):
        q, opts = self._mcq(correct_idx=0)
        return q, opts

    @mute_logger("odoo.sql_db")
    def test_an_option_a_candidate_chose_cannot_be_deleted(self):
        """The guard that protects a submitted answer.

        `response.line.selected_option_id` is ondelete="restrict", so the
        database would refuse anyway - but as an IntegrityError, which reaches
        the user as "server error". The route names the option and says why
        instead, because the operator's next move (edit the text, or retire the
        question) depends on understanding which one is stuck.
        """
        q, opts = self._bank_mcq()
        gen = self.Generator.create({"name": "G %s" % uuid4().hex[:6]})
        a = self.Assessment.create({"name": "A %s" % uuid4().hex[:6],
                                    "generator_id": gen.id})
        applicant = self._applicant("Sat")
        ev = self.Evaluator.create({"assessment_id": a.id,
                                    "applicant_id": applicant.id})
        resp = self.Response.create({
            "assessment_id": a.id,
            "assessment_evaluator_id": ev.id,
            "evaluator_id": applicant.id,
            "question_id": q.id,
            "state": "submitted",
        })
        self.env["assessments.be.response.line"].create({
            "response_id": resp.id,
            "question_dimension_id": q.question_dimension_ids[0].id,
            "selected_option_id": opts[0].id,
        })

        # The database itself refuses, via ondelete="restrict". Asserting on
        # that rather than on the route's wording pins the property that
        # matters - a submitted answer cannot be silently rewritten - without
        # depending on an HTTP context the route needs and this does not.
        from psycopg2 import IntegrityError
        with self.assertRaises(IntegrityError):
            with self.env.cr.savepoint():
                opts[0].unlink()

        # An option NOBODY chose is removable, so the guard is about real
        # answers rather than about options in general.
        with self.env.cr.savepoint():
            opts[2].unlink()
        self.assertFalse(opts[2].exists())

    def test_the_correct_answer_must_be_one_of_the_options(self):
        """A draft's key is the option TEXT, so a typo silently breaks it.

        `correct_answer_json` holds the text rather than an id or an index. Any
        edit that leaves it naming something not in `options_json` produces a
        question nobody can answer correctly - and it looks entirely normal on
        screen, which is what makes it worth refusing at the point of saving.
        """
        from odoo.addons.assessments_be_v2.controllers.api.write import (
            answer_key_problem)

        options = ["Alpha", "Bravo", "Charlie"]
        self.assertIsNone(
            answer_key_problem("mcq", options, "Alpha"),
            "a correct answer that IS an option must be accepted")
        self.assertIsNotNone(
            answer_key_problem("mcq", options, "Delta"),
            "a correct answer that is not an option must be refused")
        self.assertIsNotNone(
            answer_key_problem("mcq", options, ""),
            "an empty correct answer must be refused")
        self.assertIsNotNone(
            answer_key_problem("mcq", options, ["Alpha", "Bravo"]),
            "a single-answer question cannot have two correct options")
        self.assertIsNone(
            answer_key_problem("msq", options, ["Alpha", "Bravo"]),
            "a multi-answer question may have several")
        self.assertIsNotNone(
            answer_key_problem("mcq", ["Only one"], "Only one"),
            "a question with a single option is not a question")
        # A written-answer question has no options to check, and must not be
        # dragged through this validation at all.
        self.assertIsNone(
            answer_key_problem("subjective_rubric", [], ""))


# ─────────────────────────────────────────────────────────────────────────────
# INVARIANT 5 (C3) - nothing INTERNAL reaches a candidate.
#
# WRITTEN BEFORE THE FIELD EXISTED, deliberately. D1 adds an operator-applied
# flag and a free-text internal remark to one SITTING; requirement 2.6 says it
# must reach every ADMIN surface and requirement 3.5 says it must reach no
# candidate one. A disclosure rule written after the field is a rule written
# after the leak, so this landed first and must pass on both sides of task 13.
#
# ABSENT, NOT `false`. A `flagged: false` on a candidate payload tells the
# candidate the mechanism exists and turns its absence into information - which
# is the whole point of an INTERNAL note. The assertion is therefore on key
# presence at any depth, never on the value.
#: Both halves of the feature, on both sides of the wire: the JSON keys the
#: admin payloads use (`candidate_flag` and the block's own `flagged` /
#: `remark`) and the Odoo field names behind them (`manual_flagged`,
#: `manual_remark`, `manual_flagged_by`, `manual_flagged_at`), because a
#: serializer that dumped a record's raw field dict would leak the second set
#: rather than the first.
MANUAL_FLAG_KEYS = frozenset({
    "candidate_flag", "flagged", "remark",
    "manual_flagged", "manual_remark",
    "manual_flagged_by", "manual_flagged_at",
})


def _is_flag_key(key):
    return str(key) in MANUAL_FLAG_KEYS


def _walk_keys(node, path="$"):
    """Every (path, key) in `node`, at EVERY nesting depth.

    A top-level check is not enough and that is not a hypothetical: the shared
    `applicant_brief` is nested inside other payloads, so a field added there
    would surface two and three levels down while every top-level key still
    looked clean. Lists are walked too - a cohort payload is a list of dicts.
    """
    if isinstance(node, dict):
        for key, value in node.items():
            yield "%s.%s" % (path, key), key
            yield from _walk_keys(value, "%s.%s" % (path, key))
    elif isinstance(node, (list, tuple)):
        for i, value in enumerate(node):
            yield from _walk_keys(value, "%s[%d]" % (path, i))


@tagged("-at_install", "post_install")
class TestNothingInternalReachesACandidate(_Base):
    """INVARIANT 5 - the C3 disclosure boundary.

    The exclusion list is every candidate-facing serializer in
    `controllers/api/serializers.py`. `applicant_brief` is the one to watch: it
    is SHARED, called by `evaluator_admin_row` on admin routes and reachable
    from candidate payloads, so it is the only realistic path by which an admin
    annotation reaches a candidate. The rule D1 has to hold is that the flag
    lives on the ADMIN ATTEMPT ROW and never on the shared person brief.
    """

    def _assessment(self):
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        return self.Assessment.create({
            "name": "A %s" % uuid4().hex[:6],
            "generator_id": gen.id,
        })

    def _flag_a_cohort(self, evaluators):
        """Set every manual-flag field that EXISTS, on alternating ATTEMPTS.

        ON THE EVALUATOR, because that is where D1 put the flag: a fixture
        still writing `hr.applicant` would set nothing at all and turn this
        whole disclosure suite green by testing an empty cohort.

        Guarded on `_fields` so a rename fails loudly in
        `test_the_cohort_is_actually_flagged_before_anything_is_asserted`
        below rather than silently here.

        BOTH HALVES ARE EXERCISED and they are set on different rows: one
        attempt carries a flag with a remark, another carries a remark with no
        flag. The second is the state a serializer is most likely to leak by
        accident, because it looks like ordinary free text.
        """
        wrote = self.Evaluator.browse()
        fields_now = self.Evaluator._fields
        for i, evaluator in enumerate(evaluators):
            vals = {}
            if "manual_flagged" in fields_now:
                vals["manual_flagged"] = bool(i % 2 == 0)
            if "manual_remark" in fields_now and i % 3 != 2:
                vals["manual_remark"] = (
                    "Webcam showed a second person at 14:03. Internal only.")
            if vals:
                evaluator.write(vals)
                wrote |= evaluator
        return wrote

    def _payloads(self):
        """One call of every candidate-facing serializer, as (name, body)."""
        assessment = self._assessment()
        people = [self._applicant("Cand %d" % i) for i in range(4)]

        evs = self.Evaluator.browse()
        for person in people:
            evs |= self.Evaluator.create({
                "assessment_id": assessment.id,
                "applicant_id": person.id,
            })
        evs.write({"state": "submitted"})
        # AFTER the attempts exist, because the flag is per-attempt now: there
        # is no person-level field a cohort could be flagged through.
        flagged = self._flag_a_cohort(evs)
        ev = evs[0]

        question, options = self._mcq("Flagged cohort Q")
        dimension = question.question_dimension_ids[:1]

        out = [
            ("applicant_brief", S.applicant_brief(people[0])),
            ("attempt_bucket", S.attempt_bucket(ev)),
            ("candidate_result",
             S.candidate_result(ev, S.attempt_bucket(ev))),
            ("candidate_result_breakdown", S.candidate_result_breakdown(ev)),
            ("attempt", S.attempt(ev)),
            ("candidate_dashboard", S.candidate_dashboard(evs)),
            ("candidate_analytics", S.candidate_analytics(evs)),
            ("empty_candidate_analytics", S.empty_candidate_analytics()),
            ("proctoring_rules", S.proctoring_rules(assessment, ev)),
            ("question_option", S.question_option(options[0])),
            ("question_dimension", S.question_dimension(dimension)),
            ("question_media", S.question_media(question, "tok")),
            ("question_for_candidate",
             S.question_for_candidate(question, "tok", 1, 1)),
            ("exam_state_envelope",
             S.exam_state_envelope("in_progress", ev)),
            ("released_answer_review_row",
             S.released_answer_review_row(
                 1, question, self.Response.browse(), "tok")),
            ("session_user",
             S.session_user(people[0].be_candidate_user_id, people[0])),
        ]
        return assessment, evs, flagged, out

    def test_the_cohort_is_actually_flagged_before_anything_is_asserted(self):
        """The fixture has to bite, or every assertion below is vacuous.

        `_flag_a_cohort` writes only the fields that EXIST, which is what lets
        this file land before task 13. Once they exist it must actually be
        setting them - otherwise a renamed or dropped field would turn the
        whole disclosure suite green by writing nothing at all.
        """
        _a, _evs, flagged, _p = self._payloads()
        self.assertTrue(
            flagged, "the fixture flagged nothing, so nothing was under test")
        self.assertTrue(
            any(e.manual_flagged for e in flagged),
            "at least one attempt in the cohort must carry a raised flag")
        self.assertTrue(
            any(e.manual_remark for e in flagged),
            "and at least one must carry an internal remark, which is the "
            "free-text half a leak would expose")
        self.assertTrue(
            any(e.manual_remark and not e.manual_flagged for e in flagged),
            "and at least one must carry a remark with NO flag - the two are "
            "independent, and that combination is the one a serializer is "
            "most likely to leak because it reads as ordinary free text")

    def test_no_candidate_serializer_carries_a_manual_flag_key(self):
        _a, _evs, flagged, payloads = self._payloads()

        for name, body in payloads:
            for path, key in _walk_keys(body, "$%s" % name):
                self.assertFalse(
                    _is_flag_key(key),
                    "%s leaks an internal annotation at %s. A candidate "
                    "payload must not carry %r at ANY depth - absent, not "
                    "false." % (name, path, key))

    def test_the_walk_would_actually_catch_one(self):
        """The walker is load-bearing, so it gets its own counterexample.

        Without this, a `_walk_keys` that silently stopped recursing would make
        every assertion above pass for the wrong reason - the classic way a
        disclosure test goes green while the disclosure happens.
        """
        planted = {"attempt": {"sitting": {"manual_remark": "internal"}},
                   "rows": [{"ok": 1}, {"candidate_flag": {"detail": "x"}}]}
        found = [p for p, k in _walk_keys(planted) if _is_flag_key(k)]
        self.assertEqual(
            len(found), 2,
            "the walker must reach a key nested three deep AND one inside a "
            "list; it found %r" % (found,))

    def test_an_unreleased_result_is_still_withheld(self):
        """3.5, re-asserted here because D1 touches the same payload."""
        _a, evs, _f, _p = self._payloads()
        ev = evs[0]
        ev.write({"results_released": False})

        body = S.candidate_result(ev, S.attempt_bucket(ev))
        self.assertFalse(
            body.get("released"),
            "an unreleased attempt must not report itself as released")
        for path, key in _walk_keys(body):
            self.assertNotIn(
                key, ("score_percent", "percentage"),
                "an unreleased result must not carry a percentage at %s"
                % path)

    def test_a_released_result_is_expressed_in_marks(self):
        _a, evs, _f, _p = self._payloads()
        ev = evs[0]
        ev.write({"results_released": True})

        body = S.candidate_result(ev, S.attempt_bucket(ev))
        text = json.dumps(body)
        self.assertIn(
            "marks", text,
            "a released result is expressed as marks, not as a percentage")
        for _path, key in _walk_keys(body):
            self.assertFalse(
                _is_flag_key(key),
                "a RELEASED result is still not a place for an internal note")
