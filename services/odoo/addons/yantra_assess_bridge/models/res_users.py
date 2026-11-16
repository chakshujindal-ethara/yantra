"""A Yantra person in Assessment v2: an internal user bound to their Keycloak subject.

Assessment v2 takes candidates only as internal users bound to an `hr.applicant`; Yantra knows people by their
Keycloak subject. The subject is the key here: the first call binds or creates the user, every later call finds them
by subject, so a changed email follows the person instead of creating a second account. An existing account is
bound by email only when Keycloak has VERIFIED that email (otherwise anyone could claim another person's account by
typing their address), and never a portal account (v2 refuses those) or one already bound to another subject.

Nobody gets a password: the bridge's launch tickets are the only way in.
"""

import re

from odoo import _, api, fields, models
from odoo.exceptions import UserError

SUB = re.compile(r"^[0-9a-fA-F-]{8,64}$")
STAFF_KINDS = ("staff",)


class IdentityConflict(UserError):
    """The person cannot be bound as asked; `code` is the API's error code."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


class ResUsers(models.Model):
    _inherit = "res.users"

    yantra_keycloak_sub = fields.Char(
        string="Yantra (Keycloak) subject",
        index=True,
        copy=False,
        readonly=True,
        help="The Keycloak subject of the Yantra person this account belongs to. Set by the Yantra assessment "
        "bridge; the key it finds the person by.",
    )

    _yantra_keycloak_sub_uniq = models.Constraint(
        "UNIQUE(yantra_keycloak_sub)",
        "A Yantra person maps to one account.",
    )

    @api.model
    def _yantra_login_for(self, sub, email, verified):
        """The login: the email Keycloak verified, or a stable address no mail can reach."""
        email = (email or "").strip().lower()
        return email if (email and verified) else f"{sub.lower()}@users.yantra.invalid"

    @api.model
    def _yantra_ensure_person(self, sub, email="", verified=False, name="", kind="worker"):
        """The internal user and applicant for a Yantra person, made or bound as needed: `(user, applicant)`."""
        if not sub or not SUB.match(sub):
            raise IdentityConflict("invalid_subject", _("A Keycloak subject is required."))
        Users = self.sudo().with_context(active_test=False, no_reset_password=True)
        login = self._yantra_login_for(sub, email, verified)
        name = (name or "").strip() or login.split("@")[0]
        user = Users.search([("yantra_keycloak_sub", "=", sub)], limit=1)
        if not user and verified and email:
            existing = Users.search([("login", "=", login)], limit=1)
            if existing:
                if existing.share:
                    raise IdentityConflict(
                        "portal_account",
                        _("%s belongs to a portal account; Assessment v2 takes internal users only.", login),
                    )
                if existing.yantra_keycloak_sub and existing.yantra_keycloak_sub != sub:
                    raise IdentityConflict("identity_conflict", _("%s is bound to another Yantra person.", login))
                existing.write({"yantra_keycloak_sub": sub})
                user = existing
        if not user:
            user = Users.create({
                "name": name,
                "login": login,
                "email": login,
                "yantra_keycloak_sub": sub,
            })
        else:
            self._yantra_follow_changes(user, login, name)
        self._yantra_grant(user, kind)
        if not user.active:
            user.active = True
        applicant, _created = self.env["hr.applicant"].sudo()._be_ensure_applicant_for_user(user)
        return user, applicant

    @api.model
    def _yantra_follow_changes(self, user, login, name):
        """A verified email change in Keycloak moves the login; never onto someone else's."""
        values = {}
        if user.login != login and not login.endswith("@users.yantra.invalid"):
            taken = self.sudo().with_context(active_test=False).search(
                [("login", "=", login), ("id", "!=", user.id)], limit=1
            )
            if taken:
                raise IdentityConflict("identity_conflict", _("%s is used by another account.", login))
            values.update(login=login, email=login)
        if name and user.name != name:
            values["name"] = name
        if values:
            user.sudo().write(values)

    @api.model
    def _yantra_grant(self, user, kind):
        """Workers sit papers (Candidate); staff run them (v2's Admin, which implies Candidate)."""
        group = self.env.ref(
            "assessments_be_v2.group_assessment_manager"
            if kind in STAFF_KINDS
            else "assessments_be_v2.group_assessment_candidate"
        )
        if group not in user.group_ids:
            user.sudo().write({"group_ids": [(4, group.id)]})
