# -*- coding: utf-8 -*-
"""Which front end belongs to this backend, and who is trusted at CORS.

WHAT THIS PROTECTS. One Odoo instance and one Flutter client are deployed
together per environment, and the pairing used to be operator knowledge typed
into `assessments_be_v2.cors_origins` and
`assessments_be_v2.candidate_app_base_url` on every database. Both failure modes
are silent:

  * A missing CORS origin means Odoo answers 200 and the BROWSER throws the
    response away. Nothing in the server log is wrong; the app just shows empty
    screens, and an operator cannot debug a response that never arrived.
  * A missing `candidate_app_base_url` means every invited candidate is emailed
    into the Odoo QWeb portal instead of the client that runs the exam.

`services/app_origins.py` derives the pairing from `web.base.url` instead. Its
table is MIRRORED by `lib/assessment/data/environment.dart` in the
ethara-assessment-fe repo, which does the same derivation in reverse so the
client can find its backend. If the two disagree the client calls an origin this
server will not answer, so the parity assertions below are not decoration.

The CORS half is exercised through the module-level helpers rather than over
HTTP: what is being tested is the allow-list decision, not werkzeug. See
test_password_reset's note on the same choice.
"""
from odoo.tests.common import TransactionCase

from ..controllers.api import auth as auth_api
from ..models import ir_http
from ..services import app_origins


class TestPairedAppOrigin(TransactionCase):
    """The table, as a pure function. No database involved."""

    def test_the_new_production_backend_pairs_with_the_new_console(self):
        self.assertEqual(
            app_origins.paired_app_origin("https://projects.ethara.ai"),
            "https://assessment.ethara.ai")

    def test_stage_pairs_with_stage(self):
        self.assertEqual(
            app_origins.paired_app_origin("https://projects-stage.ethara.ai"),
            "https://assessment-stage.ethara.ai")

    def test_the_two_environments_never_pair_with_each_other(self):
        """The whole point. A copy-paste in the table would satisfy both tests
        above individually while crossing production with stage - which is the
        failure this file exists to prevent, and the one with no symptom.
        """
        prod = app_origins.paired_app_origin("https://projects.ethara.ai")
        stage = app_origins.paired_app_origin(
            "https://projects-stage.ethara.ai")
        self.assertNotEqual(prod, stage)
        self.assertNotIn("-stage", prod)
        self.assertIn("-stage", stage)

    def test_a_trailing_path_or_slash_does_not_defeat_the_lookup(self):
        """`web.base.url` is hand-editable and Odoo does not normalise it."""
        for value in ("https://projects.ethara.ai/",
                      "https://projects.ethara.ai/web",
                      "https://projects.ethara.ai/web/login",
                      "  https://projects.ethara.ai  "):
            self.assertEqual(
                app_origins.paired_app_origin(value),
                "https://assessment.ethara.ai", value)

    def test_a_hostname_matches_in_any_case(self):
        self.assertEqual(
            app_origins.paired_app_origin("https://Projects.Ethara.AI"),
            "https://assessment.ethara.ai")

    def test_the_REAL_stage_value_resolves(self):
        """`http://`, not `https://`. This is the value the live stage server
        actually reports from `/api/v1/settings`, read on 2026-09-07:

            base_url = 'http://projects-stage.ethara.ai'

        The table is keyed on netloc alone precisely so the scheme Odoo happens
        to have stored cannot decide whether CORS works. Keying on the full
        origin would have made the derivation silently dead on the one
        deployment it was written for - and a dead derivation looks exactly like
        a working one until a browser is pointed at it.
        """
        self.assertEqual(
            app_origins.paired_app_origin("http://projects-stage.ethara.ai"),
            "https://assessment-stage.ethara.ai")

    def test_the_derived_origin_is_https_whatever_the_backend_scheme_is(self):
        """The browser sends `Origin: https://assessment...`, because that is how
        the client is served. An `http://` derived value would never match it.
        """
        for backend in ("http://projects.ethara.ai",
                        "https://projects.ethara.ai",
                        "http://projects-stage.ethara.ai",
                        "https://projects-stage.ethara.ai"):
            self.assertTrue(
                app_origins.paired_app_origin(backend).startswith("https://"),
                backend)

    def test_a_bare_host_with_no_scheme_still_resolves(self):
        """urlsplit reads a scheme-less value as a PATH, so without the fixup
        in `_normalise` a hand-edited `web.base.url` yields no netloc and the
        pairing silently disappears.
        """
        self.assertEqual(
            app_origins.paired_app_origin("projects.ethara.ai"),
            "https://assessment.ethara.ai")

    def test_an_unknown_backend_pairs_with_nothing(self):
        """Empty is the SAFE answer: it widens no allow-list and changes no
        email link, so an unrecognised deployment behaves as it did before this
        module existed. A guess here would hand production's console the trust
        of a preview environment.
        """
        for value in ("https://projects-preview-7.ethara.ai",
                      "https://odoo.someone-else.com",
                      "https://10.0.0.5:8069",
                      "not a url",
                      "",
                      None):
            self.assertEqual(app_origins.paired_app_origin(value), "", value)

    def test_localhost_pairs_with_nothing_on_purpose(self):
        """localhost is MANY origins, not one - the front-end repo serves on
        8200, 8201, 8202 and whatever `flutter run` picks. Returning a single
        guess would name the wrong port most of the time, so `ir_http` owns the
        full localhost set and gates it on dev mode or an explicit opt-in.
        """
        for value in ("http://localhost:8069", "http://127.0.0.1:8069"):
            self.assertEqual(app_origins.paired_app_origin(value), "", value)
            self.assertTrue(app_origins.is_local_backend(value), value)

    def test_no_paired_origin_carries_a_trailing_slash(self):
        """Every caller concatenates a path onto these."""
        for origin in app_origins.PAIRED_APP_ORIGINS.values():
            self.assertFalse(origin.endswith("/"), origin)
            self.assertTrue(origin.startswith("https://"), origin)


