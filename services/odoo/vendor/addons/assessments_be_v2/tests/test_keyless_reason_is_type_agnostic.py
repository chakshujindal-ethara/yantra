# -*- coding: utf-8 -*-
"""Both launch gates ask ONE method, and it asks what the question is WORTH.

TWO DEFECTS THIS LOCKS DOWN, plus one over-reach it prevents.

1. THE TYPE LIST. `action_start` and the launch dry run behind
   /api/v1/assessments/<id>/launch_check both opened with
   `if question_type not in ("mcq", "msq", "image_ab"): return False` - so a
   question of ANY other type with nothing markable on it passed the gate
   written to stop questions that "score 0 for every candidate".

2. TWO COPIES, ONE RULE. The rule was hand-copied into both gates and had
   already drifted once (`test_authored_question_marks` documents it: the
   mirror exempted a dimensionless objective question that `action_start`
   refused, so the operator saw `answer_keys` PASS, pressed confirm, and got a
   UserError the route does not render as a gate failure). It now lives on
   `assessments.be.question._keyless_reason`, so the two cannot disagree.

3. THE OVER-REACH, caught by measuring against the live bank before shipping.
   The first version of the unified rule reasoned "has dimensions, none keyed ->
   keyless", which flagged 9 real bank rows - `subjective_rubric` and
   `image_label` questions whose LLM-graded component is worth 1 mark, so they
   DO grade. Refusing those would have cost the examiner usable papers.

   The rule therefore asks `_component_counts` - the same arithmetic the paper's
   denominator is built from - so the gate cannot disagree with what the paper
   actually counts. "Scores 0 for every candidate" means "is worth 0 marks".

WHAT MUST NOT BE FLAGGED, and each has its own test below:
  * A subjective/labelling question with no per-option key - LLM-graded, it
    earns its mark from its type.
  * A PARTIALLY keyed axis set - the keyed axes do score, so refusing to launch
    would have a real cost. It stays visible as "only X of Y" in the UI.

Separately, unkeyed axes are still a real authoring fault wherever they appear:
their marks silently do not exist (`_keyed_dimension_count`), which is what made
assessment 140 report 1/3 when six of six axes were answered correctly. That is
what the template answer-key fix addresses (`test_template_authored_key`); this
gate is only about refusing a paper nothing can be earned on.
"""
from odoo.tests.common import TransactionCase


class TestKeylessReasonAsksWhatTheQuestionIsWorth(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]

    def _question(self, qtype, axes=()):
        """`axes` is a list of (name, keyed) pairs."""
        q = self.Question.create({
            "name": "Probe %s" % qtype,
            "question_type": qtype,
            "prompt": "Answer the checks.",
        })
        for name, keyed in axes:
            self.QDim.create({
                "question_id": q.id,
                "name": name,
                "option_line_ids": [
                    (0, 0, {"name": "Yes", "is_correct": bool(keyed)}),
                    (0, 0, {"name": "No", "is_correct": False}),
                ],
            })
        q.invalidate_recordset()
        return q

    # -- the defect: a non-mcq type with unkeyed axes -------------------

    def test_an_unkeyed_axis_is_flagged_on_a_purely_objective_type(self):
        """The assessment-140 shape on the types that have nothing ELSE to mark.

        `mcq` and `msq` earn their marks only from keyed axes, so an all-unkeyed
        set leaves nothing on the question at all. Fails if the gate goes back to
        asking `question_type in (mcq, msq, image_ab)` and then exempting the
        rest by type rather than by what they are worth.
        """
        for qtype in ("mcq", "msq"):
            q = self._question(qtype, axes=[("Check 1", False),
                                            ("Check 2", False)])
            self.assertTrue(
                q._keyless_reason(),
                "%s with two unkeyed axes scores 0 for every candidate and "
                "must be flagged" % qtype)

    def test_unkeyed_axes_beside_an_LLM_GRADED_component_are_NOT_refused(self):
        """Measured on the live bank: 9 rows would have been blocked wrongly.

        `subjective_rubric` / `image_label` / `image_prompt` / `video_prompt`
        earn a mark from their own type (`_component_counts` returns (1, 1)), so
        the question DOES grade even with every axis unkeyed. An earlier version
        of the gate reasoned "has dimensions, none keyed -> keyless" and
        over-reached onto exactly these rows, which would have cost the examiner
        usable papers.

        Those unkeyed axes are still a real authoring fault - their marks
        silently do not exist - but that is a warning, not a reason to refuse a
        paper that grades.
        """
        for qtype in ("subjective_rubric", "image_prompt", "video_prompt",
                      "image_label"):
            q = self._question(qtype, axes=[("Check 1", False),
                                            ("Check 2", False)])
            self.assertEqual(
                q._keyless_reason(), "",
                "%s is worth %s marks, so it grades and must stay launchable"
                % (qtype, q._component_counts()[0]))

    def test_a_keyed_axis_clears_the_gate(self):
        q = self._question("mcq", axes=[("Check 1", True)])
        self.assertEqual(q._keyless_reason(), "")

    def test_a_PARTIALLY_keyed_set_is_not_flagged(self):
        """The keyed axes still score, so this must remain launchable."""
        q = self._question("mcq", axes=[("Check 1", True),
                                        ("Check 2", False)])
        self.assertEqual(
            q._keyless_reason(), "",
            "one keyed axis is markable, so refusing to launch would cost the "
            "examiner a usable paper")

    # -- the dimensionless cases ---------------------------------------

    def test_a_dimensionless_objective_question_is_flagged(self):
        """There is nothing on it to answer - the purest example of a question
        that scores 0 for everyone."""
        q = self._question("mcq")
        self.assertTrue(q._keyless_reason())

    def test_a_dimensionless_SUBJECTIVE_question_is_fine(self):
        """LLM-graded, and it carries no per-option key by design. Flagging it
        would make every rubric question unlaunchable."""
        for qtype in ("subjective_rubric", "image_prompt", "video_prompt",
                      "image_label"):
            q = self._question(qtype)
            self.assertEqual(
                q._keyless_reason(), "",
                "%s earns a mark from its own type, so it is not keyless"
                % qtype)

    def test_the_reason_agrees_with_the_denominator(self):
        """`_keyless_reason` and `_component_counts` must not disagree: a
        question worth nothing is exactly a question that is flagged."""
        for q in (self._question("mcq"),
                  self._question("mcq", axes=[("A", False)]),
                  self._question("mcq", axes=[("A", True)]),
                  self._question("subjective_rubric")):
            marks, _raw = q._component_counts()
            self.assertEqual(
                bool(q._keyless_reason()), marks == 0,
                "a flagged question must be one worth 0 marks, and vice versa")

    def test_the_reason_names_the_fault(self):
        """The operator has to know WHICH fault to go and fix."""
        self.assertIn("no correct option",
                      self._question("mcq", axes=[("A", False)])
                      ._keyless_reason())
        self.assertIn("nothing on it to answer",
                      self._question("mcq")._keyless_reason())
