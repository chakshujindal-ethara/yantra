# -*- coding: utf-8 -*-
"""The nine retired QWeb exam paths, kept as redirects into the Flutter client.

THE SERVER-RENDERED EXAM RUNNER IS GONE. `controllers/portal.py` (7 routes) and
`controllers/candidate_portal.py` (2) rendered a complete second exam surface -
about 6,000 lines with its templates and stylesheet - duplicating what the
Flutter client does through `/api/v1/exam/<token>/*` and `/api/v1/me/*`. Two
implementations of one exam is not a fallback, it is a drift generator: the
violation dedupe, the auto-submit and the answer-diffing rule were each written
twice and each pair drifted apart, and the fixes are documented in those very
methods. One runner now.

WHY THE PATHS STAY REGISTERED. NOT for tidiness, and not only for old emails.

  1. THE ROUTE COLLISION. `etp_assessment_pro` - the addon this one was forked
     from, still installed on stage at 19.0.1.137.0 - declares these SAME nine
     paths. Odoo does not merge independent `http.Controller` subclasses: each
     registers its own werkzeug rule, the routing map is built over
     `sorted(installed_modules)`, and the matcher returns the FIRST rule it
     finds. `"assessments_be_v2" < "etp_assessment_pro"` alphabetically, and
     that accident is the only reason v2 answers them today.

     Simply deleting the routes would hand all nine to upstream, silently.
     A candidate's link would return HTTP 200 with upstream's page, which looks
     its token up in `etp_assessment_pro_evaluator` - where a v2 token does not
     exist, because the fork renamed every table - and render "invalid link".
     No 404, no 5xx, nothing in the log to correlate. Registering them here is
     what keeps that from happening, and it is why this file is not optional.

  2. LINKS ALREADY SENT. `mail_mail.body_html` and `mail_message.body` are
     frozen renders: every invitation sent while
     `assessments_be_v2.candidate_app_base_url` was unset carries
     `<web.base.url>/my/pro_assessments`, and `[NO EMAIL]` audit rows
     (`auto_delete: False`, so kept forever) carry
     `<base>/pro_assessment/<token>` in `failure_reason`. Neither can be
     rewritten. A 301 is how a URL is decommissioned without breaking them.

WHERE THEY GO IS NOT HARDCODED HERE. Both targets come from the two methods that
already own "where does a candidate go" - `evaluator._candidate_link_for(token)`
for a deep link and `evaluator._candidate_home()` for the front door - which are
the same methods the invitation email uses. Inventing a URL shape in this file
would be a third opinion on the question, and the one most likely to be wrong.

301 AND NOT 302, for the six sub-paths and the two list pages: they are gone for
good and a browser or crawler should stop asking. The exam entry itself is 302,
because WHERE it sends depends on a config parameter an operator may change.

NO GATE ON THESE ROUTES. A redirect discloses nothing: the token is already in
the URL the caller typed, the destination is a public origin, and every route
behind it does its own authorisation. Gating here would only mean a candidate
following an old link hits a login wall on the Odoo host before being sent to
the app that would have signed them in anyway.
"""
import logging

from odoo import http
from odoo.http import request

_logger = logging.getLogger(__name__)


