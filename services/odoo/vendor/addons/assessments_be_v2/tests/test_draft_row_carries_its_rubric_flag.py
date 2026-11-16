# -*- coding: utf-8 -*-
"""Two screens showing the same draft must agree about whether it has a rubric.

THE DEFECT, reported from stage: "One of Template's generated question has
rubrics but UI does not detect it... Its warning in Generator's Drafts is not
shown but in Review Queue."

`bank_question_row` sends `has_rubric`; `draft_row` did not. The client raises its
"No rubric" warning whenever `type.isSubjective && !hasRubric`, and an ABSENT key
parses as false - so the same draft was badged one way in the Review Queue and the
other way in the generator's Drafts tab, with nothing having changed about the
draft between the two screens. An absent boolean is not a missing feature here; it
is a WRONG ANSWER, because false is a meaningful value.

This is the THIRD field on this row to need exactly this treatment, and the file
already documents the other two in the same words: `has_valid_key` (every
objective draft carried a blocking "No answer key" over a stored key) and
`has_official_reasoning` (every A/B draft claimed "No answer rationale" while the
rationale was rendered on the same page). The list route is what the client's
warning badges are built from, so any quality signal that lives only on the detail
route is a signal the badges cannot see.

READ FROM `rubric_json`. A draft keeps its marking guide there and
`action_approve` copies it into the question's `subjective_rubric_json` - so
reading the question's spelling here would raise AttributeError, and reading it
defensively would report "no rubric" for every draft ever written.
"""
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import serializers as S


@tagged("-at_install", "post_install")
class TestDraftRowCarriesItsRubricFlag(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Rubric flag probe"})

    def _draft(self, rubric_json=None, question_type="subjective_rubric"):
        vals = {
            "name": "Describe what you see",
            "prompt_id": self.generator.id,
            "question_type": question_type,
            "question_prompt": "What is wrong with this clip?",
        }
        if rubric_json is not None:
            vals["rubric_json"] = rubric_json
        return self.env["assessments.be.prompt.question"].create(vals)

    # ------------------------------------------------------------------
    # The defect
    # ------------------------------------------------------------------
    def test_a_draft_with_a_rubric_says_so_on_the_LIST_row(self):
        """THE HEADLINE. This key was absent, and absent reads as false."""
        draft = self._draft(rubric_json='{"points": ["Names the artefact"]}')
        row = S.draft_row(draft)
        self.assertIn(
            "has_rubric", row,
            "the review queue and the drafts tab build their warning badges "
            "from this row; a key that is not here cannot be read as true")
        self.assertTrue(
            row["has_rubric"],
            "the draft has a marking guide, so no screen may warn that it "
            "does not")

    def test_a_draft_with_no_rubric_still_says_so(self):
        """The warning has to keep working - this is a real authoring smell."""
        row = S.draft_row(self._draft())
        self.assertIn("has_rubric", row)
        self.assertFalse(row["has_rubric"])

    def test_the_two_SCREENS_agree_about_the_same_marking_guide(self):
        """What the tester actually observed: one draft, two screens, two
        answers. The Review Queue reads an approved question's bank row and the
        Drafts tab reads this one, so the two shapes have to answer the same."""
        draft = self._draft(rubric_json='{"points": ["a", "b"]}')
        question = self.env["assessments.be.question"].create({
            "name": draft.name,
            "question_type": "subjective_rubric",
            "prompt": draft.question_prompt,
            "generator_id": self.generator.id,
            "subjective_rubric_json": draft.rubric_json,
        })
        self.assertEqual(
            S.draft_row(draft)["has_rubric"],
            S.bank_question_row(question)["has_rubric"],
            "the same marking guide must not be present on one screen and "
            "missing on the other")

    # ------------------------------------------------------------------
    # Emptiness, which is where a sloppier check would go wrong
    # ------------------------------------------------------------------
    def test_an_EMPTY_json_container_is_not_a_marking_guide(self):
        """"[]" and "{}" are what get stored when a rubric was attempted and
        came back with nothing in it. Treating either as a rubric would silence
        the warning on exactly the drafts that most need it - the same emptiness
        test `bank_question_row` already applies."""
        for empty in ("[]", "{}", "", "   "):
            self.assertFalse(
                S.draft_row(self._draft(rubric_json=empty))["has_rubric"],
                "%r is not a marking guide" % empty)

    def test_whitespace_around_a_real_rubric_does_not_hide_it(self):
        row = S.draft_row(self._draft(rubric_json='\n  {"points": ["x"]}\n '))
        self.assertTrue(row["has_rubric"])

    def test_an_objective_draft_carries_the_key_too(self):
        """Absent and false are different to the client. An mcq needs no rubric
        and raises no warning, but the key must still be PRESENT so a future
        reader never has to tell "no rubric" from "this row does not say"."""
        row = S.draft_row(self._draft(question_type="mcq"))
        self.assertIn("has_rubric", row)
        self.assertFalse(row["has_rubric"])
