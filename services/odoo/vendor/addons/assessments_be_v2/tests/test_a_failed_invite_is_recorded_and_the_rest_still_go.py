# -*- coding: utf-8 -*-
"""One invitation that fails is recorded as failed, and the batch goes on.

THE DEFECT. `_cron_send_pending_invitations` caught the exception and wrote
`invite_state = 'failed'` on the SAME transaction. When the failure was the
flush or the commit, that transaction was aborted (or held a snapshot that had
already lost the row), so the 'failed' write raised too - nothing was
recorded - and every later invitation in the batch ran on the dead
transaction and failed with it. A lost DB race was also branded a failure
instead of being left queued for the next tick.

The test drives a REAL aborted transaction: the fake commit runs a statement
that errors, and the fake rollback returns to a savepoint taken at the last
fake commit, which is what a real ROLLBACK does to this cron's state.
"""
import logging
from unittest.mock import patch
from uuid import uuid4

from psycopg2 import Error as PgError
from psycopg2.errors import SerializationFailure

from odoo.tests.common import TransactionCase, tagged

_LOGGER = "odoo.addons.assessments_be_v2.models"
_SP = "invite_probe_commit"


@tagged("-at_install", "post_install")
class TestAFailedInviteIsRecordedAndTheRestStillGo(TransactionCase):

    def setUp(self):
        super().setUp()
        Evaluator = self.env["assessments.be.evaluator"]
        # Only this test's invitations are drained: etp_local copies carry
        # queued rows of their own.
        Evaluator.search([("invite_state", "=", "queued")]).write(
            {"invite_state": "none"})
        gen = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        for i in range(2):
            question = self.env["assessments.be.question"].create({
                "name": "Q%d" % i, "question_type": "mcq",
                "prompt": "Pick one", "difficulty": "easy",
                "generator_id": gen.id})
            self.env["assessments.be.question.dimension"].create({
                "question_id": question.id, "name": "Dim %d" % i,
                "option_line_ids": [
                    (0, 0, {"name": n, "sequence": j * 10,
                            "is_correct": j == 0})
                    for j, n in enumerate(("Alpha", "Bravo"))]})
        applicants = self.env["hr.applicant"].create([{
            "partner_name": "Cand %d" % i,
            "email_from": "cand%d_%s@example.com" % (i, uuid4().hex[:8]),
        } for i in range(2)])
        assessment = self.env["assessments.be"].create({
            "name": "Invite %s" % uuid4().hex[:6],
            "generator_id": gen.id, "question_limit": 2,
            "evaluator_ids": [(6, 0, applicants.ids)]})
        assessment.action_start()
        assessment.invalidate_recordset()
        # In the drainer's own order, so the failing invitation comes FIRST
        # and the one after it has to run on whatever it left behind.
        self.bad, self.good = Evaluator.search(
            [("id", "in", assessment.assessment_evaluator_ids.ids)])
        self.assertEqual(
            (self.bad.invite_state, self.good.invite_state),
            ("queued", "queued"), "the fixture must queue both invitations")

    def _drain(self, commit_fails_for=None, deliver_raises_for=None):
        """Run the drainer with commit/rollback modelled on a savepoint.

        `commit_fails_for`: that evaluator's commit aborts the transaction and
        raises. `deliver_raises_for`: (evaluator, exception) for the send.
        """
        cr = self.env.cr
        Evaluator = type(self.env["assessments.be.evaluator"])
        original = Evaluator._deliver_invitation
        current, failed = [], []

        def deliver(ev):
            current.append(ev.id)
            if deliver_raises_for and ev == deliver_raises_for[0]:
                raise deliver_raises_for[1]
            return original(ev)

        def commit():
            if (commit_fails_for and current
                    and current[-1] == commit_fails_for.id and not failed):
                failed.append(True)
                try:
                    cr.execute("SELECT 1/0", log_exceptions=False)
                except PgError:
                    pass  # the transaction is now aborted, as in production
                raise RuntimeError("commit lost")
            cr.flush()
            cr.execute('RELEASE SAVEPOINT "%s"' % _SP)
            cr.execute('SAVEPOINT "%s"' % _SP)

        def rollback():
            cr.clear()
            cr.execute('ROLLBACK TO SAVEPOINT "%s"' % _SP)

        cr.execute('SAVEPOINT "%s"' % _SP)
        # Test mode, so `_warn_lost_race`'s fresh cursor reads this test's rows.
        with self.enter_registry_test_mode(), \
                patch.object(Evaluator, "_deliver_invitation", deliver), \
                patch.object(cr, "commit", commit), \
                patch.object(cr, "rollback", rollback), \
                self.assertLogs(_LOGGER, level=logging.WARNING) as logs:
            self.env["assessments.be.evaluator"]._cron_send_pending_invitations(
                batch=200)
        (self.bad | self.good).invalidate_recordset()
        return logs.output

    def test_a_failure_on_an_aborted_transaction_is_recorded(self):
        self._drain(commit_fails_for=self.bad)

        self.assertEqual(self.bad.invite_state, "failed")
        self.assertIn("commit lost", self.bad.invite_error or "")

    def test_one_bad_invite_does_not_poison_the_rest(self):
        self._drain(commit_fails_for=self.bad)

        self.assertEqual(self.good.invite_state, "sent")
        self.assertFalse(self.good.invite_error)

    def test_a_lost_db_race_is_left_queued(self):
        output = self._drain(deliver_raises_for=(
            self.bad, SerializationFailure(
                "could not serialize access due to concurrent update")))

        self.assertEqual(self.bad.invite_state, "queued")
        self.assertFalse(self.bad.invite_error)
        self.assertEqual(self.good.invite_state, "sent")
        self.assertTrue(any(
            "left for the next tick" in line and str(self.bad.id) in line
            for line in output), "\n".join(output))
