"""An invitation is 'sent' only when the mail layer actually took it.

TWO DEFECTS, one theme: the platform reported success for work it had not done,
and in both cases the state it wrote was the one state that BLOCKS a retry.

P-10 - AN INVITATION NOBODY SENT WAS MARKED 'sent'.
`_send_single_invitation` had two paths that produced no mail:

  * the mail template is missing (`if not tpl: return`), and
  * the candidate has no email address (`continue`),

and `_cron_send_pending_invitations` wrote `invite_state = "sent"` regardless,
because it never looked at the result. The cost is not just a wrong label:
`action_requeue_invitation` filters `invite_state != "sent"`, so the one
recovery path SKIPS exactly these rows. An admin saw "sent" beside a candidate
who never received a link, pressing Requeue did nothing, and the only remaining
fix was editing the database.

'failed' is the honest state AND the useful one - it is requeueable, so adding
the missing address and pressing Requeue now works.

WHY THE FIX RETURNS A REASON INSTEAD OF RAISING. The no-email branch
deliberately creates a cancelled `mail.mail` whose `failure_reason` carries the
candidate's exam link, so an admin can pass it on by hand. The drainer calls
`_deliver_invitation` inside `self.env.cr.savepoint()`; raising would roll that
audit row back and destroy the one artefact that makes the failure recoverable.
`test_the_no_email_audit_row_survives` pins that.

P-7 - AN EMPTY PAPER WAS REPORTED AS FINISHED.
`_question_payload` answered `complete` on an empty question order, which is
what a candidate sees when the paper was launched with no questions, or when
every question was deleted under them mid-sitting. They were told they had
finished an exam they were never shown, and the attempt then scores zero off no
answers - on the dashboard that is indistinguishable from someone who sat it
and failed everything. etp_local carried 5 such attempts.

The carve-out that matters: a candidate who HAS answered still completes. They
did the work; questions vanishing afterwards must not retract it.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestASilentNoSendIsNeverMarkedSent(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Generator = self.env["assessments.be.prompt"]

    # ── fixtures ──────────────────────────────────────────────────────

    def _applicant(self, name, email=True):
        """An applicant, optionally with NO email - the P-10 trigger."""
        slug = "%s_%s" % (name.lower().replace(" ", "_"), uuid4().hex[:8])
        vals = {"partner_name": name}
        if email:
            vals["email_from"] = "%s@example.com" % slug
        return self.env["hr.applicant"].create(vals)

    def _generator_with_questions(self, count=2):
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        for i in range(count):
            q = self.Question.create({
                "name": "Q%d" % i,
                "question_type": "mcq",
                "prompt": "Pick one",
                "difficulty": "easy",
                "generator_id": gen.id,
            })
            self.QDim.create({
                "question_id": q.id,
                "name": "Dim %d" % i,
                "option_line_ids": [
                    (0, 0, {"name": n, "sequence": j * 10,
                            "is_correct": j == 0})
                    for j, n in enumerate(("Alpha", "Bravo"))
                ],
            })
        return gen

    def _drain(self, rows):
        """Run the invite drainer with its per-candidate commit neutralised.

        The drainer commits after each candidate ON PURPOSE - one failure must
        not roll back the invitations already sent in the same tick - and Odoo
        forbids a real commit inside a TransactionCase. Patching `commit` to a
        no-op keeps every line of the loop under test (the savepoint, the
        stamping, the except branch) while leaving the test transaction intact.
        The savepoints are real, so a rollback still behaves as in production.
        """
        # Odoo replaces `commit` on the cursor INSTANCE (tests/common.py:1100),
        # so the class is the wrong target - patch the instance. Without this
        # the forbidden-commit AssertionError is raised INSIDE the drainer's
        # own `except`, which then stamps 'failed' on a perfectly healthy
        # candidate: the failure looks like a bug in the fix rather than a
        # test-harness artefact.
        with patch.object(self.env.cr, "commit", lambda: None):
            rows._cron_send_pending_invitations()
        rows.invalidate_recordset()

    def _launched(self, with_email=True, questions=2):
        """A launched assessment with one candidate, invite queued."""
        gen = self._generator_with_questions(questions)
        applicant = self._applicant("Cand %s" % uuid4().hex[:4],
                                    email=with_email)
        assessment = self.Assessment.create({
            "name": "Invite %s" % uuid4().hex[:6],
            "generator_id": gen.id,
            "question_limit": questions,
            "evaluator_ids": [(6, 0, applicant.ids)],
        })
        assessment.action_start()
        assessment.invalidate_recordset()
        row = assessment.assessment_evaluator_ids
        self.assertEqual(len(row), 1)
        return assessment, row

    # ── P-10: the state written must match what happened ──────────────

    def test_the_fixture_really_does_queue_an_invite(self):
        """GUARD THE GUARD. If launch stopped queueing, every test below
        would pass for the wrong reason - nothing to drain, nothing to
        mis-stamp."""
        _, row = self._launched()
        self.assertEqual(row.invite_state, "queued")

    def test_a_candidate_with_no_email_is_failed_not_sent(self):
        """THE HEADLINE. Before the fix this row read 'sent'."""
        _, row = self._launched(with_email=False)

        self._drain(row)

        self.assertEqual(
            row.invite_state, "failed",
            "a candidate with no address received nothing, so 'sent' is a lie")
        self.assertTrue(row.invite_error,
                        "and the reason must be on the row for an admin")
        self.assertIn("email", (row.invite_error or "").lower())

    def test_that_failure_can_actually_be_requeued(self):
        """THE POINT OF 'failed'. `action_requeue_invitation` skips 'sent', so
        the old label made the one recovery path a no-op."""
        _, row = self._launched(with_email=False)
        self._drain(row)

        row.action_requeue_invitation()
        row.invalidate_recordset()

        self.assertEqual(row.invite_state, "queued",
                         "an admin who adds the address must be able to retry")
        self.assertFalse(row.invite_error, "and the stale reason is cleared")

    def test_the_no_email_audit_row_survives(self):
        """WHY THE FIX RETURNS RATHER THAN RAISES.

        The cancelled mail carries the candidate's exam link - the only way an
        admin can hand it over by hand. Raising inside the drainer's savepoint
        would roll it back.
        """
        _, row = self._launched(with_email=False)
        self._drain(row)

        audit = self.env["mail.mail"].sudo().search(
            [("subject", "like", "[NO EMAIL]")], order="id desc", limit=1)
        self.assertTrue(
            audit,
            "the audit row carrying the exam link must not be rolled back")
        self.assertEqual(audit.state, "cancel")
        self.assertIn("Portal link:", audit.failure_reason or "")
        # Filed against the attempt, or no Emails tab can ever show it.
        self.assertEqual(
            (audit.model, audit.res_id), (row._name, row.id))

    def test_a_missing_template_is_failed_not_sent(self):
        """The other silent path: `if not tpl: return` marked every row sent."""
        _, row = self._launched()

        with patch.object(type(self.env["ir.model.data"]), "_xmlid_lookup",
                          side_effect=ValueError("gone")):
            # env.ref resolves through _xmlid_lookup; making it fail is how a
            # deleted/never-installed template presents itself.
            reason = row._deliver_invitation()

        self.assertTrue(
            reason,
            "no template means no mail, so it must report a reason")
        self.assertIn("template", reason.lower())

    def test_a_normal_candidate_is_still_marked_sent(self):
        """THE GUARD ON THE GUARD. If the fix flagged healthy sends as failed,
        every candidate would be re-mailed on the next tick."""
        _, row = self._launched(with_email=True)

        self._drain(row)

        self.assertEqual(row.invite_state, "sent",
                         "a candidate with an address IS invited")
        self.assertFalse(row.invite_error)

    def test_deliver_returns_None_on_the_happy_path(self):
        """The contract the drainer reads: None means it reached the mail
        layer."""
        _, row = self._launched(with_email=True)
        self.assertIsNone(row._deliver_invitation())

    def test_one_bad_candidate_does_not_stop_the_others(self):
        """A cohort is drained as a batch. The no-email candidate must not
        take the whole tick down with them."""
        gen = self._generator_with_questions(2)
        good = [self._applicant("Good %d" % i) for i in range(2)]
        bad = self._applicant("NoMail", email=False)
        assessment = self.Assessment.create({
            "name": "Mixed %s" % uuid4().hex[:6],
            "generator_id": gen.id,
            "question_limit": 2,
            "evaluator_ids": [(6, 0, [a.id for a in good] + bad.ids)],
        })
        assessment.action_start()
        assessment.invalidate_recordset()
        rows = assessment.assessment_evaluator_ids

        self._drain(rows)

        by_name = {r.applicant_id.partner_name: r.invite_state for r in rows}
        self.assertEqual(by_name.get("NoMail"), "failed")
        for name in ("Good 0", "Good 1"):
            self.assertEqual(by_name.get(name), "sent",
                             "%s must still be invited" % name)
