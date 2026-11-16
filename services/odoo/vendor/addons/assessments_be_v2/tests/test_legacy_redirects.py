# -*- coding: utf-8 -*-
"""The nine retired QWeb paths still answer, and they answer with the app.

WHY THESE ROUTES EXIST AT ALL, which is the thing this file is really pinning.

`etp_assessment_pro` - the addon this one was forked from, installed on stage at
19.0.1.137.0 - declares the SAME nine candidate paths. Odoo does not merge
independent `http.Controller` subclasses: both addons' rules enter the routing
map, insertion follows `sorted(installed_modules)`, and the matcher returns the
FIRST match. `"assessments_be_v2" < "etp_assessment_pro"` alphabetically, and
that accident is the only reason v2 answers them.

So deleting the retired routes rather than replacing them would have handed all
nine to upstream SILENTLY - HTTP 200, upstream's page, a v2 token looked up in
`etp_assessment_pro_evaluator` where the fork's renaming means it cannot exist,
and an "invalid link" screen with nothing in the log to correlate. Not a 404, not
a 500: a plausible page telling a candidate their exam link is broken.
`test_route_takeover` is the test that fails on that; this file pins the other
half, which is where the redirect actually sends people.

THE SECOND REASON IS FROZEN DATA. `mail_mail.body_html` and `mail_message.body`
are rendered at send time and cannot be rewritten, so every invitation posted
while `candidate_app_base_url` was unset carries `/my/pro_assessments`, and every
`[NO EMAIL]` audit row (`auto_delete: False` - kept forever) carries
`/pro_assessment/<token>` in `failure_reason`.

NOT ASSERTED HERE: that a redirect is "secure". It discloses nothing - the token
is already in the URL the caller typed, and every route behind it authorises
itself.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers import legacy_redirects


class _FakeRequest:
    """The slice of `odoo.http.request` a redirect touches.

    `redirect` records rather than builds: what matters is the URL and the code,
    and a real `werkzeug` response would have to be unpicked to read them back.
    """

    def __init__(self, env):
        self.env = env
        self.redirects = []

    def redirect(self, url, code=303, local=True):
        self.redirects.append({"url": url, "code": code, "local": local})
        return self.redirects[-1]


@tagged("-at_install", "post_install")
class TestLegacyRedirects(TransactionCase):

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()
        self.icp.set_param("web.base.url", "https://projects.ethara.ai")
        self.icp.set_param(
            "assessments_be_v2.candidate_app_base_url",
            "https://assessment.ethara.ai")
        self.controller = legacy_redirects.AssessmentsBeLegacyRedirects()

    # -- fixtures ---------------------------------------------------------

    def _attempt(self):
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:6],
        })
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "duration_minutes": 30,
        })
        return self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "access_token": str(uuid4()),
        })

    def _call(self, route_name, *args):
        """One redirect route, with `request` stubbed.

        `original_endpoint`, not the decorated attribute: `@http.route` wraps a
        `type="http"` endpoint in `route_wrapper`, which ends with
        `Response.load(result)` and would reject the recording dict below.
        """
        endpoint = getattr(
            legacy_redirects.AssessmentsBeLegacyRedirects,
            route_name).original_endpoint
        stub = _FakeRequest(self.env)
        with patch.object(legacy_redirects, "request", stub):
            endpoint(self.controller, *args)
        self.assertEqual(
            len(stub.redirects), 1,
            "a retired path must answer exactly one redirect")
        return stub.redirects[0]

    # -- the exam entry ---------------------------------------------------

    def test_the_exam_path_redirects_to_the_apps_exam_for_that_token(self):
        evaluator = self._attempt()

        answer = self._call("legacy_exam", evaluator.access_token)

        self.assertEqual(
            answer["url"],
            "https://assessment.ethara.ai/exam/%s" % evaluator.access_token)

    def test_the_destination_is_cross_origin(self):
        """`local=False` OR THE URL IS MANGLED. Odoo's `redirect` treats a target
        as a path on this host by default, which would turn
        `https://assessment.ethara.ai/exam/x` into
        `https://projects.ethara.ai/https://assessment.ethara.ai/exam/x`."""
        evaluator = self._attempt()

        answer = self._call("legacy_exam", evaluator.access_token)

        self.assertFalse(answer["local"])

    def test_every_sub_path_lands_on_the_same_exam_entry(self):
        """The runner's own navigation collapses onto one destination.

        There is nothing finer to aim at, and that is correct rather than lossy:
        the app resumes an attempt at the right question by asking
        `/api/v1/exam/<token>/state`, so a sub-path carries no information it
        needs.
        """
        evaluator = self._attempt()
        expected = ("https://assessment.ethara.ai/exam/%s"
                    % evaluator.access_token)

        # One endpoint serves all six; the route decorator lists the paths.
        answer = self._call("legacy_exam_subpath", evaluator.access_token)

        self.assertEqual(answer["url"], expected)
        self.assertEqual(
            answer["code"], 301,
            "a sub-path is gone for good - a browser should stop asking")

    def test_an_unknown_token_still_goes_to_the_app(self):
        """It must NOT be answered here.

        Saying "no such attempt" on this host would need a page to say it on, and
        the templates are gone. The app already has that screen - it renders
        `outcome: invalid` from `/api/v1/exam/<token>/state`. Answering 404 here
        would also tell a caller which tokens exist.
        """
        answer = self._call("legacy_exam", "tok-that-never-existed")

        self.assertEqual(
            answer["url"],
            "https://assessment.ethara.ai/exam/tok-that-never-existed")

    # -- the two list pages -----------------------------------------------

    def test_the_list_and_dashboard_go_to_the_apps_front_door(self):
        """Both to the front door, not to a guessed deep path.

        `_candidate_home` is what the invitation email's own button uses, so it
        is the one URL shape proven on every deployment, and the app routes a
        signed-in candidate to their list from there.
        """
        answer = self._call("legacy_candidate_home")

        self.assertEqual(answer["url"], "https://assessment.ethara.ai")
        self.assertEqual(answer["code"], 301)

    # -- the unconfigured deployment --------------------------------------

    def test_with_no_app_configured_the_pairing_table_answers(self):
        """An unset parameter is not a dead link any more.

        `_candidate_app_origin` falls through to
        `app_origins.PAIRED_APP_ORIGINS`, which has known
        `projects.ethara.ai -> assessment.ethara.ai` all along and was previously
        forbidden from being used - because the QWeb route it would have replaced
        still worked. It does not now.
        """
        self.icp.set_param("assessments_be_v2.candidate_app_base_url", "")
        evaluator = self._attempt()

        answer = self._call("legacy_exam", evaluator.access_token)

        self.assertEqual(
            answer["url"],
            "https://assessment.ethara.ai/exam/%s" % evaluator.access_token)

    def test_an_unpaired_host_falls_back_to_itself_rather_than_nowhere(self):
        """A preview environment or a bare IP is in no table.

        `<this host>/exam/<token>` is a guess, but it is a guess at the right
        SHAPE - it is what a same-origin deployment looks like - and it is a URL
        rather than a blank.
        """
        self.icp.set_param("assessments_be_v2.candidate_app_base_url", "")
        self.icp.set_param("web.base.url", "https://preview-7.internal.example")
        evaluator = self._attempt()

        answer = self._call("legacy_exam", evaluator.access_token)

        self.assertEqual(
            answer["url"],
            "https://preview-7.internal.example/exam/%s"
            % evaluator.access_token)

    def test_a_database_with_no_base_url_at_all_lands_somewhere(self):
        """The last resort. A 404 on a link somebody was emailed is worse than
        an Odoo landing page, and this is a database nobody has configured."""
        self.icp.set_param("assessments_be_v2.candidate_app_base_url", "")
        self.icp.set_param("web.base.url", "")

        answer = self._call("legacy_candidate_home")

        self.assertEqual(answer["url"], "/web")

    # -- the property that guards the retirement --------------------------

    def test_all_nine_retired_paths_are_declared_here(self):
        """The set, read off the route decorators.

        Stated as its own assertion because the FAILURE MODE OF FORGETTING ONE IS
        SILENT: an undeclared path falls through to `etp_assessment_pro`, which
        answers 200 with its own "invalid link" page. Nothing raises, nothing
        logs, and the candidate is told their exam is broken.
        """
        declared = set()
        for name in dir(legacy_redirects.AssessmentsBeLegacyRedirects):
            attribute = getattr(
                legacy_redirects.AssessmentsBeLegacyRedirects, name, None)
            routing = getattr(attribute, "original_routing", None)
            if routing:
                declared.update(routing.get("routes") or [])

        self.assertEqual(declared, {
            "/pro_assessment/<string:token>",
            "/pro_assessment/<string:token>/begin",
            "/pro_assessment/<string:token>/submit",
            "/pro_assessment/<string:token>/review",
            "/pro_assessment/<string:token>/answers",
            "/pro_assessment/<string:token>/finish",
            "/pro_assessment/<string:token>/violation",
            "/my/pro_assessments",
            "/my/pro_dashboard",
        })

    def test_no_retired_path_renders_a_template(self):
        """The templates are deleted, so a `render` here would be a 500.

        Asserted statically because the mistake it catches is the natural one: a
        future edit that wants to show a candidate a message reaches for
        `request.render` out of habit, and the QWeb file it would name no longer
        exists.
        """
        import ast
        import inspect

        tree = ast.parse(inspect.getsource(legacy_redirects))
        called = {
            node.func.attr
            for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
        }
        self.assertNotIn("render", called)
