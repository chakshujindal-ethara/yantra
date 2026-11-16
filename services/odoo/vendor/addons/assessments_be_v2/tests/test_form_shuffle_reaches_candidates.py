"""The designer's "Shuffle question order" switch must reach a CANDIDATE.

THE GAP THIS CLOSES. The switch existed in Form Studio and did nothing outside
the examiner's own Preview tab. Three links in the chain were missing:

  1. `controllers/api/forms.py` built its write values from `title`,
     `description`, `published` and `structure_json` only, so the flag the
     client had always sent was dropped at the API boundary.
  2. `etp.studio.form` had no field to store it in.
  3. `publish_to_assessment` hardcoded `preserve_question_order = True`.

So a form published with the switch ON still served every candidate the same
order, and nothing anywhere said why.

WHAT THE DEFAULT IS, AND WHY. Off. A Form Studio author groups questions into
sections deliberately, and `action_start`'s per-candidate shuffle would throw
that arrangement away - which is exactly why the hardcoded `True` was there in
the first place. The switch is how an author opts OUT of their own ordering, so
turning it off must keep publishing behaving as it always has.

WHAT THESE TESTS ASSERT ON. The `preserve_question_order` flag on the minted
assessment, and then the actual `question_order` each roster row is served.
Asserting only the flag would pass while the shuffle itself was broken; the
per-candidate orders are what a candidate actually sees.
"""
import json
from uuid import uuid4

from odoo.tests.common import tagged

from odoo.addons.assessments_be_v2.tests.test_authored_question_marks import (
    _FormBase,
)


@tagged("post_install", "-at_install")
class TestFormShuffleReachesCandidates(_FormBase):
    """`etp.studio.form.shuffle_questions` -> assessment -> question_order."""

    def _choice(self, title):
        return self._item(
            "multipleChoice", title=title,
            options=self._opts(("Yes", True), ("No", False)))

    def _publish_form(self, shuffle, count=8):
        """A form with `count` plain questions, published with the switch set."""
        items = [self._choice("Q%d" % (i + 1)) for i in range(count)]
        form = self._form(*items)
        form.shuffle_questions = shuffle
        return form, form.publish_to_assessment()

    def _assessment_of(self, result):
        questions = self.Question.browse(result["questions_created"]) \
            if isinstance(result.get("questions_created"), list) else None
        self.assertIsNone(
            result.get("problems"),
            "the fixture form must publish; problems were %r"
            % (result.get("problems"),))
        assessment = self.env["assessments.be"].browse(result["assessment_id"])
        self.assertTrue(
            assessment.exists(),
            "publishing must mint an assessment to read the flag off")
        return assessment, questions

    # -- the flag reaches the assessment -------------------------------

    def test_shuffle_off_preserves_the_authored_order(self):
        """The default, and the behaviour that existed before the switch."""
        _form, result = self._publish_form(shuffle=False)
        assessment, _q = self._assessment_of(result)
        self.assertTrue(
            assessment.preserve_question_order,
            "with the switch off the author's section order IS the instrument, "
            "so the assessment must preserve it")

    def test_shuffle_on_hands_the_order_to_the_shuffler(self):
        _form, result = self._publish_form(shuffle=True)
        assessment, _q = self._assessment_of(result)
        self.assertFalse(
            assessment.preserve_question_order,
            "with the switch on the author asked for a per-candidate shuffle, "
            "which action_start only performs when preserve_question_order is "
            "False")

    def test_form_studio_publish_reports_shuffle_false_over_the_api(self):
        """The alias must AGREE with Form Studio, not fight it.

        Form Studio sets `preserve_question_order=True` on a publish deliberately
        (the author's section order is the instrument), and the operator's config
        screen now reads that field through the `shuffle_questions` alias. If the
        alias inverted the wrong way the screen would show "shuffle: on" over a
        paper Form Studio froze, and an operator toggling it would silently undo
        the author's arrangement. So the serialized alias on a preserve-order
        publish must read false - Form Studio keeps winning.
        """
        from odoo.addons.assessments_be_v2.controllers.api import (
            serializers as S,
        )
        _form, result = self._publish_form(shuffle=False)
        assessment, _q = self._assessment_of(result)
        self.assertTrue(assessment.preserve_question_order)
        self.assertFalse(
            S.assessment_detail(assessment)["shuffle_questions"],
            "a Form Studio publish preserves the authored order, so the API "
            "alias the config screen reads must report shuffle_questions:false")

    def test_the_flag_defaults_off_on_a_form_nobody_set_it_on(self):
        form = self._form(self._choice("Q1"))
        self.assertFalse(
            form.shuffle_questions,
            "a form written before this field existed must keep publishing "
            "exactly as it did")

    # -- and reaches the candidate -------------------------------------

    def _orders(self, assessment, candidates=6):
        """Launch with `candidates` roster rows; return each one's order."""
        Applicant = self.env["hr.applicant"]
        applicants = Applicant.create([
            {"partner_name": "Candidate %s" % uuid4().hex[:6],
             "email_from": "cand-%s@candidates.test" % uuid4().hex[:8]}
            for _ in range(candidates)])
        assessment.write({"evaluator_ids": [(6, 0, applicants.ids)]})
        assessment.action_start()
        return [json.loads(row.question_order or "[]")
                for row in assessment.assessment_evaluator_ids]

    def test_with_shuffle_ON_candidates_get_different_orders(self):
        """The whole point of the switch, asserted on what is served.

        Six candidates over eight questions: the chance of every independent
        shuffle landing on the same permutation is 1/40320^5, so a single
        distinct order means the shuffle did not run.
        """
        _form, result = self._publish_form(shuffle=True, count=8)
        assessment, _q = self._assessment_of(result)
        orders = self._orders(assessment)

        self.assertTrue(orders, "launch must fill the roster")
        distinct = {tuple(o) for o in orders}
        self.assertGreater(
            len(distinct), 1,
            "with shuffle on, candidates must not all be served the same "
            "order - got %d identical orders" % len(orders))

    def test_with_shuffle_OFF_every_candidate_gets_the_authored_order(self):
        _form, result = self._publish_form(shuffle=False, count=8)
        assessment, _q = self._assessment_of(result)
        orders = self._orders(assessment)

        distinct = {tuple(o) for o in orders}
        self.assertEqual(
            len(distinct), 1,
            "with shuffle off every candidate must sit the SAME authored "
            "order; got %d different orders" % len(distinct))

    def test_shuffling_serves_the_same_QUESTIONS_only_reordered(self):
        """A shuffle must reorder the paper, never change which paper it is.

        Every candidate sits one shared set, so fairness is the contract:
        everyone faces the same instrument. Only the sequence moves.
        """
        _form, result = self._publish_form(shuffle=True, count=8)
        assessment, _q = self._assessment_of(result)
        orders = self._orders(assessment)

        sets = {frozenset(o) for o in orders}
        self.assertEqual(
            len(sets), 1,
            "every candidate must be served the same SET of questions - a "
            "shuffle reorders the paper, it does not redraw it")
