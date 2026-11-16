"""One-time launch tickets: how a Yantra worker reaches the Assessment v2 exam already signed in.

Yantra's assess adapter (holding the Keycloak service client's token) asks for a ticket for a person and an attempt;
the worker's browser carries it to the exam app in a URL fragment (never sent to a server, never logged); the app
redeems it once for an ordinary v2 bearer token (`api.access_token`) that lives until the attempt's deadline plus
half an hour, at most 12 hours. Only the sha256 of a ticket is stored, a ticket lives two minutes, and redeeming
takes a row lock, so two tabs racing for one ticket get one session between them.
"""

import hashlib
import secrets
from datetime import timedelta

from odoo import _, api, fields, models
from odoo.exceptions import UserError

TICKET_TTL = 120
TOKEN_MAX = timedelta(hours=12)
AFTER_DEADLINE = timedelta(minutes=30)


class TicketRefused(UserError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def digest(raw):
    return hashlib.sha256((raw or "").encode()).hexdigest()


class YantraAssessTicket(models.Model):
    _name = "yantra.assess.ticket"
    _description = "Yantra assessment launch ticket"
    _order = "id desc"

    token_hash = fields.Char(required=True, index=True, readonly=True)
    kind = fields.Selection([("candidate", "Candidate"), ("staff", "Staff")], required=True, readonly=True)
    user_id = fields.Many2one("res.users", required=True, ondelete="cascade", readonly=True)
    evaluator_id = fields.Many2one("assessments.be.evaluator", ondelete="cascade", readonly=True)
    next_path = fields.Char(readonly=True)
    return_url = fields.Char(readonly=True)
    expires_at = fields.Datetime(required=True, readonly=True)
    used_at = fields.Datetime(readonly=True)

    _token_hash_uniq = models.Constraint("UNIQUE(token_hash)", "A ticket is unique.")

    @api.model
    def _mint(self, user, kind, evaluator=None, next_path=None, return_url=None, now=None):
        """A fresh ticket: `(raw ticket, record)`. Only the hash is stored."""
        now = now or fields.Datetime.now()
        ttl = int(self.env["ir.config_parameter"].sudo().get_param("yantra_assess_bridge.ticket_ttl_seconds", TICKET_TTL))
        raw = secrets.token_urlsafe(32)
        record = self.sudo().create({
            "token_hash": digest(raw),
            "kind": kind,
            "user_id": user.id,
            "evaluator_id": evaluator.id if evaluator else False,
            "next_path": next_path or False,
            "return_url": return_url or False,
            "expires_at": now + timedelta(seconds=max(10, ttl)),
        })
        return raw, record

    @api.model
    def _redeem(self, raw, now=None):
        """Spend a ticket once: a v2 bearer for its person, and where to send them."""
        now = now or fields.Datetime.now()
        if not raw:
            raise TicketRefused("invalid_ticket", _("A ticket is required."))
        self.env.cr.execute(
            "SELECT id FROM yantra_assess_ticket WHERE token_hash = %s FOR UPDATE", (digest(raw),)
        )
        row = self.env.cr.fetchone()
        if not row:
            raise TicketRefused("invalid_ticket", _("This link is not valid. Start again from Yantra."))
        ticket = self.sudo().browse(row[0])
        if ticket.used_at:
            raise TicketRefused("ticket_used", _("This link was already used. Start again from Yantra."))
        if ticket.expires_at < now:
            raise TicketRefused("ticket_expired", _("This link expired. Start again from Yantra."))
        user = ticket.user_id
        if not user.active:
            raise TicketRefused("account_inactive", _("This account is not active."))
        ticket.write({"used_at": now})
        expiry = now + TOKEN_MAX
        evaluator = ticket.evaluator_id
        if evaluator and evaluator.deadline_datetime:
            expiry = min(expiry, max(now, evaluator.deadline_datetime) + AFTER_DEADLINE)
        bearer = secrets.token_urlsafe(32)
        self.env["api.access_token"].sudo().create({"user_id": user.id, "access_token": bearer, "expiry": expiry})
        return {
            "access_token": bearer,
            "refresh_token": "",
            "expires_at": fields.Datetime.to_string(expiry),
            "exam_token": evaluator.access_token if evaluator else None,
            "next": ticket.next_path or None,
            "return_url": ticket.return_url or None,
        }

    @api.autovacuum
    def _gc_spent(self):
        """Tickets a day past their life go; nothing reads them after redeem."""
        cutoff = fields.Datetime.now() - timedelta(days=1)
        self.sudo().search([("expires_at", "<", cutoff)]).unlink()
