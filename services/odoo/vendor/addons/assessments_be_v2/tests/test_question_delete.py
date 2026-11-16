"""Deleting a question, and deleting the generator that authored it.

WHAT "DELETE" MEANS HERE, AND WHY IT IS NOT `unlink`. The product offers one
action - take this out of the bank - and the implementation splits it in two
depending on whether the row carries history:

  * `response.question_id` is ondelete="cascade". Unlinking a question somebody
    has ANSWERED deletes their answer, and every score already computed from it
    silently changes. A released result an operator may have hired or rejected
    somebody on quietly becomes a different number, with no undo and no record.
  * `assessment.question_ids` is a plain m2m. Unlinking removes the question
    from papers that were built, launched and possibly already sat, so a
    six-question paper becomes a five-question paper after the fact.

So a referenced question is RETIRED and an unreferenced one is erased. Both
read as "gone from the bank" to the operator, and only one of them is
recoverable - which is exactly backwards from what a naive implementation would
do, because the naive one erases the valuable rows and keeps the worthless.

RETIRED IS NOT ARCHIVED, and that distinction is load-bearing enough to have
its own assertion. Odoo filters archived records out of RELATIONAL reads, so
setting `active = False` empties the question out of `assessment.question_ids`
and the paper silently loses a question - the same damage as deleting it. The
record therefore stays active and carries a `retired` flag that only the bank
filters on. `test_a_question_on_an_assessment_is_retired_not_erased` fails on
an `active`-based implementation, which is how this was caught.

These are the tests that stop that regressing. `test_a_question_with_answers_is_never_erased`
and `test_deleting_a_generator_keeps_the_answers_to_its_questions` are the two
that matter: their failure mode is silent, irreversible data loss that nothing
in the UI would report.

TransactionCase rather than HttpCase, matching test_candidate_password: the
rule under test is the helper the routes delegate to, not the transport. The
helpers deliberately read `record.env` rather than `request.env` so they can be
called here with no request in scope.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api.serializers import (
    question_usage,
)
from odoo.addons.assessments_be_v2.controllers.api.write import (
    _delete_generator, _generator_delete_preview, _question_delete_preview,
    _retire_or_delete_question,
)


@tagged("-at_install", "post_install")
class TestQuestionDelete(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Generator = self.env["assessments.be.prompt"]
        self.Question = self.env["assessments.be.question"]
        self.Assessment = self.env["assessments.be"]
        self.Applicant = self.env["hr.applicant"]
        self.Response = self.env["assessments.be.response"]

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _generator(self, name="Forklift SOP"):
        return self.Generator.create({"name": "%s %s" % (name, uuid4().hex[:6])})

    def _question(self, generator=None, name="Battery charging"):
        # `prompt` is required=True on the model - a question with no text is
        # not a question - so the fixture has to carry one.
        return self.Question.create({
            "name": "%s %s" % (name, uuid4().hex[:6]),
            "question_type": "mcq",
            "prompt": "What does the SOP require before charging a battery?",
            "generator_id": generator.id if generator else False,
        })

    def _assessment(self, questions, name="Warehouse Safety"):
        return self.Assessment.create({
            "name": "%s %s" % (name, uuid4().hex[:6]),
            "question_ids": [(6, 0, questions.ids)],
        })

    def _answer(self, assessment, question):
        """One submitted answer, which is the thing that must never be lost."""
        applicant = self.Applicant.create({
            "partner_name": "Asha Rao",
            "email_from": "asha_%s@example.com" % uuid4().hex[:8],
        })
        return self.Response.create({
            "assessment_id": assessment.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "justification": "Because the SOP says so.",
        })

    # ------------------------------------------------------------------
    # The rule: erase what has no history, retire what does
    # ------------------------------------------------------------------
    def test_an_unused_question_is_really_deleted(self):
        # Nothing points at it, so there is nothing to protect and no reason to
        # leave a row behind.
        q = self._question()
        qid = q.id

        self.assertEqual(_retire_or_delete_question(q)["outcome"], "deleted")
        self.assertFalse(
            self.Question.with_context(active_test=False).browse(qid).exists(),
            "an unreferenced question should leave no row behind",
        )

    def test_a_question_on_an_assessment_is_retired_not_erased(self):
        q = self._question()
        asm = self._assessment(q)

        self.assertEqual(_retire_or_delete_question(q)["outcome"], "retired")
        self.assertTrue(q.exists(), "the row must survive")
        self.assertTrue(q.retired, "but it must be out of the bank")
        self.assertTrue(
            q.active,
            "retiring must NOT archive: Odoo filters archived records out of "
            "relational reads, so `active = False` empties question_ids and "
            "the paper silently loses a question",
        )
        # THE POINT OF RETIRING: the paper still holds it.
        self.assertIn(
            q, asm.question_ids,
            "an assessment must keep the question it was built with",
        )

    def test_a_question_with_answers_is_never_erased(self):
        # The severe one. `response.question_id` is ondelete="cascade", so an
        # unlink here would delete the answer and change a recorded score.
        q = self._question()
        asm = self._assessment(q)
        answer = self._answer(asm, q)

        self.assertEqual(_retire_or_delete_question(q)["outcome"], "retired")
        self.assertTrue(
            answer.exists(),
            "deleting a question must never delete somebody's answer to it",
        )
        self.assertEqual(answer.question_id, q)

    def test_retiring_takes_it_out_of_the_bank_for_good(self):
        # "The user will not be able to use those questions for further use":
        # an ordinary search - which is what the bank list and the assessment
        # question picker both run - must not find it.
        q = self._question()
        self._assessment(q)
        _retire_or_delete_question(q)

        self.assertNotIn(
            q, self.Question.search([("id", "=", q.id), ("retired", "=", False)]),
            "the bank list, and the picker a new assessment draws from, both "
            "run this domain - a retired question must not be offered again",
        )
        self.assertIn(
            q, self.Question.search([("id", "=", q.id)]),
            "the record is still ACTIVE, so everything that is not the bank - "
            "the papers using it above all - still sees it",
        )

    def test_restoring_puts_it_back(self):
        # Archived, not deleted: Delete on a used question is final now.
        q = self._question()
        self._assessment(q)
        q.action_retire_from_bank()

        q.retired = False
        self.assertIn(
            q,
            self.Question.search([("id", "=", q.id), ("retired", "=", False)]),
        )

    # ------------------------------------------------------------------
    # The preview must agree with the work
    # ------------------------------------------------------------------
    def test_preview_predicts_the_outcome_and_writes_nothing(self):
        # The operator confirms a sentence built from the preview; if the two
        # disagree the confirmation is a lie.
        used = self._question()
        asm = self._assessment(used)
        unused = self._question()

        used_preview = _question_delete_preview(used)
        unused_preview = _question_delete_preview(unused)

        self.assertEqual(used_preview["outcome"], "retired")
        self.assertEqual(used_preview["assessment_count"], 1)
        self.assertEqual(
            [a["id"] for a in used_preview["assessments"]], [asm.id],
            "the confirmation names the papers by name, so it carries them",
        )
        self.assertEqual(unused_preview["outcome"], "deleted")

        # Nothing was written.
        self.assertFalse(used.retired)
        self.assertTrue(unused.exists())

        # And the real call agrees with what was predicted.
        self.assertEqual(
            _retire_or_delete_question(used)["outcome"], used_preview["outcome"])
        self.assertEqual(
            _retire_or_delete_question(unused)["outcome"],
            unused_preview["outcome"])

    def test_usage_counts_answers_without_listing_them(self):
        q = self._question()
        asm = self._assessment(q)
        self._answer(asm, q)
        self._answer(asm, q)

        usage = question_usage(q)
        self.assertEqual(usage["answer_count"], 2)
        self.assertEqual(usage["assessment_count"], 1)
        self.assertTrue(usage["referenced"])

    def test_an_untouched_question_reports_no_usage(self):
        usage = question_usage(self._question())
        self.assertEqual(usage["answer_count"], 0)
        self.assertEqual(usage["assessment_count"], 0)
        self.assertFalse(usage["referenced"])

    # ------------------------------------------------------------------
    # Deleting the generator
    # ------------------------------------------------------------------
    def test_deleting_a_generator_takes_its_questions_out_of_the_bank(self):
        # `generator_id` is ondelete="set null", so WITHOUT this the questions
        # would survive the delete still sitting in the bank, still pickable
        # for a new paper, and no longer able to name the SOP that justified
        # them - a question with no provenance is what the review gate exists
        # to prevent.
        gen = self._generator()
        unused = self._question(gen)
        used = self._question(gen)
        asm = self._assessment(used)

        summary = _delete_generator(gen)

        self.assertFalse(gen.exists(), "the generator row is really deleted")
        self.assertFalse(
            self.Question.with_context(active_test=False)
            .browse(unused.id).exists(),
            "a question nothing points at goes with its generator",
        )
        self.assertTrue(used.exists(), "a used one keeps its row")
        self.assertTrue(used.retired, "but leaves the bank")
        self.assertIn(used, asm.question_ids, "the paper is untouched")
        self.assertEqual(summary["retired_question_count"], 1)
        self.assertEqual(summary["deleted_question_count"], 1)

    def test_deleting_a_generator_keeps_the_answers_to_its_questions(self):
        # The other severe one: a generator delete must not become a way to
        # destroy scoring history through the back door.
        gen = self._generator()
        q = self._question(gen)
        asm = self._assessment(q)
        answer = self._answer(asm, q)

        _delete_generator(gen)

        self.assertTrue(answer.exists())
        self.assertEqual(answer.question_id, q)
        self.assertTrue(q.exists())

    def test_deleting_a_generator_removes_its_drafts_and_files(self):
        # Neither is history anybody can appeal to - a draft that was never
        # approved, and a document already read into tags. Both are
        # ondelete="cascade", so this pins the behaviour rather than adding it.
        gen = self._generator()
        draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": gen.id,
            "name": "Draft that was never approved",
        })
        draft_id = draft.id

        _delete_generator(gen)

        self.assertFalse(
            self.env["assessments.be.prompt.question"]
            .browse(draft_id).exists(),
        )

    def test_generator_preview_counts_what_is_at_stake(self):
        gen = self._generator()
        unused = self._question(gen)
        used = self._question(gen)
        asm = self._assessment(used)

        preview = _generator_delete_preview(gen)

        self.assertEqual(preview["question_count"], 2)
        self.assertEqual(preview["retired_question_count"], 1)
        self.assertEqual(preview["deleted_question_count"], 1)
        self.assertEqual([a["id"] for a in preview["assessments"]], [asm.id])
        # Wrote nothing.
        self.assertTrue(gen.exists())
        self.assertTrue(unused.exists())
        self.assertFalse(used.retired)

    def test_generator_preview_deduplicates_assessments(self):
        # One paper usually uses several of a generator's questions, and naming
        # it once is the sentence worth reading.
        gen = self._generator()
        a = self._question(gen)
        b = self._question(gen)
        asm = self._assessment(a + b)

        preview = _generator_delete_preview(gen)
        self.assertEqual(len(preview["assessments"]), 1)
        self.assertEqual(preview["assessments"][0]["id"], asm.id)

    # ------------------------------------------------------------------
    # Attribution
    # ------------------------------------------------------------------
    def test_a_question_knows_which_assessments_use_it(self):
        # The inverse m2m this feature added. Without it "what would deleting
        # this break?" costs a search per row, which the bank list would pay on
        # every row it draws.
        q = self._question()
        asm = self._assessment(q)
        self.assertEqual(q.assessment_ids, asm)