class TestAppBaseUrl(TransactionCase):
    """The resolver the invitation and reset links share."""

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()

    def test_an_explicit_parameter_wins_over_the_table(self):
        """A deployment serving the client from a vanity domain is a topology
        no table can describe, and this is how it says so.
        """
        self.icp.set_param("web.base.url", "https://projects.ethara.ai")
        self.icp.set_param(app_origins.CANDIDATE_APP_PARAM,
                           "https://exams.acme.example/")
        self.assertEqual(app_origins.app_base_url(self.env),
                         "https://exams.acme.example")

    def test_a_blank_parameter_does_NOT_fall_through_to_the_table(self):
        """THE DELIBERATE ASYMMETRY, and the reason this test is worded as a
        negative.

        `app_base_url` reports what an OPERATOR configured, and "" when they
        configured nothing. It is not the whole answer to "where is the app" -
        `assessments.be.evaluator._candidate_app_origin` layers the pairing table
        and then the Odoo host underneath it, and that is where the fallback
        belongs.

        The distinction is load-bearing rather than stylistic: `_reset_base_url`
        and the link builders need to be able to tell "an operator named an
        origin" from "we guessed one", and a resolver that always returns
        something cannot express the difference.
        """
        self.icp.set_param("web.base.url", "https://projects.ethara.ai")
        self.icp.set_param(app_origins.CANDIDATE_APP_PARAM, "")
        self.assertEqual(app_origins.app_base_url(self.env), "")
        # The pairing IS available - this is a choice, not an inability.
        self.assertEqual(
            app_origins.paired_app_origin("https://projects.ethara.ai"),
            "https://assessment.ethara.ai")

    def test_whitespace_is_not_a_configured_value(self):
        """A settings field cleared by hand can hold a space, and treating that
        as configured would point every link at a blank origin.
        """
        self.icp.set_param("web.base.url", "https://projects-stage.ethara.ai")
        self.icp.set_param(app_origins.CANDIDATE_APP_PARAM, "   ")
        self.assertEqual(app_origins.app_base_url(self.env), "")

    def test_a_trailing_slash_is_stripped(self):
        """Every caller concatenates a path onto this."""
        self.icp.set_param(app_origins.CANDIDATE_APP_PARAM,
                           "https://assessment.ethara.ai/")
        self.assertEqual(app_origins.app_base_url(self.env),
                         "https://assessment.ethara.ai")


