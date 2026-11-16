"""A subjective score records WHICH grading prompt produced it - SNo 124.

THE GAP. `llm_judge_model` has always recorded the exact Vertex model behind a
score, because a hire/reject decision has to be auditable. The system PROMPT was
not recorded at all, so "this answer was weaker" was indistinguishable from
"this answer was marked to a different standard". That is the question an
appeal asks.

THE DECISION ON THIS ROW WAS EXPLICIT: freeze the prompt, version it going
forward. No re-grade, no mark changes, no LLM spend. Existing scores are tagged
`pre-versioning` by the 19.0.3.16.0 migration rather than backfilled with a
digest, because the prompt that graded them is not recoverable.

W12 REMOVED THE STORED OVERRIDE. A stored
`assessments_be_v2.scoring_system_prompt` used to replace the shipped
`prompts/scoring.md`; grading now always uses the shipped file, and a value
already stored is left in place, unread. The version is therefore always
`bundled:<sha8>` of the text actually sent.

  * THE VERSION FOLLOWS THE TEXT, NOT A COUNTER. A hand-bumped number is a
    number somebody forgets to bump.
  * A STORED OVERRIDE IS IGNORED, and the tests below prove it through the
    real request builder, not just the loader.
"""
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.services import scoring, vertex


@tagged("-at_install", "post_install")
class TestAScoreRecordsWhichRubricGradedIt(TransactionCase):

    def setUp(self):
        super().setUp()
        self.params = self.env["ir.config_parameter"].sudo()
        self.KEY = "assessments_be_v2.scoring_system_prompt"

    # ── the id itself ─────────────────────────────────────────────────

    def test_the_version_changes_when_the_prompt_changes(self):
        """THE HEADLINE. The version is derived FROM the text, so it cannot
        drift from what was actually sent - which is exactly what a
        hand-incremented version number does."""
        a = scoring.scoring_prompt_version("Grade strictly. box_scores")
        b = scoring.scoring_prompt_version("Grade leniently. box_scores")

        self.assertTrue(a)
        self.assertNotEqual(a, b, "a different rubric must read as a different "
                                  "version")

    def test_the_same_prompt_always_gives_the_same_version(self):
        """Stable across calls and processes: a content hash, not a counter or
        a timestamp. Two answers graded under one prompt must compare equal."""
        text = "Grade strictly. box_scores"
        self.assertEqual(scoring.scoring_prompt_version(text),
                         scoring.scoring_prompt_version(text))

    def test_whitespace_alone_is_not_a_new_rubric(self):
        """A trailing newline from an editor is not a change of standard, and
        reporting it as one would make every re-save look like a re-rubric."""
        self.assertEqual(
            scoring.scoring_prompt_version("Grade strictly. box_scores"),
            scoring.scoring_prompt_version("  Grade strictly. box_scores\n"))

    def test_the_version_is_always_the_bundled_lane(self):
        """There is one lane now; the prefix stays so versions stored while
        an override lane existed still compare."""
        self.assertTrue(scoring.scoring_prompt_version("Grade strictly.")
                        .startswith("bundled:"))

    def test_an_empty_prompt_has_no_version(self):
        """Nothing to attribute. An id here would assert a rubric that does not
        exist."""
        self.assertEqual(scoring.scoring_prompt_version(""), "")
        self.assertEqual(scoring.scoring_prompt_version(None), "")

    # ── a stored override is ignored ──────────────────────────────────

    def test_grading_uses_the_shipped_file(self):
        shipped = vertex._load_bundled_prompt("scoring.md").strip()

        self.assertEqual(scoring._get_scoring_prompt(), shipped)

    def test_a_stored_override_is_ignored_and_left_in_place(self):
        """The value stays in `ir.config_parameter` (nothing is deleted), and
        neither the text sent nor the version stamped comes from it."""
        stale = "Grade leniently and return box_scores per marker."
        self.params.set_param(self.KEY, stale)
        shipped = vertex._load_bundled_prompt("scoring.md").strip()
        response = self._scored_response("")

        _scored, job = scoring._prepare_submission(self.env, response)

        self.assertEqual(job.system_prompt, shipped)
        self.assertNotIn(stale, job.system_prompt + job.user_text)
        self.assertEqual(job.prompt_version,
                         scoring.scoring_prompt_version(shipped))
        self.assertEqual(self.params.get_param(self.KEY), stale,
                         "the stored value is left in place, unread")

    def test_the_settings_fields_for_it_are_gone(self):
        fields_ = self.env["res.config.settings"]._fields
        for name in ("assessments_be_scoring_prompt",
                     "assessments_be_scoring_prompt_upload",
                     "assessments_be_scoring_prompt_filename"):
            self.assertNotIn(name, fields_)
        self.assertIn("assessments_be_question_prompt", fields_,
                      "the question-generation override is kept")

    # ── the stamp reaches the record and the API ──────────────────────

    def _scored_response(self, prompt_version):
        """One graded answer, stored through the real `_store_scored`.

        Driven through the storer rather than a bare `write`: the defect worth
        catching is the stamp being computed and never persisted, and a test
        that writes the field itself would pass against exactly that.
        """
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Rubric provenance fixture"})
        assessment = self.env["assessments.be"].create({
            "name": "Rubric provenance sitting",
            "generator_id": generator.id,
        })
        question = self.env["assessments.be.question"].create({
            "name": "Describe the fault",
            "question_type": "subjective_rubric",
            "prompt": "What went wrong?",
            "generator_id": generator.id,
            "assessment_ids": [(4, assessment.id)],
        })
        candidate = self.env["hr.applicant"].create(
            {"partner_name": "Rubric Provenance Candidate"})
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": candidate.id,
        })
        response = self.env["assessments.be.response"].create({
            "question_id": question.id,
            "assessment_id": assessment.id,
            "evaluator_id": candidate.id,
            "assessment_evaluator_id": evaluator.id,
            "justification": "The mast weld is cracked.",
        })
        scoring._store_scored(response, {
            "score": 80,
            "feedback": "Names the fault.",
            "_judge_model_version": "gemini-3-pro",
            "_prompt_version": prompt_version,
        })
        response.invalidate_recordset()
        return response

    def test_the_version_lands_on_the_scored_answer(self):
        version = scoring.scoring_prompt_version("Grade strictly. box_scores")

        response = self._scored_response(version)

        self.assertEqual(response.llm_state, "scored")
        self.assertEqual(response.llm_prompt_version, version)
        self.assertEqual(response.llm_judge_model, "gemini-3-pro",
                         "the model attribution must not have regressed")

    def test_the_audit_payload_carries_it(self):
        """An audit that can name the model and not the rubric cannot answer
        "were these two held to the same standard?" - which is the question."""
        from odoo.addons.assessments_be_v2.controllers.api import serializers

        version = scoring.scoring_prompt_version("Grade strictly. box_scores")
        response = self._scored_response(version)

        payload = serializers.response_audit(response)

        self.assertEqual(payload["grading"]["prompt_version"], version)
        self.assertEqual(payload["grading"]["judge_model"], "gemini-3-pro")

    def test_an_unstamped_score_reads_as_empty_not_as_a_guess(self):
        """A score graded before versioning must carry NO version rather than
        an invented one. The migration tags those `pre-versioning` in one
        deliberate pass; the storer never fabricates a digest."""
        response = self._scored_response("")

        # `assertFalse`, not `== ""`: Odoo stores an empty Char as False, and
        # the fact under test is "no rubric is claimed" - not which of the two
        # falsy spellings landed. Asserting the spelling would make this test
        # fail for a reason that has nothing to do with provenance.
        self.assertFalse(response.llm_prompt_version)

    def test_the_attribution_is_not_copyable(self):
        """`copy=False`, matching `llm_judge_model`: a copy has not been graded,
        so carrying a grading provenance onto it would attribute a score that
        was never produced.

        ASSERTED ON THE FIELD, not by calling `copy()`. The unique index
        `assessments_be_response_uniq_eval_q_sess` allows one answer per
        (evaluator, question) - correctly, a candidate answers a question once -
        so `copy()` on a response cannot complete at all and would fail this
        test for a reason that has nothing to do with the attribution.
        """
        Response = self.env["assessments.be.response"]

        self.assertFalse(Response._fields["llm_prompt_version"].copy)
        self.assertTrue(Response._fields["llm_prompt_version"].readonly,
                        "a grading attribution is written by the grader, never "
                        "typed by a person")
