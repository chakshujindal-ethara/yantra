"""Every assessment is timed, and the floor is two minutes.

THE EXPECTATION IN THIS FILE WAS DELIBERATELY REVERSED. It used to argue that
0 meant "no limit" and that refusing it would delete a feature rather than
tighten a bound. That reading is what let an assessment be launched at 0 and
its candidates emailed "Duration: 0 minutes". An untimed sitting never gets a
`deadline_datetime`, so the expiry cron skips it by design and the attempt can
never be swept - the assessment sits in `in_progress` indefinitely.

TWO MECHANISMS, and the second is the one that matters. The constraint fires
on create, and on write only when the field is in the vals. `action_start`
writes `state`, `question_ids` and `start_date` and never the duration, so a
row already sitting below the floor would launch untouched. The launch gate is
what catches that, and it is tested here alongside the constraint.

TransactionCase, matching the house style: the assertions are about the model,
which is what makes the rule hold for the Odoo form and the API alike -
`api_endpoint` turns a ValidationError into the standard failure envelope.
"""
from uuid import uuid4

from odoo.exceptions import UserError, ValidationError
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestDurationFloor(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]

    def _make(self, minutes):
        return self.Assessment.create({
            "name": "Duration %s" % uuid4().hex[:6],
            "duration_minutes": minutes,
        })

    # ------------------------------------------------------------------
    # The floor
    # ------------------------------------------------------------------
    def test_zero_is_refused(self):
        """The reversal. 0 was "no limit"; it is now simply invalid."""
        with self.assertRaises(ValidationError):
            self._make(0)

    def test_one_minute_is_refused(self):
        with self.assertRaises(ValidationError):
            self._make(1)

    def test_two_minutes_is_the_floor_and_is_allowed(self):
        self.assertEqual(self._make(2).duration_minutes, 2)

    def test_editing_an_existing_record_below_the_floor_is_refused(self):
        """Constraints fire on write, not only on create."""
        rec = self._make(30)
        for bad in (1, 0):
            with self.assertRaises(ValidationError):
                rec.duration_minutes = bad

    def test_the_message_does_not_offer_zero(self):
        """The old message advertised 0 as a legal value. It is not."""
        with self.assertRaises(ValidationError) as caught:
            self._make(1)
        message = str(caught.exception)
        self.assertIn("2", message)
        self.assertNotIn("no limit", message.lower())

    # ------------------------------------------------------------------
    # The default, which is load-bearing
    # ------------------------------------------------------------------
    def test_a_create_that_names_no_duration_still_works(self):
        """The canary for the whole change.

        `@api.constrains` runs after defaults are applied, so a default of 0
        under a floor of 2 would make EVERY create that omits the field raise -
        Odoo's own New button, the API create route, and around eleven test
        files in this suite. The default has to move with the floor.
        """
        rec = self.Assessment.create({"name": "Default %s" % uuid4().hex[:6]})
        self.assertGreaterEqual(rec.duration_minutes, 2)

    # ------------------------------------------------------------------
    # The launch gate, which the constraint cannot replace
    # ------------------------------------------------------------------
    def test_launching_below_the_floor_is_refused(self):
        """The hole the constraint alone leaves open.

        A row can sit below the floor - written before the rule existed, or by
        SQL - and `action_start` never writes the duration, so the constraint
        never fires on launch. Without an explicit check the assessment would
        launch and its candidates would be invited to a paper with no clock.
        """
        rec = self._make(30)
        # Straight to the column, the way a legacy row got there. Going through
        # the ORM would trip the constraint and prove nothing about launch.
        self.env.cr.execute(
            "UPDATE assessments_be SET duration_minutes = 0 WHERE id = %s",
            (rec.id,))
        rec.invalidate_recordset(["duration_minutes"])
        self.assertEqual(rec.duration_minutes, 0)

        with self.assertRaises(UserError) as caught:
            rec.action_start()

        self.assertIn("2 minutes", str(caught.exception))
        self.assertEqual(rec.state, "draft", "a refused launch must not move")
