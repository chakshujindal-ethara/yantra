from markupsafe import Markup, escape

from odoo import api, fields, models
from odoo.tools import email_normalize


def _norm_email(value):
    """The address inside ``value``, case-folded, or ''.

    `strict=False` deliberately. It is what `mail.thread.blacklist` uses to
    compute the stored `email_normalized` column this module searches on
    (mail/models/mail_thread_blacklist.py:47-50), and `hr.applicant.email_from`
    is free text that can legitimately carry a display name -
    `"Asha Rao" <asha@corp.com>`. Reading it strictly here would refuse a row
    the indexed search had just proposed, and the candidate would get an empty
    list with nothing anywhere saying why.
    """
    return email_normalize(value or "", strict=False) or ""


#: Longest name a typed-in or imported candidate may carry. A person's name,
#: not a paragraph: the same bound the form designer's media name uses.
MAX_CANDIDATE_NAME = 200


def candidate_row_error(name, email):
    """Why a (name, email) candidate row cannot be accepted, or None.

    ONE CHECK for every entry point that turns a typed-in row into an
    applicant - `/assign` and the candidate CSV import (Odoo button and API).
    The address becomes the portal login at launch (`_ensure_candidate_user`),
    and `_norm_email(email) or email` stored a non-address raw, so the login
    was one nobody could sign in to. STRICT, unlike `_norm_email`: the whole
    input must BE one plain address whose domain ends in a letters-only
    label of 2+ ("example.com3450" is not one). `email_normalize` alone
    extracts an address from messy text - "john smith@corp.com" gave
    smith@corp.com, somebody else's address - so its result has to equal what
    was typed. Both values arrive stripped and non-empty; each caller keeps
    its own handling of a missing one.
    """
    address = email_normalize(email) or ""
    domain = address.rpartition("@")[2]
    tld = domain.rpartition(".")[2] if "." in domain else ""
    if (address.lower() != email.lower()
            or len(tld) < 2 or not tld.isalpha()):
        return "%r is not an email address" % email[:100]
    if len(name) > MAX_CANDIDATE_NAME:
        return "the name is longer than %d characters" % MAX_CANDIDATE_NAME
    return None


