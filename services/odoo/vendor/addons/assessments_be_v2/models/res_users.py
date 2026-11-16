# -*- coding: utf-8 -*-
"""Which rung of this addon's access ladder an account stands on.

ONE FUNCTION, ONE ANSWER. Every gate in the addon used to decide for itself what
"may use the assessment platform" meant, out of `_is_public()` and
`_is_internal()` and a `has_group` call, and the four copies did not agree:

  * `controllers/admin_media.py` (x4) refused anything not internal - correct.
  * `controllers/exam_media.py._refused` ADMITTED every internal user and only
    then compared identities. Candidate accounts are internal, so the identity
    comparison became unreachable and candidate A holding candidate B's token
    could fetch B's exam media. The docstring still claimed "a caller who IS
    signed in as somebody else is still refused"; it could not be.
  * `controllers/api/common.may_view_attempt` asked `has_group(GROUP_MANAGER)`,
    which is a narrower question than "is this staff" and a different one again.

A ROLE, NOT A BOOLEAN, because the gates need three outcomes and a boolean
forces each caller to re-derive the third. `staff` and `candidate` are both
internal accounts and must be told apart - that distinction IS the exam_media
bug - and `none` has to be reachable so a portal account is refused explicitly
rather than by falling off the end of an if-chain.

WHY ON `res.users` AND NOT IN `controllers/api/common.py`. A model needs it:
`assessments.be._ensure_candidate_user` has to refuse binding a portal account
before it writes anything, and a model importing from a controller is backwards.
The group xmlids moved to `constants.py` for the same reason.
"""
import contextlib
import datetime
import logging

from odoo import api, models
from odoo.exceptions import AccessDenied
from odoo.http import request

from ..constants import (
    GROUP_CANDIDATE, GROUP_MANAGER_RESTRICTED,
    ROLE_CANDIDATE, ROLE_NONE, ROLE_STAFF,
)


_logger = logging.getLogger(__name__)


