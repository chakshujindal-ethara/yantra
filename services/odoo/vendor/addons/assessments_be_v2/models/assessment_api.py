"""Assessment behaviour the JSON API needs, added by inheritance.

Nothing here declares a field or a table. `assessments_be_v2` keeps ownership
of the model; this file changes only the two decisions that differ when the
client is the Flutter app rather than the Odoo portal.
"""

import logging

from psycopg2.errors import SerializationFailure, TransactionRollbackError

from odoo import api, fields, models
from odoo.exceptions import UserError

from .ir_http import _truthy

_logger = logging.getLogger(__name__)

# The password a candidate account is provisioned with. See
# `_seed_candidate_password` for when it is applied - it is a SEED, never a
# reset, so it can only ever reach an account that has no password at all.
DEFAULT_CANDIDATE_PASSWORD = "Ethara@123"

# Override it per deployment without a code change:
#
#     assessments_be_v2.default_candidate_password = <something else>
#
# CLEARING THIS DOES NOT DISABLE SEEDING - use the switch below. Odoo's
# `get_param` is `self._get_param(key) or default`, so a stored empty string is
# indistinguishable from an absent key and falls back to the default either way.
CANDIDATE_PASSWORD_PARAM = "assessments_be_v2.default_candidate_password"

# Turn seeding off and go back to the signup-email-only flow:
#
#     assessments_be_v2.seed_candidate_password = 0
#
# Defaults to ON when unset. Parsed with `_truthy` because Odoo stores every
# parameter as TEXT, and "0" and "False" are both truthy Python strings.
CANDIDATE_PASSWORD_ENABLED_PARAM = "assessments_be_v2.seed_candidate_password"


class EtpAssessmentProEvaluator(models.Model):
    # THE ATTEMPT, not the assessment. `access_token` and `candidate_link` are
    # fields of `assessments.be.evaluator` - one per candidate sitting -
    # and this override used to be declared on `assessments.be`, which has
    # neither. Odoo does not complain: no field on that model names
    # `_compute_candidate_link` as its compute, so the method was simply never
    # called, the evaluator kept upstream's hardcoded portal URL, and
    # `candidate_app_base_url` - the one setting this addon exists to honour -
    # was read by nothing. Every candidate was emailed the Odoo portal.
    _inherit = "assessments.be.evaluator"

    def _candidate_link_for(self, token):
        """The URL a candidate is sent, for one access token.

        Always the Flutter client's `/exam/<token>`, because that is now the only
        exam runner: the QWeb portal this used to fall back to has been retired.

        THE ORIGIN COMES FROM `app_origins.client_app_origin`: the configured
        parameter, then the pairing table, then a developer's local client, then
        `web.base.url` itself. Four steps, written out once in that file and
        deliberately NOT repeated here - this method and `_reset_base_url` in
        `controllers/api/auth.py` each kept their own copy, the copies drifted
        apart, and the reset link is the one that ended up dead.

        DERIVING AT ALL IS THE RETIREMENT'S DOING. `app_origins` used to refuse
        to infer the origin because this link is EMAILED and cannot be recalled,
        and `/pro_assessment/<token>` answered 200 on the live hosts, so
        inferring would have silently redirected every invitation on a
        deployment that had never set the parameter. That reasoning was
        conditioned entirely on the QWeb route working; it no longer exists, so
        an unset parameter would otherwise mint links into a redirect that has
        to bounce them out again. See `app_base_url` for the longer version.

        NOTHING BREAKS FOR A LINK ALREADY SENT: `controllers/legacy_redirects.py`
        still answers all nine retired paths and sends them here.
        """
        if not token:
            return False
        return "%s/exam/%s" % (self._candidate_app_origin(), token)

    def _candidate_app_origin(self):
        """Origin of the Flutter client - configured, paired, local, or this host.

        Shared by the deep link and the front door so the two cannot disagree
        about where the app lives, which is exactly the sort of thing that ends
        with an invitation button and its paste-URL pointing at different hosts.
        The password-reset link reaches the same resolver directly, so all three
        now answer from one chain.

        Never returns a trailing slash; may return "" only when `web.base.url` is
        itself unset, which is a database nobody has configured at all.
        """
        # THE CHAIN LIVES IN `app_origins.client_app_origin`, and it was
        # written out here. The password-reset link in `controllers/api/auth.py`
        # had its own shorter copy, the two disagreed on any database where
        # `candidate_app_base_url` was unset, and production is one - so exam
        # invitations derived the client correctly while reset emails shipped a
        # dead Odoo URL. One copy now, read by both.
        from ..services import app_origins
        return app_origins.client_app_origin(self.env)

    candidate_home_url = fields.Char(
        string="Candidate Sign-in URL", compute="_compute_candidate_home_url",
        help="Where the invitation email sends the candidate: the front door "
             "of the candidate app, which they sign into with their own "
             "credentials. Not token-scoped - see candidate_link for the "
             "direct deep link.")

    def _candidate_home(self):
        """The candidate app's front door, with no token in it.

        WHY THE EMAIL DOES NOT DEEP-LINK ANY MORE. A token URL is a bearer
        credential in an inbox: forwardable, logged by mail scanners, and it only
        ever opens ONE sitting - a candidate with three assessments needed three
        emails and could not get back to the second after archiving the first.

        The token is untouched: `candidate_link` still deep-links, and the app
        still resolves `/exam/<token>` for anybody holding an older mail.

        THE ORIGIN, NOT A PATH. It used to fall back to
        `<web.base.url>/my/pro_assessments` - the QWeb list page, now retired -
        which would leave an unset deployment emailing a link into a redirect.
        `_candidate_app_origin` resolves the app instead, and the app routes a
        signed-in candidate to their own list from its root.
        """
        return self._candidate_app_origin()

    def _compute_candidate_home_url(self):
        home = self._candidate_home()
        for rec in self:
            rec.candidate_home_url = home

    # `_compute_candidate_link` USED TO BE OVERRIDDEN HERE, because the base
    # class built `/pro_assessment/<token>` inline and offered no hook. The base
    # now delegates to `_candidate_link_for` (this file's method), so an override
    # that did exactly the same thing was a second copy of nothing. Removed.