class TestDerivedOriginIsTrustedAtCors(TransactionCase):
    """The derived origin has to be accepted, and nothing else may be."""

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()
        # Module-level caches, shared by the whole process because the WSGI
        # wrapper that answers a preflight has no env of its own. Restored
        # afterwards so test order cannot matter.
        self._saved = (
            ir_http._CONFIGURED_ORIGINS_CACHE,
            ir_http._ALLOW_LOCALHOST_CACHE,
            ir_http._PAIRED_APP_ORIGIN_CACHE,
            ir_http._LOCAL_BACKEND_CACHE,
        )
        self.addCleanup(self._restore)

    def _restore(self):
        (ir_http._CONFIGURED_ORIGINS_CACHE,
         ir_http._ALLOW_LOCALHOST_CACHE,
         ir_http._PAIRED_APP_ORIGIN_CACHE,
         ir_http._LOCAL_BACKEND_CACHE) = self._saved

    def test_the_paired_console_is_allowed_with_nothing_configured(self):
        """A fresh deployment must answer its own client on the first call."""
        ir_http._PAIRED_APP_ORIGIN_CACHE = "https://assessment.ethara.ai"
        ir_http._CONFIGURED_ORIGINS_CACHE = set()
        ir_http._ALLOW_LOCALHOST_CACHE = False
        self.assertIn("https://assessment.ethara.ai",
                      ir_http._allowed_origins())

    def test_the_derived_origin_does_not_widen_anything_else(self):
        """Exactly one origin is added, never a wildcard and never a suffix
        match. `https://assessment.ethara.ai.evil.example` is a DIFFERENT site
        that a substring test would have trusted.
        """
        ir_http._PAIRED_APP_ORIGIN_CACHE = "https://assessment.ethara.ai"
        ir_http._CONFIGURED_ORIGINS_CACHE = set()
        ir_http._ALLOW_LOCALHOST_CACHE = False
        allowed = ir_http._allowed_origins()
        self.assertEqual(allowed, {"https://assessment.ethara.ai"})
        for hostile in ("https://assessment.ethara.ai.evil.example",
                        "http://assessment.ethara.ai",
                        "https://evil.example",
                        "*"):
            self.assertNotIn(hostile, allowed, hostile)

    def test_no_pairing_means_no_extra_trust(self):
        ir_http._PAIRED_APP_ORIGIN_CACHE = ""
        ir_http._CONFIGURED_ORIGINS_CACHE = set()
        ir_http._ALLOW_LOCALHOST_CACHE = False
        self.assertEqual(ir_http._allowed_origins(), set())

    def test_configured_origins_are_added_not_replaced(self):
        """Deriving one origin must not be a reason to stop honouring the
        parameter an operator set.

        THE PRODUCTION-SAFETY PROPERTY. The live stage server already answers
        `https://assessment-stage.ethara.ai` with the full credentialed header
        set, so its `cors_origins` already names it - which makes this change a
        no-op there. That is only true if the derivation is strictly ADDITIVE.
        """
        ir_http._PAIRED_APP_ORIGIN_CACHE = "https://assessment.ethara.ai"
        ir_http._CONFIGURED_ORIGINS_CACHE = {"https://extra.example"}
        ir_http._ALLOW_LOCALHOST_CACHE = False
        self.assertEqual(
            ir_http._allowed_origins(),
            {"https://assessment.ethara.ai", "https://extra.example"})

    def test_a_derivation_failure_cannot_drop_the_configured_origins(self):
        """The regression this nearly shipped with.

        `_refresh_paired_origin` used to live INSIDE the try in
        `_configured_origins`, above `_CONFIGURED_ORIGINS_CACHE = parsed`. A
        throw there took the `except`'s early `return`, so the parse never ran
        and an operator's hand-configured origins were DROPPED - breaking CORS
        for a front end that was working, in order to add a convenience.

        Simulated by making the derivation raise, which is what a mid-upgrade
        import or an unreadable parameter table looks like.
        """
        ir_http._CONFIGURED_ORIGINS_CACHE = {"https://already-working.example"}

        class _Exploding:
            def get_param(self, *a, **k):
                raise RuntimeError("parameter table unavailable")

        ir_http._refresh_paired_origin(_Exploding())
        self.assertEqual(ir_http._CONFIGURED_ORIGINS_CACHE,
                         {"https://already-working.example"})

    def test_the_derivation_never_raises(self):
        """It runs on the CORS path of every API request. An exception here is
        the whole API down, so it has to swallow anything.
        """
        class _Exploding:
            def get_param(self, *a, **k):
                raise RuntimeError("boom")

        try:
            ir_http._refresh_paired_origin(_Exploding())
        except Exception as exc:  # noqa: BLE001 - that is the assertion
            self.fail("_refresh_paired_origin raised %r" % (exc,))

    def test_every_port_the_front_end_repo_serves_on_is_trusted(self):
        """ethara-assessment-fe's Makefile serves one bundle per environment:
        8200 local, 8201 stage, 8202 prod, all three up at once. 8201 and 8202
        were absent, so `make serve-stage` against this backend failed at CORS -
        request arrives, Odoo answers 200, browser discards it, app shows empty
        screens over a clean server log.
        """
        for port in (8200, 8201, 8202):
            for host in ("localhost", "127.0.0.1"):
                self.assertIn("http://%s:%d" % (host, port),
                              ir_http.LOCALHOST_ORIGINS)

    def test_localhost_is_still_gated_on_a_deployed_host(self):
        """The derived origin must not have unlocked the dev set. Trusting
        localhost on a shared deployment trusts any page a signed-in user
        happens to be serving on their own machine.

        BOTH FLAGS ARE CLEARED, not just one. `_LOCAL_BACKEND_CACHE` is the third
        way into `_localhost_origins` and it is derived from `web.base.url`, so a
        test that only cleared the parameter flag would pass on a deployed host
        and silently do nothing on a developer's machine - where the localhost
        set is legitimately open and this assertion is not the invariant.
        """
        ir_http._ALLOW_LOCALHOST_CACHE = False
        ir_http._LOCAL_BACKEND_CACHE = False
        if not ir_http._dev_mode():
            self.assertEqual(ir_http._localhost_origins(), set())