class ResUsers(models.Model):
    _inherit = "res.users"

    def _be_assessment_role(self):
        """`staff`, `candidate`, or `none`. Never raises, never guesses.

        THE INVARIANT: this platform is for INTERNAL users. A portal or public
        account is `none` - it has no role here at all - and that is checked
        BEFORE any group, because a portal user cannot hold
        `group_assessment_candidate` in the first place (it implies
        `base.group_user`, and `res.users._check_disjoint_groups` forbids being
        both portal and internal). Asking about groups first would therefore be
        asking a question that cannot have a useful answer.

        `staff` is anyone from the restricted Manager rung upward. Tested at the
        LOWEST rung on purpose: `has_group` resolves through `implied_ids`, and
        Admin implies Manager, so an Admin answers `staff` without this having to
        enumerate the ladder. A rung added above Manager later is staff for free.

        `candidate` is an internal account holding the Candidate group. An
        internal account holding NONE of the three groups is `none` - that is
        what "Assessment v2 Access = No" means, and it is the hole this ladder
        was built to close: candidate ability used to ride on `base.group_user`,
        which every employee in the instance holds.

        Single-record, like `_is_internal()` itself, so a caller cannot get a
        silent answer for the wrong row.
        """
        self.ensure_one()
        # `_is_internal()` covers public too: the public user is not internal.
        # Testing it this way rather than `_is_public() or not _is_internal()`
        # keeps one question instead of two that can disagree.
        if not self._is_internal():
            return ROLE_NONE
        if self.has_group(GROUP_MANAGER_RESTRICTED):
            return ROLE_STAFF
        if self.has_group(GROUP_CANDIDATE):
            return ROLE_CANDIDATE
        return ROLE_NONE

    def _be_is_staff(self):
        """Shorthand for the commonest test. Reads better at a gate."""
        return self._be_assessment_role() == ROLE_STAFF

    # ── the login chokepoint ──────────────────────────────────────────────

    @api.model_create_multi
    def create(self, vals_list):
        """Fold an email-shaped login to lower case, whoever is writing it.

        ODOO'S OWN LOGIN LOOKUP IS CASE-SENSITIVE (`res_users.py`), so a login
        stored as `Asha.Rao@corp.com` cannot be signed into by typing
        `asha.rao@corp.com` - and nothing about the account looks wrong. The
        candidate is told their password is incorrect, forever.

        WHY HERE AND NOT AT THE WRITER. `etp_assessment_pro` creates candidate
        accounts with `"login": applicant.email_from.strip()` - raw - and it is
        installed on production and under a standing do-not-edit rule. This
        addon's own `_ensure_candidate_user` already folds, so fixing only our
        path would leave the live defect untouched. `create` is the one place
        every writer passes through: this addon, pro, the auth gateway, a
        manual create in Settings. Inheritance stacks regardless of module load
        order, so this does not depend on which addon loads first - which
        matters, because v2 deliberately does not depend on pro.

        SCOPED TO `@`-SHAPED LOGINS. A system account named `__system__` or a
        service login is not an address and is left exactly as typed. Every
        address, though, is folded - not only candidates - because a
        mixed-case login is unreachable whoever made it, and a rule that
        applied to some accounts and not others would be a second thing to
        remember at the next call site.

        NOT A WRITE OVERRIDE TOO. Renaming a login after the fact is rare,
        deliberate, and done by an administrator who can see what they typed;
        guarding it would mean silently rewriting an edit someone made on
        purpose. The defect being closed is account CREATION.
        """
        for vals in vals_list:
            login = (vals.get("login") or "").strip()
            if "@" in login:
                vals["login"] = login.casefold()
        return super().create(vals_list)

    # ── brute-force protection that a shared ingress IP cannot break ──────

    #: Hard ceiling on the in-memory failure bucket.
    #:
    #: KEYING ON THE LOGIN MADE THIS UNBOUNDED, and that is a scalability
    #: regression Odoo's own version does not have: its bucket is keyed on the
    #: remote address, so it is bounded by the number of clients. Ours gains an
    #: entry per DISTINCT LOGIN ATTEMPTED, and a spray script trying random
    #: addresses would grow the dict until the worker ran out of memory - a
    #: cheaper denial of service than the password guessing it was added to
    #: stop.
    #:
    #: When the ceiling is hit the oldest half is evicted. Evicting rather than
    #: refusing keeps the limiter's failure mode SAFE: the worst case is that a
    #: long-idle attacker's counter is forgotten, never that a real candidate is
    #: locked out or that sign-in stops working.
    _BE_MAX_TRACKED_FAILURES = 4096

    #: How many times the per-IP ceiling is looser than the per-login one.
    #: The login bucket is the real protection; the IP bucket only exists to
    #: catch one host spraying MANY different accounts, which the login bucket
    #: cannot see. 20x means a cohort of 650 behind two ingress IPs never
    #: reaches it, while a spray script does.
    _BE_IP_CEILING_MULTIPLIER = 20

    @staticmethod
    def _be_login_failure_keys(login=None, source=None):
        """The two bucket keys one attempt touches: its login, and its address.

        SPELLED IN ONE PLACE because two modules read this bucket - the limiter
        below and `api_auth_gateway`'s refusal classifier - and a key built even
        slightly differently on either side is a lookup that silently never
        matches.
        """
        return (("login", (login or "").strip().casefold() or "?"),
                ("ip", source or "?"))

    def _be_login_cooldown_key(self, login=None, source=None):
        """Which bucket is refusing this attempt right now, or None.

        THE ONE PLACE THE POLICY LIVES. `_assert_can_auth` gates on this and
        `api_auth_gateway.auth_token` classifies its refusal with it, so the
        two cannot drift - and they had. The route asked the shared per-IP
        bucket at Odoo's plain `base.login_cooldown_after`, while the limiter
        only refuses that bucket at `after * _BE_IP_CEILING_MULTIPLIER`. In the
        window between the two, a candidate whose password really WAS wrong was
        answered "your password is not the problem, wait a minute", every time,
        with no way left to discover the actual fault.

        POLICY IS STILL ODOO'S. The threshold is `base.login_cooldown_after`,
        the recency test is `_on_login_cooldown`, and 0 still disables - so a
        deployment that tunes those parameters, or overrides that predicate, is
        obeyed here exactly as it is in core.

        Returns the offending key rather than a bool so the caller that refuses
        can say WHICH ceiling was hit without re-deriving it.
        """
        buckets = getattr(self.env.registry, "_be_login_failures", None)
        if not buckets:
            return None
        try:
            after = int(self.env["ir.config_parameter"].sudo().get_param(
                "base.login_cooldown_after", 10))
        except (TypeError, ValueError):
            after = 10
        # `after == 0` disables the feature in Odoo; honour that for both keys.
        if after <= 0:
            return None
        login_key, ip_key = self._be_login_failure_keys(login, source)
        for key, multiplier in ((login_key, 1),
                                (ip_key, self._BE_IP_CEILING_MULTIPLIER)):
            failures, previous = buckets.get(key, (0, None))
            if (previous and failures >= after * multiplier
                    and self._on_login_cooldown(failures, previous)):
                return key
        return None

    @contextlib.contextmanager
    def _assert_can_auth(self, user=None):
        """Rate-limit by LOGIN first, by IP only at a far looser ceiling.

        WHY THIS OVERRIDE EXISTS. Odoo's own docstring for this method says the
        cooldown puts "the user (by login)" on hold. Its implementation keys the
        bucket on `request.httprequest.remote_addr` instead. On this deployment
        every candidate reaches Odoo as one of TWO ingress addresses, because
        the NLB and the Istio sidecar have already replaced the client IP - so
        the bucket is effectively global.

        Measured on 2026-09-17: five failures from any one candidate froze
        sign-in for the whole 753-candidate cohort, producing 3,668 refusals in
        seven minutes. The mitigation was to switch brute-force protection OFF
        entirely (`base.login_cooldown_after = 0`), and it has been off since -
        so today there is NO limit on password guessing at all.

        `proxy_mode` does not fix it: `odoo/http.py` pins `ProxyFix(x_for=1)`,
        so only one hop is trusted, and the real client address was destroyed
        further upstream. That is an infrastructure change with its own
        timeline. This override restores protection now, without it.

        WHAT IT DOES. The failure bucket is keyed on the LOGIN being attempted,
        which is what brute-forcing actually targets and what Odoo's docstring
        promises. One candidate fat-fingering their password can no longer lock
        out anybody else. A second, much looser bucket on the IP still catches a
        single host spraying many accounts.

        POLICY IS STILL ODOO'S. Both buckets ask `_on_login_cooldown`, so
        `base.login_cooldown_after` / `_duration` keep deciding, 0 still
        disables, and a deployment that overrides that predicate is obeyed.

        The bucket is per-worker and not thread-safe, exactly as Odoo's is; it
        is a rate limiter, not an accounting system.
        """
        if not request:
            yield
            return

        registry = self.env.registry
        buckets = getattr(registry, "_be_login_failures", None)
        if buckets is None:
            buckets = registry._be_login_failures = {}

        source = request.httprequest.remote_addr
        login_key, ip_key = self._be_login_failure_keys(user, source)

        tripped = self._be_login_cooldown_key(user, source)
        if tripped:
            _logger.warning(
                "login cooldown: too many recent failures for %s %s",
                tripped[0], tripped[1])
            raise AccessDenied(self.env._(
                "Too many login failures, please wait a bit before trying "
                "again."))

        try:
            yield
        except AccessDenied:
            now = datetime.datetime.now()
            # A ROLLING WINDOW, NOT A LIFETIME TOTAL. A counter that only ever
            # climbs would eventually refuse a candidate for typos made weeks
            # apart, and - since a success no longer clears the shared address,
            # see below - the IP bucket would accumulate all season and freeze
            # the cohort all over again. Odoo's own `_on_login_cooldown` already
            # ignores a failure older than `base.login_cooldown_duration`, so
            # starting the count over at that point simply makes the number
            # stored mean the same thing the predicate reads it as: failures in
            # the last window, not failures ever.
            try:
                window = datetime.timedelta(seconds=int(
                    self.env["ir.config_parameter"].sudo().get_param(
                        "base.login_cooldown_duration", 60)))
            except (TypeError, ValueError):
                window = datetime.timedelta(seconds=60)
            for key in (login_key, ip_key):
                failures, previous = buckets.get(key, (0, None))
                if previous and now - previous > window:
                    failures = 0
                buckets[key] = (failures + 1, now)
            # BOUND IT. See `_BE_MAX_TRACKED_FAILURES`: keyed on the login, this
            # dict would otherwise grow one entry per distinct login ever tried.
            if len(buckets) > self._BE_MAX_TRACKED_FAILURES:
                for stale, _v in sorted(
                        buckets.items(),
                        key=lambda kv: kv[1][1] or datetime.datetime.min
                )[:len(buckets) // 2]:
                    buckets.pop(stale, None)
                _logger.info(
                    "login failure bucket trimmed to %d entries", len(buckets))
            raise
        else:
            # A success clears THIS LOGIN, so a candidate who finally gets in
            # does not leave their own counter part-way to a lockout.
            #
            # IT DOES NOT CLEAR THE ADDRESS, and that asymmetry is the whole
            # point of the second bucket. The address is one shared by the
            # entire cohort, so clearing it on ANY success meant that credential
            # spraying - the one attack the login bucket cannot see, because one
            # password against ten thousand accounts never accumulates on a
            # single login - was never limited at all: the sprayer only had to
            # sign in to their own account occasionally, or simply wait for some
            # candidate to sign in, and the ceiling reset to zero. The rolling
            # window above is what ages this bucket out instead, and the 20x
            # ceiling is what keeps a real cohort well clear of it.
            buckets.pop(login_key, None)
