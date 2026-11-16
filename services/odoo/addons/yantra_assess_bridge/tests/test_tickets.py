"""Launch tickets: stored as a hash, single use, two minutes; the bearer they buy lives to the attempt's deadline plus
half an hour (twelve hours at most); old tickets are vacuumed; a Yantra worker's invitation mail is left to Yantra."""

from datetime import timedelta
from unittest.mock import patch

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.yantra_assess_bridge.models import ticket as ticket_module
from odoo.addons.yantra_assess_bridge.models.ticket import TicketRefused, digest

from .common import bridge_settings

SUB = "00000000-0000-4000-8000-0000000000a1"


@tagged("post_install", "-at_install")
class TestTickets(TransactionCase):
    def setUp(self):
        super().setUp()
        bridge_settings(self.env)
        self.user, self.applicant = self.env["res.users"]._yantra_ensure_person(
            SUB, email="asha@yantra.local", verified=True, name="Asha"
        )
        self.Ticket = self.env["yantra.assess.ticket"]

    def test_only_the_hash_is_stored_and_a_ticket_buys_one_bearer_once(self):
        raw, record = self.Ticket._mint(self.user, "staff", next_path="/admin", return_url="http://localhost:8095/x")
        self.assertEqual(record.token_hash, digest(raw))
        self.assertNotIn(raw, str(record.read()))
        got = self.Ticket._redeem(raw)
        bearer = self.env["api.access_token"].sudo().search([("access_token", "=", got["access_token"])])
        self.assertEqual(bearer.user_id, self.user)
        self.assertFalse(bearer.has_expired())
        self.assertEqual((got["next"], got["return_url"], got["exam_token"]), ("/admin", "http://localhost:8095/x", None))
        with self.assertRaises(TicketRefused) as e:
            self.Ticket._redeem(raw)
        self.assertEqual(e.exception.code, "ticket_used")

    def test_unknown_empty_expired_and_inactive_are_each_named(self):
        for raw, code in (("", "invalid_ticket"), ("nope", "invalid_ticket")):
            with self.assertRaises(TicketRefused) as e:
                self.Ticket._redeem(raw)
            self.assertEqual(e.exception.code, code)
        raw, record = self.Ticket._mint(self.user, "staff")
        with self.assertRaises(TicketRefused) as e:
            self.Ticket._redeem(raw, now=record.expires_at + timedelta(seconds=1))
        self.assertEqual(e.exception.code, "ticket_expired")
        raw, _ = self.Ticket._mint(self.user, "staff")
        self.user.active = False
        with self.assertRaises(TicketRefused) as e:
            self.Ticket._redeem(raw)
        self.assertEqual(e.exception.code, "account_inactive")

    def test_a_ticket_lives_its_configured_seconds_never_under_ten(self):
        now = fields.Datetime.now()
        _, record = self.Ticket._mint(self.user, "staff", now=now)
        self.assertEqual(record.expires_at, now + timedelta(seconds=120))
        self.env["ir.config_parameter"].sudo().set_param("yantra_assess_bridge.ticket_ttl_seconds", "1")
        _, record = self.Ticket._mint(self.user, "staff", now=now)
        self.assertEqual(record.expires_at, now + timedelta(seconds=10))

    def test_the_bearer_ends_half_an_hour_after_the_attempts_deadline(self):
        now = fields.Datetime.now()
        evaluator = self._attempt()
        evaluator.deadline_datetime = now + timedelta(minutes=15)
        raw, _ = self.Ticket._mint(self.user, "candidate", evaluator=evaluator, now=now)
        got = self.Ticket._redeem(raw, now=now)
        self.assertEqual(got["expires_at"], fields.Datetime.to_string(now + timedelta(minutes=45)))
        self.assertEqual(got["exam_token"], evaluator.access_token)
        raw, _ = self.Ticket._mint(self.user, "candidate", evaluator=evaluator, now=now)
        evaluator.deadline_datetime = now + timedelta(days=3)
        got = self.Ticket._redeem(raw, now=now)
        self.assertEqual(got["expires_at"], fields.Datetime.to_string(now + timedelta(hours=12)))

    def test_old_tickets_are_vacuumed(self):
        _, old = self.Ticket._mint(self.user, "staff", now=fields.Datetime.now() - timedelta(days=2))
        _, fresh = self.Ticket._mint(self.user, "staff")
        self.Ticket._gc_spent()
        self.assertFalse(old.exists())
        self.assertTrue(fresh.exists())

    def test_a_yantra_workers_invitation_is_not_mailed_but_others_are(self):
        evaluator = self._attempt()
        with patch.object(type(self.env["assessments.be.evaluator"]), "_send_single_invitation") as send:
            self.assertIsNone(evaluator._deliver_invitation())
            send.assert_not_called()
        other = self.env["res.users"].with_context(no_reset_password=True).create(
            {"name": "Other", "login": "other@corp.example", "email": "other@corp.example"}
        )
        applicant, _ = self.env["hr.applicant"].sudo()._be_ensure_applicant_for_user(other)
        theirs = self._attempt(applicant)
        with patch.object(type(self.env["assessments.be.evaluator"]), "_send_single_invitation", return_value={}) as send:
            theirs._deliver_invitation()
            send.assert_called_once()
        self.env["ir.config_parameter"].sudo().set_param("yantra_assess_bridge.suppress_invitations", "0")
        with patch.object(type(self.env["assessments.be.evaluator"]), "_send_single_invitation", return_value={}) as send:
            evaluator._deliver_invitation()
            send.assert_called_once()

    def _attempt(self, applicant=None):
        assessment = self.env["assessments.be"].sudo().create({"name": "Ticket paper", "duration_minutes": 15})
        return self.env["assessments.be.evaluator"].sudo().create(
            {"assessment_id": assessment.id, "applicant_id": (applicant or self.applicant).id}
        )

    def test_the_module_constants_are_what_the_contract_says(self):
        self.assertEqual(ticket_module.TICKET_TTL, 120)
        self.assertEqual(ticket_module.TOKEN_MAX, timedelta(hours=12))