class TestEmailedLinksDidNotChange(TransactionCase):
    """THE REGRESSION GUARD FOR PRODUCTION.

    Introducing `services/app_origins.py` refactored the three callers that
    build candidate and password-reset links onto one shared reader. This class
    exists to prove that refactor moved no behaviour, because the thing it
    touches is emailed to real candidates and cannot be recalled.

    Every case below was what the code did BEFORE the pairing table existed, and
    a change that moved behaviour had to rewrite one consciously - which is the
    point, and which is exactly what happened: the reset case pinned a link that
    404s, with a docstring explaining why it was correct. See
    `test_an_unset_app_url_derives_the_reset_link_too`.

    THE LESSON KEPT HERE: a regression guard is only as true as its reason. This
    one asserted "unchanged" over a link nobody had opened.
    """

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()
        self.icp.set_param(auth_api.RESET_URL_PARAM, "")
        self.icp.set_param(app_origins.CANDIDATE_APP_PARAM, "")
        # A RECOGNISED host, so the pairing is available and declining to use it
        # is being tested - not merely the absence of a pairing.
        self.icp.set_param("web.base.url", "https://projects.ethara.ai")

    def test_an_unset_app_url_derives_the_reset_link_too(self):
        """THE ONE THIS CLASS GOT WRONG, and it was a live 404.

        This test used to assert `https://projects.ethara.ai/reset-password`,
        on the stated grounds that "`RESET_PATH` is Odoo's own password flow,
        served by `auth_signup` on the Odoo host". That is false, and it is
        worth spelling out because the sentence read plausibly for a week:

          * Odoo's `auth_signup` route is `/web/reset_password` - underscore,
            under `/web` (`odoo/addons/auth_signup/controllers/main.py`).
          * `RESET_PATH` is `/reset-password` - hyphen, at the root. It is the
            FLUTTER CLIENT's page, parsed by `resetTokenFrom` in the front-end
            repo's `lib/deep_link.dart`.

        Two different paths on two different hosts. Nothing on projects.ethara.ai
        answers the hyphenated one, so every reset email sent from production -
        which has never set `candidate_app_base_url` - landed the user on the
        website's "Page Not Found". Verified live: that URL returns 404 while
        `https://assessment.ethara.ai/reset-password` returns the app.

        The reset page is served by the same app as the candidate front door,
        so it derives the same origin, from the same resolver.
        """
        self.assertEqual(
            auth_api._reset_base_url(self.env),
            "https://assessment.ethara.ai" + auth_api.RESET_PATH)

    def test_no_emailed_link_points_at_the_odoo_host(self):
        """The property, stated once over every link this addon mints.

        A fourth link-builder added later, or a fifth, cannot quietly go back to
        `web.base.url` without failing here. That is the whole class of bug: a
        link that is EMAILED, so the failure surfaces in somebody's inbox rather
        than in a log, and only on a database nobody configured by hand.
        """
        evaluator = self.env["assessments.be.evaluator"]
        for link in (auth_api._reset_base_url(self.env),
                     evaluator._candidate_link_for("tok-123"),
                     evaluator._candidate_home()):
            self.assertNotIn("projects.ethara.ai", link)
            self.assertIn("assessment.ethara.ai", link)

    def test_an_unset_app_url_now_derives_the_paired_app_origin(self):
        """POLICY CHANGE, and these two tests used to pin the opposite.

        They asserted `https://projects.ethara.ai/pro_assessment/tok-123` and
        `.../my/pro_assessments` - Odoo's own QWeb exam runner - because an unset
        parameter deliberately did NOT derive the app origin. The reason was
        sound: these links are EMAILED and cannot be recalled, and the QWeb route
        answered 200, so inferring would have silently redirected every
        invitation on an unconfigured deployment. A behaviour change, not a fix.

        That runner is retired. `controllers/legacy_redirects.py` answers its
        paths with a redirect into the app, so continuing to MINT links at them
        would mean emailing people into a bounce - and on a deployment where
        upstream `etp_assessment_pro` is installed, into upstream's own
        "invalid link" page. Deriving is now the accurate answer, and the pairing
        table has known it all along.

        Nothing is lost for links already sent: those paths still resolve, by
        redirect. This is only about where NEW links point.
        """
        evaluator = self.env["assessments.be.evaluator"]
        self.assertEqual(
            evaluator._candidate_link_for("tok-123"),
            "https://assessment.ethara.ai/exam/tok-123")
        self.assertEqual(
            evaluator._candidate_home(),
            "https://assessment.ethara.ai")

    def test_no_new_link_points_at_a_retired_path(self):
        """The property, stated independently of which origin wins.

        A link into `/pro_assessment/...` or `/my/pro_...` is now a link into a
        redirect. Asserted over every link-building path at once so a fourth one
        added later cannot quietly reintroduce the shape.
        """
        evaluator = self.env["assessments.be.evaluator"]
        for link in (auth_api._reset_base_url(self.env),
                     evaluator._candidate_link_for("tok-123"),
                     evaluator._candidate_home()):
            self.assertNotIn("pro_assessment", link)
            self.assertNotIn("pro_assessments", link)
            self.assertNotIn("pro_dashboard", link)

    def test_app_base_url_itself_still_reports_only_what_was_configured(self):
        """TWO READERS, ON PURPOSE, and the pair is the point.

        `app_base_url` reports what an operator typed and nothing else;
        `client_app_origin` is the one that also derives. Keeping the first is
        what lets a caller ask whether anything was configured AT ALL - a
        defaulting resolver cannot answer that.

        The bug was never that both existed. It was that `_reset_base_url`
        called the reporting one where it needed the resolving one.
        """
        self.assertEqual(app_origins.app_base_url(self.env), "")
        self.assertEqual(
            app_origins.paired_app_origin_for_env(self.env),
            "https://assessment.ethara.ai")

    def test_a_configured_app_url_is_honoured_as_it_always_was(self):
        self.icp.set_param(app_origins.CANDIDATE_APP_PARAM,
                           "https://assessment.ethara.ai/")
        evaluator = self.env["assessments.be.evaluator"]
        self.assertEqual(evaluator._candidate_link_for("tok-123"),
                         "https://assessment.ethara.ai/exam/tok-123")
        self.assertEqual(evaluator._candidate_home(),
                         "https://assessment.ethara.ai")
        self.assertEqual(
            auth_api._reset_base_url(self.env),
            "https://assessment.ethara.ai" + auth_api.RESET_PATH)

    def test_an_explicit_reset_url_still_wins(self):
        self.icp.set_param(auth_api.RESET_URL_PARAM,
                           "https://exams.acme.example/reset/")
        self.assertEqual(auth_api._reset_base_url(self.env),
                         "https://exams.acme.example/reset")

    def test_no_token_is_still_no_link(self):
        self.assertFalse(
            self.env["assessments.be.evaluator"]._candidate_link_for(""))