class HrApplicant(models.Model):
    _inherit = "hr.applicant"

    be_candidate_user_id = fields.Many2one(
        "res.users",
        string="Candidate Portal User (v2)",
        ondelete="set null",
        index=True,
        copy=False,
    )

    be_evaluator_ids = fields.One2many(
        "assessments.be.evaluator",
        "applicant_id",
        string="ETP Assessments (v2)",
    )

    be_assessment_count = fields.Integer(
        string="Assessments (v2)", compute="_compute_be_stats")
    be_submitted_count = fields.Integer(
        string="Submitted (v2)", compute="_compute_be_stats")
    be_pass_count = fields.Integer(
        string="Passed (v2)", compute="_compute_be_stats")
    be_fail_count = fields.Integer(
        string="Failed (v2)", compute="_compute_be_stats")
    be_pending_count = fields.Integer(
        string="Awaiting Result (v2)", compute="_compute_be_stats")
    be_avg_score = fields.Float(
        string="Average Score (v2)", compute="_compute_be_stats")
    be_pass_rate = fields.Float(
        string="Pass Rate (v2)", compute="_compute_be_stats")
    be_best_score = fields.Float(
        string="Best Score (v2)", compute="_compute_be_stats")

    # sanitize=False so inline numeric styles (width:NN%, conic-gradient
    # degrees) survive; safe because markup is admin-only, readonly, built
    # from numbers only, with every dynamic string escaped via markupsafe.
    be_scores_chart_html = fields.Html(
        string="Scores by Assessment (v2)", sanitize=False, readonly=True,
        compute="_compute_be_scores_chart_html")
    etp_result_donut_html = fields.Html(
        string="Result Breakdown", sanitize=False, readonly=True,
        compute="_compute_etp_result_donut_html")

    # Identity resolution
    #
    # ONE pair of methods, walked in both directions, because there used to be
    # four hand-copied versions of this walk and they did not agree. The gate
    # (`assessments.be.evaluator._candidate_user`) refused internal users on
    # the email step; the candidate's own list (`resolve_applicant`) allowed
    # them by design. An employee sitting an assessment therefore saw it on
    # "My assessments", pressed Start, and was told the link belonged to
    # somebody else - the server naming their own address on both sides of the
    # comparison. Any change here must keep the two directions symmetric: if
    # the list offers an attempt, the gate has to let that person in.

    def _be_same_person(self, user):
        """True when ``user`` is the account holding this applicant's address.

        The identity test both directions share. `res.users.login` is the one
        user attribute the database makes unique
        (base/models/res_users.py `_login_key`); `res.partner.email` is not,
        and `_inverse_partner_email` picks a partner through
        `_partner_find_from_emails_single`, whose sort key prefers the writer's
        OWN partner and internal partners (mail/models/mail_thread.py:2062-2073)
        - so one duplicated address on an admin's contact was enough to make an
        applicant's `partner_id` name the admin. Comparing normalised logins is
        the one test duplicate contacts cannot steer.
        """
        self.ensure_one()
        if not user:
            return False
        email = _norm_email(self.email_from)
        return bool(email) and _norm_email(user.login) == email

    def _be_search_email(self):
        """The normalised address to match a login against, or ''."""
        self.ensure_one()
        return _norm_email(self.email_from)

    def _be_candidate_user(self):
        """Applicant -> the ``res.users`` allowed to sit its assessments.

        TWO WAYS IN: the explicit bind, then the account whose login IS this
        applicant's address.

        NO PARTNER STEP. There used to be one, and it is what handed one
        person's exam to another: it accepted any user sharing
        `applicant.partner_id` without checking they were the same person. Once
        the address has to match, a partner match can only ever return a user
        the login step returns anyway, so the step is not merely unsafe, it is
        redundant - and two steps that cannot disagree are how the old
        "Security (M-1)" rule outlived its own reasoning.

        INTERNAL USERS ARE CANDIDATES. An employee sitting an assessment is
        the ordinary case here, and excluding them is what made this disagree
        with the candidate's own list.
        """
        self.ensure_one()
        if self.be_candidate_user_id:
            return self.be_candidate_user_id
        Users = self.env["res.users"].sudo()
        # The NORMALISED address, not the raw field: `email_from` is free text
        # and may carry a display name - `"Asha Rao" <asha@corp.com>` - which
        # matches no login at all.
        email = _norm_email(self.email_from)
        if email:
            # `=ilike` compiles to SQL ILIKE with the value used verbatim, and
            # `%` and `_` are both legal in a local-part - `_` is common. So
            # this search is a PATTERN, not an equality: `a_b@corp.com` also
            # matches the account `axb@corp.com`. The same bug was found and
            # fixed once already in this codebase, in the assign route
            # (controllers/api/admin.py, "=ilike compiles to SQL ILIKE with no
            # escaping"). The search only NARROWS; `_be_same_person` decides,
            # and a handful of rows are read rather than one so a wildcard
            # collision cannot crowd out the real account.
            for match in Users.with_context(active_test=False).search(
                    [("login", "=ilike", email)], limit=10):
                if self._be_same_person(match):
                    return match
        return Users.browse()

    @api.model
    def _be_ensure_applicant_for_user(self, user):
        """The applicant for a directory user, made if they have none.

        The Assign-candidates picker offers `res.users`, but the roster is
        keyed on `hr.applicant` - `assessments.be.evaluator.applicant_id` is
        required and `ondelete="restrict"` - so somebody picked has to be
        mapped to an applicant before they can be assigned.

        Matched the same way the exam gate resolves identity, in the same
        order: the explicit bind, then the normalised address. Never an
        `=ilike` pattern - `_` is legal in a local-part, so `a_b@corp.com`
        would also match the account `axb@corp.com` and the roster would name
        the wrong person.

        Returns ``(applicant, created)``.
        """
        applicant = self._be_find_applicant_for_user(user)
        if applicant:
            # An archived applicant being assigned again is somebody coming
            # back, not a new person: reuse the record so their history stays
            # attached to one identity.
            if not applicant.active:
                applicant.active = True
            if not applicant.partner_name:
                applicant.partner_name = user.name or user.login
            if not applicant.be_candidate_user_id:
                applicant.be_candidate_user_id = user.id
            return applicant, False
        applicant = self.sudo().create({
            "partner_name": user.name or user.login,
            "email_from": user.login,
        })
        # Bound explicitly rather than left to the address fallback, so the
        # gate and the record rules key on a real link from the first moment.
        applicant.be_candidate_user_id = user.id
        return applicant, True

    @api.model
    def _be_find_applicant_for_user(self, user):
        """The applicant a directory user maps to, or an empty recordset.

        Read-only, so the assign route's dry run can tell "already on the
        roster" from "would be added" without making anybody.
        """
        Applicant = self.sudo().with_context(active_test=False)
        applicant = Applicant.search(
            [("be_candidate_user_id", "=", user.id)], limit=1)
        if not applicant:
            normalized = _norm_email(user.login)
            if normalized:
                applicant = Applicant.search(
                    [("email_normalized", "=", normalized)], limit=1)
        return applicant

    @api.model
    def _be_applicant_for_user(self, user=None):
        """User -> their applicant, or an empty recordset.

        PROPOSE, THEN CONFIRM. The searches below only NOMINATE applicants;
        :meth:`_be_candidate_user` is what decides. Written this way the method
        is structurally incapable of returning an attempt the exam gate would
        refuse - which is the defect that put a Start button in front of a
        candidate the gate then called somebody else. Mirroring the steps by
        hand is what drifted the first time, so the mirror is not repeated
        here; the forward walk is called instead.

        Runs sudo because candidates are portal users with no ACL on
        hr.applicant. Finding nothing is not an error: a logged-in user who is
        simply not a candidate gets an empty state, not a failure.
        """
        user = user or self.env.user
        if not user or user._is_public():
            return self.browse()
        Applicant = self.sudo()
        proposals = Applicant.search(
            [("be_candidate_user_id", "=", user.id)], limit=1)
        # `email_normalized` is the stored, indexed, case-folded column
        # mail.thread.blacklist maintains from `email_from`. Searched with `=`
        # rather than `email_from =ilike login`, which is a pattern.
        normalized = _norm_email(user.login)
        if normalized:
            proposals |= Applicant.search(
                [("email_normalized", "=", normalized)], limit=1)
        for applicant in proposals:
            if applicant._be_candidate_user() == user:
                return applicant
        return self.browse()

    @api.depends(
        "be_evaluator_ids.state",
        "be_evaluator_ids.result",
        "be_evaluator_ids.score_percent",
    )
    def _compute_be_stats(self):
        for rec in self:
            evals = rec.be_evaluator_ids
            submitted = evals.filtered(lambda e: e.state == "submitted")
            passed = evals.filtered(lambda e: e.result == "pass")
            failed = evals.filtered(lambda e: e.result == "fail")
            pending = evals.filtered(lambda e: e.result == "pending")

            rec.be_assessment_count = len(evals)
            rec.be_submitted_count = len(submitted)
            rec.be_pass_count = len(passed)
            rec.be_fail_count = len(failed)
            rec.be_pending_count = len(pending)

            # DECIDED attempts only: a pending result (still with the grader)
            # holds 0.0 that nobody awarded, so it is neither a score nor a fail.
            decided = passed | failed
            sub_scores = decided.mapped("score_percent")
            rec.be_avg_score = round(
                sum(sub_scores) / len(sub_scores), 1) if sub_scores else 0.0
            rec.be_pass_rate = round(
                len(passed) / len(decided) * 100.0, 1) if decided else 0.0
            all_scores = evals.mapped("score_percent")
            rec.be_best_score = round(max(all_scores), 1) if all_scores else 0.0

    @api.depends(
        "be_evaluator_ids.score_percent",
        "be_evaluator_ids.result",
        "be_evaluator_ids.submitted_at",
    )
    def _compute_be_scores_chart_html(self):
        labels = {"pass": "Pass", "fail": "Fail", "pending": "Pending"}
        for rec in self:
            evals = list(rec.be_evaluator_ids)
            evals.sort(
                key=lambda e: (
                    e.submitted_at or fields.Datetime.to_datetime("1900-01-01"),
                    e.score_percent or 0.0,
                ),
                reverse=True,
            )
            if not evals:
                rec.be_scores_chart_html = Markup(
                    '<div class="etp-chart-empty">No assessments yet</div>')
                continue

            rows = Markup("")
            for ev in evals:
                pct = max(0.0, min(100.0, ev.score_percent or 0.0))
                result = ev.result if ev.result in labels else "pending"
                rows += Markup(
                    '<a class="etp-cbar-row" '
                    'href="/web#id={eid}&amp;model=assessments.be.evaluator'
                    '&amp;view_type=form">'
                    '<span class="etp-cbar-name">{name}</span>'
                    '<span class="etp-cbar-track">'
                    '<span class="etp-cbar-fill" style="width:{pct}%"></span>'
                    "</span>"
                    '<span class="etp-cbar-val">{val}% '
                    '<span class="etp-feed-pill etp-feed-pill-{cls}">{label}</span>'
                    "</span>"
                    "</a>"
                ).format(
                    eid=ev.id,
                    name=escape(
                        ev.assessment_id.display_name or "Untitled"),
                    pct=round(pct, 1),
                    val=round(pct, 1),
                    cls=result,
                    label=labels[result],
                )
            rec.be_scores_chart_html = Markup(
                '<div class="etp-cbar-wrap etp-cand-scores">{}</div>').format(rows)

    @api.depends(
        "be_evaluator_ids.result",
        "be_evaluator_ids.state",
    )
    def _compute_etp_result_donut_html(self):
        for rec in self:
            evals = rec.be_evaluator_ids
            pass_count = len(evals.filtered(lambda e: e.result == "pass"))
            fail_count = len(evals.filtered(lambda e: e.result == "fail"))
            pending_count = len(evals.filtered(lambda e: e.result == "pending"))
            total = pass_count + fail_count + pending_count

            legend = Markup(
                '<ul class="etp-donut-legend">'
                '<li><span class="etp-dot etp-dot-pass"></span>Pass<b>{p}</b></li>'
                '<li><span class="etp-dot etp-dot-fail"></span>Fail<b>{f}</b></li>'
                '<li><span class="etp-dot etp-dot-pending"></span>Pending<b>{n}</b></li>'
                "</ul>"
            ).format(p=pass_count, f=fail_count, n=pending_count)

            if not total:
                ring = Markup(
                    '<div class="etp-donut" style="background:var(--etp-muted)">'
                    '<div class="etp-donut-hole"></div></div>'
                )
                rec.etp_result_donut_html = Markup(
                    '<div class="etp-donut-wrap">{}{}</div>').format(ring, legend)
                continue

            pass_deg = round(pass_count / total * 360.0, 2)
            pass_fail_deg = round((pass_count + fail_count) / total * 360.0, 2)
            ring = Markup(
                '<div class="etp-donut" style="background:conic-gradient('
                "var(--etp-pass) 0 {a}deg,"
                "var(--etp-fail) {a}deg {b}deg,"
                "var(--etp-muted) {b}deg 360deg)\">"
                '<div class="etp-donut-hole"></div></div>'
            ).format(a=pass_deg, b=pass_fail_deg)
            rec.etp_result_donut_html = Markup(
                '<div class="etp-donut-wrap">{}{}</div>').format(ring, legend)