class EtpAssessmentPro(models.Model):
    _inherit = "assessments.be"

    def _ensure_candidate_user(self, applicant):
        """Tag a newly provisioned candidate account with the `Candidate`
        api.role.

        "PORTAL USER" IS WHAT THIS SAID, and it has not been true for some time:
        `_ensure_candidate_user` provisions candidates as INTERNAL accounts, and
        a portal account is now refused outright rather than bound - this
        platform is internal-users-only.

        WHY: the auth gateway reports `user_role: ""` for a user with no
        api.role, and the client reads a blank as its default role - `admin`. A
        candidate provisioned without one would sign in to the ADMIN sidebar.

        Wrapped, not reimplemented: upstream returns a status string callers act
        on ("exists", "skipped", ...), so the result passes through untouched.
        """
        result = super()._ensure_candidate_user(applicant)
        user = applicant.be_candidate_user_id if applicant else None
        if user:
            # THE TEST IS "DID WE JUST MAKE THIS ACCOUNT", not "is it internal" -
            # see `_seed_candidate_password` for why the `_is_internal()` version
            # stopped working. An account this module created a second ago is
            # ours to finish setting up; one that already existed is not.
            fresh = result == "created"
            if fresh:
                self._tag_candidate_role(user)
            self._seed_candidate_password(user, created=fresh)
        return result

    def _default_candidate_password(self):
        """The password a freshly provisioned candidate account gets.

        Empty when this deployment has switched seeding off, which is the
        caller's signal to do nothing at all.

        Read per call rather than cached: an operator changing it in Settings
        must apply to the next launch, not the next restart.
        """
        params = self.env["ir.config_parameter"].sudo()
        # Unset means ON, so a database that has never heard of the switch still
        # provisions usable accounts.
        raw_flag = params.get_param(CANDIDATE_PASSWORD_ENABLED_PARAM)
        if raw_flag not in (False, None, "") and not _truthy(raw_flag):
            return ""
        raw = params.get_param(
            CANDIDATE_PASSWORD_PARAM, DEFAULT_CANDIDATE_PASSWORD)
        return (raw or "").strip()

    def _candidate_has_password(self, user):
        """True when this account already has a password of its own.

        Read over SQL because it cannot be read any other way: `password` is a
        NON-STORED computed field whose compute is
        ``user.password = ''`` (base/models/res_users.py), so the ORM answers
        the empty string for everybody - an account with a password and one
        without are indistinguishable through `user.password`. The hash lives
        in the `res_users.password` COLUMN, which upstream's own
        `_set_encrypted_password` writes with raw SQL for the same reason.
        """
        self.env.cr.execute(
            "SELECT password FROM res_users WHERE id = %s", (user.id,))
        row = self.env.cr.fetchone()
        return bool(row and (row[0] or "").strip())

    def _seed_candidate_password(self, user, created=False):
        """Give a candidate account a known password so it can be signed into.

        WHY THIS EXISTS. Upstream provisions candidates with
        ``Users.create({...})`` and no `password` key at all
        (assessments_be_v2/models/assessment.py), so the column is NULL and
        the account cannot authenticate by password by any route. The only way
        in was the signup link mailed by `_deliver_invitation`, which means a
        candidate whose invitation bounced, expired in a spam folder, or was
        never configured to send (no outgoing mail server on a fresh install)
        had no way to reach their own exam. This closes that hole: the account
        is usable the moment it is assigned to a launched assessment.

        A SEED, NEVER A RESET - the three guards below are the whole safety
        argument, because this runs on every `_ensure_candidate_user`, which
        includes launching an assessment for candidates who already have
        accounts:

          * `created` - only an account this module made a moment ago is
            touched. This used to test `_is_internal()`, which protected staff
            by protecting a TYPE; candidate accounts are internal now, so the
            type no longer tells a person being onboarded apart from a
            colleague sitting an exam. Ownership does, and it protects more:
            an account somebody else set up is left alone whatever its type.
          * `login_date` - an account that has ever been signed into keeps
            whatever its owner chose.
          * `_candidate_has_password` - an account that already has a password
            keeps it. This is what makes the whole thing idempotent, and it is
            what stops a candidate who changed their password from being
            silently put back on the shared default at the next launch.

        Only an account that no one has ever been able to sign into can be
        reached, so nothing that currently works can be downgraded.

        Best-effort. A launch that provisions thirty candidates must not fail
        because one password write was refused - the signup email is still sent
        either way, so the failure mode is the behaviour that existed before
        this method.
        """
        if not user:
            return
        user = user.sudo()
        password = self._default_candidate_password()
        if not password:
            return                      # seeding disabled for this deployment
        if not created or not user.active:
            return
        if user.login_date or self._candidate_has_password(user):
            return
        try:
            # Savepoint, so a refused write (a password policy, say) rolls back
            # only itself. Without one, the failed statement poisons the whole
            # transaction and takes the entire launch down with it - the exact
            # shape of a bug this addon has already been bitten by.
            with self.env.cr.savepoint():
                user.write({"password": password})
        except (SerializationFailure, TransactionRollbackError):
            # Retryable, and no savepoint can rescue it. Let it reach
            # `service.model.retrying`, which replays the whole request.
            raise
        except Exception:                                       # noqa: BLE001
            _logger.warning(
                "Could not seed the default password for candidate user %s; "
                "they will have to use the signup link in their invitation "
                "email instead", user.id, exc_info=True)
        else:
            _logger.info(
                "Seeded the default candidate password for user %s (%s)",
                user.id, user.login)

    def _tag_candidate_role(self, user):
        """Give a role to a user who has none. Best-effort; never fatal.

        ONLY WHEN EMPTY. This runs on every `_ensure_candidate_user`, including
        for a user upstream reports as already existing, so the earlier
        `!= role.id` test demoted people: anyone later promoted to Admin, HR or
        TA who is also linked to an applicant was silently reset to Candidate the
        next time anything touched that applicant.

        `api.role` is the gateway's model. The addon now depends on it, so the
        guard below is for a partially-loaded registry, not a missing module.
        """
        Role = self.env.get("api.role")
        if Role is None or not user or user.sudo().user_role:
            return
        try:
            role = Role.sudo().search([("name", "=ilike", "Candidate")],
                                      order="id", limit=1)
            if role:
                user.sudo().write({"user_role": role.id})
        except Exception:                                       # noqa: BLE001
            _logger.warning("Could not tag candidate user %s with an api.role",
                            user.id, exc_info=True)