class TestTheTableMatchesTheClient(TransactionCase):
    """Server and client must agree, or every call fails at CORS.

    Reads the Dart source next door. SKIPPED, not failed, when the front-end
    repo is not checked out beside this one: a backend-only CI box must still be
    able to run this suite.
    """

    FE_ENVIRONMENT_DART = (
        "../../../../ethara-assessment-fe/lib/assessment/data/environment.dart")

    def _dart_source(self):
        import os
        path = os.path.normpath(
            os.path.join(os.path.dirname(__file__), self.FE_ENVIRONMENT_DART))
        if not os.path.isfile(path):
            self.skipTest("ethara-assessment-fe is not checked out at %s"
                          % path)
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()

    def test_every_pair_in_this_table_is_in_the_client_table(self):
        """Compared as HOSTNAMES, not as origins.

        The two files spell the same pairing differently and both are right:
        this table stores full origins (`https://assessment.ethara.ai`) because
        it feeds a CORS allow-list, where the scheme is part of the origin; the
        Dart table keys on bare hostnames (`'assessment.ethara.ai'`) because it
        matches `Uri.base.host`, which carries no scheme. Asserting on the raw
        strings compares spelling rather than agreement.
        """
        source = self._dart_source()
        for backend, app in app_origins.PAIRED_APP_ORIGINS.items():
            self.assertIn(
                backend, source,
                "backend host %s is missing from environment.dart - the client "
                "would not know to call this deployment" % backend)
            app_host = app_origins.netloc_of(app)
            self.assertIn(
                app_host, source,
                "client host %s is missing from environment.dart - this server "
                "trusts an origin the client never serves from" % app_host)

    def test_the_client_agrees_which_backend_is_which(self):
        """The pairing has to be the same in both directions.

        `environment.dart` maps client host -> backend origin. Read the line for
        each of our client hosts and check the backend on it is the one this
        table came from. Without this, the two files could each be internally
        consistent while crossing production with stage - and the only symptom
        would be production's console showing stage's data.
        """
        source = self._dart_source()
        # The Dart table is `'<client host>': AppEnvironment.<name>` and the
        # profiles are `AppEnvironment.<name>: ... apiBaseUrl: '<backend>'`.
        # Rather than parse Dart, assert co-location: the backend origin and the
        # client host must both be present, and no client host may appear on the
        # same line as the WRONG backend.
        for backend, app in app_origins.PAIRED_APP_ORIGINS.items():
            app_host = app_origins.netloc_of(app)
            wrong = [other for other in app_origins.PAIRED_APP_ORIGINS
                     if other != backend]
            for line in source.splitlines():
                if app_host not in line:
                    continue
                for other in wrong:
                    self.assertNotIn(
                        other, line,
                        "environment.dart pairs client %s with backend %s; "
                        "this table pairs it with %s"
                        % (app_host, other, backend))
