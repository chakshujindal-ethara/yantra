# -*- coding: utf-8 -*-
"""Re-posting the same answer must write NOTHING.

THE DEFECT, measured on stage during the real assessment of 2026-09-03 with 588
concurrent candidates on assessments 58 and 59:

    /answer -> 200      29,867
    /answer -> 500      14,722      a THIRD of every answer save
    total 5xx           16,217

Every 500 was `psycopg2.errors.SerializationFailure`, and the statement was
always the same one:

    ERROR: could not serialize access due to concurrent delete
    DELETE FROM "assessments_be_response_line" WHERE id IN (...)

The cause was `_update_response` rewriting an answer as "delete every line, then
re-insert them":

    response.line_ids.unlink()
    response.write({"justification": ..., "line_ids": lines})

Both runners post an answer MORE THAN ONCE by design - the Flutter client's
debounced autosave (`_answerSync`) and every navigation each send the current
answer - so two requests rewriting the same response is the normal path, not an
edge case. Delete-then-re-add made each of them write rows the other was
reading. Odoo's `service.model.retrying` replays a serialization failure five
times, and at this concurrency the collisions exhausted all five (`_retry=5` in
the logs) before surfacing as a 500.

NO ANSWER WAS LOST - verified over all 9,399 objective rows of both papers: every
blank one carried `auto_submitted=True`, i.e. a placeholder written by
`_auto_submit_expired`, and zero blank rows came from a failed save. The client's
retry covered the write. The cost was paid in TIME: candidates burnt their clock
on retries and 58 attempts auto-submitted with questions still unanswered.

WHAT THESE TESTS ASSERT, and why it is not a concurrency simulation. Two
transactions genuinely racing cannot be produced inside a `TransactionCase` - it
is one transaction by construction. The invariant that actually prevents the
outage is observable in a single transaction: re-saving an unchanged answer must
issue no DELETE and no INSERT on `assessments_be_response_line`, because a
statement never issued cannot collide. That is asserted here by watching row ids,
which is exactly what a concurrent sibling would have been reading.

Sibling of test_answering_does_not_write_shared_rows.py, which covers the OTHER
contention class: stored computed fields writing rows the whole cohort shares.
That one is about `UPDATE`s on shared rows; this one is about `DELETE`s on the
answer's own child rows.
"""
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestResavingAnAnswerWritesOnlyTheDiff(TransactionCase):

    def setUp(self):
        super().setUp()
        self.assessment = self.env["assessments.be"].create({
            "name": "Diff-only answer saves",
        })
        self.question = self.env["assessments.be.question"].create({
            "name": "Which of these count as a watermark?",
            "prompt": "Which of these count as a watermark?",
            "question_type": "msq",
            "assessment_ids": [(4, self.assessment.id)],
        })
        self.dimension = self.env["assessments.be.question.dimension"].create({
            "question_id": self.question.id,
            "name": "Overall",
            "input_kind": "multipleChoice",
        })
        self.option_a, self.option_b, self.option_c = [
            self.env["assessments.be.question.dimension.option"].create({
                "question_dimension_id": self.dimension.id,
                "name": label,
            })
            for label in ("A handle over the whole clip", "A logo for 2s",
                          "Subtitles burnt in")
        ]
        self.applicant = self.env["hr.applicant"].create({
            "partner_name": "Ali Ubaid",
        })
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": self.applicant.id,
        })
        self.response = self.env["assessments.be.response"].create({
            "assessment_id": self.assessment.id,
            "assessment_evaluator_id": self.evaluator.id,
            "evaluator_id": self.applicant.id,
            "question_id": self.question.id,
            "line_ids": self._lines(self.option_a, self.option_b),
        })

    def _lines(self, *options):
        """The (0, 0, vals) command list `_selected_option_lines` produces."""
        return [
            (0, 0, {"question_dimension_id": self.dimension.id,
                    "selected_option_id": option.id})
            for option in options
        ]

    def _reconcile(self, *options):
        # `services/`, not a controller. The rule used to live at module level in
        # `controllers/portal.py` and be imported out of there by the JSON API -
        # so the API's hot write path depended on the QWeb runner's module for
        # its own core rule. Neither controller owns it; it touches no `request`.
        from odoo.addons.assessments_be_v2.services.answer_lines import (
            reconcile_response_lines,
        )
        return reconcile_response_lines(self.response, self._lines(*options))

    def test_an_unchanged_resave_touches_no_row(self):
        """THE HEADLINE, and the whole outage.

        The runner re-posts the SAME answer constantly. If that re-post deletes
        and re-inserts the lines, it collides with any sibling request reading
        them - which is the 14,722 failures. Row ids surviving unchanged is the
        proof that no DELETE and no INSERT was issued: `unlink()` would have
        destroyed these ids, and a re-insert would have minted new ones.
        """
        before = set(self.response.line_ids.ids)
        self.assertEqual(len(before), 2, "fixture should hold two lines")

        wrote = self._reconcile(self.option_a, self.option_b)

        self.assertFalse(
            wrote,
            "re-saving an unchanged answer reported a write; every such write "
            "is a row a concurrent sibling save can serialize against")
        self.assertEqual(
            set(self.response.line_ids.ids), before,
            "the line ROW IDS changed on an unchanged re-save, so the lines "
            "were deleted and re-inserted - this is the delete-then-re-add "
            "pattern that 500'd a third of all answer saves on 2026-09-03")

    def test_deselecting_one_option_keeps_the_other_row(self):
        """A real edit writes, but only the part that changed.

        The fix must not be "never write" - it must be "write the diff". The
        row for the option the candidate KEPT has to survive, because deleting
        and re-adding it is precisely the collision being removed.
        """
        kept = self.response.line_ids.filtered(
            lambda line: line.selected_option_id == self.option_a)
        kept_id = kept.id

        wrote = self._reconcile(self.option_a)

        self.assertTrue(wrote, "dropping an option is a real change")
        self.assertEqual(
            self.response.line_ids.mapped("selected_option_id"), self.option_a,
            "the answer should now be option A alone")
        self.assertEqual(
            self.response.line_ids.ids, [kept_id],
            "the KEPT option's row was replaced rather than left alone")

    def test_adding_an_option_leaves_existing_rows_alone(self):
        """Selecting one more option must not rewrite the ones already held."""
        before = set(self.response.line_ids.ids)

        wrote = self._reconcile(self.option_a, self.option_b, self.option_c)

        self.assertTrue(wrote, "adding an option is a real change")
        self.assertEqual(len(self.response.line_ids), 3)
        self.assertTrue(
            before.issubset(set(self.response.line_ids.ids)),
            "adding a third option destroyed and re-created the first two")

    def test_clearing_every_option_removes_every_row(self):
        """The empty case still has to work, or an answer cannot be cleared."""
        wrote = self._reconcile()

        self.assertTrue(wrote, "clearing an answer is a real change")
        self.assertFalse(self.response.line_ids,
                         "clearing left lines behind")

    def test_no_answer_save_path_deletes_all_lines_to_rewrite_an_answer(self):
        """The static invariant, over every module on the answer-save path.

        The API runner and the QWeb portal runner both saved answers and BOTH
        carried this bug - portal.py had two copies of it inside one function.
        A concurrency test cannot run here (see the module docstring), but
        `line_ids.unlink()` on the answer-save path is statically detectable, and
        its reappearance in either file would restore the outage.
        """
        import inspect

        # `controllers.portal` was the third module in this list and is retired.
        # `services.answer_lines` is now the ONLY implementation, so it is the
        # file that matters most; the controller is still checked because a caller
        # can reintroduce the delete AROUND the helper rather than inside it.
        from odoo.addons.assessments_be_v2.controllers.api import candidate
        from odoo.addons.assessments_be_v2.services import answer_lines

        for module in (answer_lines, candidate):
            source = inspect.getsource(module)
            # Strip comments so the account of the bug in the fix's own comment
            # block does not count as the bug.
            code = "\n".join(
                line for line in source.splitlines()
                if not line.lstrip().startswith("#")
            )
            self.assertNotIn(
                "line_ids.unlink()", code,
                "%s deletes every answer line to rewrite an answer. Two saves "
                "of the same answer then collide on "
                "assessments_be_response_line with 'could not serialize "
                "access due to concurrent delete' - a third of all answer "
                "saves failed this way at 588 concurrent candidates. Reconcile "
                "the diff instead; see services.answer_lines."
                % module.__name__)