class AssessmentsBeLegacyRedirects(http.Controller):
    """One tiny controller for all nine retired paths.

    `auth="public"` matches what the retired routes were: the candidate may not
    be signed in to Odoo at all, and the app is where they sign in. `website` is
    deliberately NOT set - dropping it is what lets `website` leave the addon's
    `depends`, and a redirect needs no page layout.
    """

    def _evaluator(self, token):
        if not token:
            return request.env["assessments.be.evaluator"].sudo().browse()
        return request.env["assessments.be.evaluator"].sudo().search(
            [("access_token", "=", token)], limit=1)

    def _to_app(self, url, permanent=False):
        """Send the caller to `url`, or to Odoo's own root if there is none.

        `local=False` because the destination is a DIFFERENT ORIGIN: Odoo's
        `redirect` defaults to treating the target as a path on this host and
        would turn `https://assessment.ethara.ai/exam/x` into
        `https://projects.ethara.ai/https://assessment.ethara.ai/exam/x`.

        THE EMPTY CASE IS REAL. `_candidate_link_for` returns False for a blank
        token, and `_candidate_home` returns "" when neither the app parameter
        nor `web.base.url` is set. `/web` is a landing place rather than a
        destination, but a 404 on a link somebody was emailed is worse.
        """
        if not url:
            _logger.warning(
                "assessments_be_v2: no candidate app URL could be resolved for "
                "a retired path; sending the caller to /web. Set "
                "assessments_be_v2.candidate_app_base_url.")
            return request.redirect("/web")
        return request.redirect(
            url, code=301 if permanent else 302, local=False)

    def _exam(self, token, permanent=False):
        """The app's exam entry for `token`, however the deployment spells it."""
        evaluator = self._evaluator(token)
        if evaluator:
            return self._to_app(
                evaluator._candidate_link_for(token), permanent=permanent)
        # AN UNKNOWN TOKEN STILL GOES TO THE APP, and is not answered here.
        #
        # Deciding "no such attempt" on this host would need a page to say it
        # on, and the templates are gone. The app already has that screen - it
        # renders `outcome: invalid` from `/api/v1/exam/<token>/state` - so the
        # token travels and the app says it. Answering 404 instead would tell a
        # caller which tokens exist, which this route has no reason to reveal.
        blank = request.env["assessments.be.evaluator"].sudo()
        return self._to_app(blank._candidate_link_for(token) or "",
                            permanent=permanent)

    # ── /pro_assessment/<token> and its five sub-paths ────────────────────
    #
    # The runner's own navigation - begin, submit, review, answers, finish,
    # violation - all collapse onto the exam entry. There is nothing finer to
    # aim at: the app resumes an attempt at the right question by asking
    # `/api/v1/exam/<token>/state`, so a sub-path is not information it needs.
    # `/submit`, `/finish` and `/violation` were POST-only and are accepted here
    # for GET as well, because a browser following a redirect chain from a
    # bookmarked POST arrives as a GET.

    @http.route("/pro_assessment/<string:token>", type="http", auth="public")
    def legacy_exam(self, token, **kw):
        return self._exam(token)

    @http.route([
        "/pro_assessment/<string:token>/begin",
        "/pro_assessment/<string:token>/submit",
        "/pro_assessment/<string:token>/review",
        "/pro_assessment/<string:token>/answers",
        "/pro_assessment/<string:token>/finish",
        "/pro_assessment/<string:token>/violation",
    ], type="http", auth="public", methods=["GET", "POST"], csrf=False)
    def legacy_exam_subpath(self, token, **kw):
        """CSRF OFF, deliberately, and it costs nothing.

        Three of these were `csrf=True` POST endpoints. This handler writes
        NOTHING - it reads one row to build a URL and answers a redirect - so
        there is no state for a forged request to change. Leaving CSRF on would
        mean a stale form POST from an open tab got a 400 instead of being sent
        to the app where its owner could carry on.
        """
        return self._exam(token, permanent=True)

    # ── /my/pro_assessments and /my/pro_dashboard ────────────────────────
    #
    # The candidate's list and their analytics page. Both go to the app's FRONT
    # DOOR rather than to a guessed deep path: `_candidate_home` is what the
    # invitation email's button already uses, so it is the one URL shape known
    # to work on every deployment, and the app routes a signed-in candidate to
    # their own list from there.

    @http.route(["/my/pro_assessments", "/my/pro_dashboard"],
                type="http", auth="public")
    def legacy_candidate_home(self, **kw):
        home = request.env["assessments.be.evaluator"].sudo()
        return self._to_app(home._candidate_home(), permanent=True)
