# -*- coding: utf-8 -*-
"""Pull the repo, restore a database, run it. No parameter to set, anywhere.

THE WORKFLOW THIS PROTECTS: the same tree is pushed and pulled between local,
stage and production and used as it is. So a setting that has to be typed in per
environment is a setting that will be missing on one of them, and both of the
ones this file covers fail SILENTLY:

  * a missing client origin means every invited candidate is emailed a link to
    port 8069 - Odoo, not the exam runner;
  * a missing CORS entry means the request reaches Odoo, Odoo answers 200, and
    the BROWSER discards the response. The server log is clean and the app shows
    empty screens.

BOTH ARE NOW DERIVED FROM `web.base.url`, which Odoo maintains itself. Production
and stage were already covered by the pairing table in `services/app_origins.py`;
LOCAL was not, and that is what these tests add.

WHY DERIVING FROM `web.base.url` IS NOT A HOLE. It is a statement about which
server this IS, written to a parameter only an administrator of this database can
set - never a statement about who is calling. Nothing here reads the request's
`Origin`. A deployment on a real hostname therefore admits nothing extra however
it is called, which is what `test_a_deployed_host_trusts_no_localhost` pins.
"""
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from ..models import ir_http
from ..services import app_origins

PROD_BACKEND = "https://projects.ethara.ai"
STAGE_BACKEND = "https://projects-stage.ethara.ai"
PROD_CLIENT = "https://assessment.ethara.ai"
STAGE_CLIENT = "https://assessment-stage.ethara.ai"


@tagged("-at_install", "post_install")
class TestTheClientOriginIsDerivedPerEnvironment(TransactionCase):
    """One tree, three environments, no configuration on any of them."""

    def test_production_derives_the_production_client(self):
        self.assertEqual(app_origins.paired_app_origin(PROD_BACKEND),
                         PROD_CLIENT)
        self.assertEqual(app_origins.local_app_origin(PROD_BACKEND), "")

    def test_stage_derives_the_stage_client(self):
        self.assertEqual(app_origins.paired_app_origin(STAGE_BACKEND),
                         STAGE_CLIENT)
        self.assertEqual(app_origins.local_app_origin(STAGE_BACKEND), "")

    def test_a_local_backend_derives_the_local_client(self):
        """THE GAP THIS CLOSES. `paired_app_origin` returns "" for localhost on
        purpose - it feeds the CORS allow-list, where one guessed port would be
        wrong most of the time. So a local database fell through to
        `web.base.url` itself, port 8069, which is Odoo and not the client.
        """
        for base in ("http://localhost:8069", "http://127.0.0.1:8069",
                     "http://localhost", "http://127.0.0.1"):
            self.assertEqual(
                app_origins.local_app_origin(base),
                app_origins.LOCAL_APP_ORIGIN,
                "a local backend at %r must resolve the local client" % base)

    def test_any_port_on_localhost_is_local(self):
        """CAUGHT BY A FRESH INSTALL, not by reasoning.

        The check was an enumerated netloc set that only knew 8069 - and the port
        is the part that varies. Odoo writes `web.base.url` from the first request
        it serves, so installing with `--http-port=8199` (routine when 8069 is
        taken) produced `http://localhost:8199`, which read as a DEPLOYED host: no
        local client origin and no localhost CORS, on a developer's own machine.
        """
        for port in (8069, 8075, 8199, 8888, 80):
            for host in ("localhost", "127.0.0.1"):
                base = "http://%s:%d" % (host, port)
                self.assertTrue(
                    app_origins.is_local_backend(base),
                    "%s is a developer's machine whatever the port" % base)
                self.assertEqual(
                    app_origins.local_app_origin(base),
                    app_origins.LOCAL_APP_ORIGIN)

    def test_an_ipv6_loopback_is_local(self):
        self.assertTrue(app_origins.is_local_backend("http://[::1]:8069"))

    def test_a_hostname_that_merely_contains_localhost_is_not_local(self):
        """The check is on the HOST, exactly, not a substring. `localhost.evil.com`
        resolves wherever its owner points it, and reading it as a developer
        machine would open the localhost CORS set on a real deployment."""
        for base in ("https://localhost.evil.com", "https://mylocalhost",
                     "https://localhost.ethara.ai", "https://127.0.0.1.evil.com"):
            self.assertFalse(
                app_origins.is_local_backend(base),
                "%s must not read as a developer machine" % base)
            self.assertEqual(app_origins.local_app_origin(base), "")

    def test_the_local_default_is_the_port_the_front_end_repo_serves_on(self):
        """8200 is `LOCAL_PORT` in ethara-assessment-fe's Makefile, which is what
        `make serve-local` binds `build/web-local` to. Not a guess."""
        self.assertEqual(app_origins.LOCAL_APP_ORIGIN, "http://localhost:8200")

    def test_an_unknown_host_still_derives_nothing(self):
        """A preview box or a bare IP must behave exactly as before: no pairing,
        no local default, so the caller falls back to its own host."""
        for base in ("https://preview-7.internal", "https://10.0.0.4",
                     "https://projects.example.com"):
            self.assertEqual(app_origins.paired_app_origin(base), "")
            self.assertEqual(app_origins.local_app_origin(base), "")


@tagged("-at_install", "post_install")
class TestTheCandidateLinkResolvesOnEveryEnvironment(TransactionCase):
    """The four-step chain on the model, end to end, per environment."""

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()
        self.Evaluator = self.env["assessments.be.evaluator"]

    def _origin_with(self, base, configured=None):
        """`_candidate_app_origin()` as it resolves for a given `web.base.url`."""
        self.icp.set_param("web.base.url", base)
        self.icp.set_param(app_origins.CANDIDATE_APP_PARAM, configured or "")
        return self.Evaluator._candidate_app_origin()

    def test_production_needs_no_parameter(self):
        self.assertEqual(self._origin_with(PROD_BACKEND), PROD_CLIENT)

    def test_stage_needs_no_parameter(self):
        self.assertEqual(self._origin_with(STAGE_BACKEND), STAGE_CLIENT)

    def test_local_needs_no_parameter(self):
        self.assertEqual(self._origin_with("http://localhost:8069"),
                         app_origins.LOCAL_APP_ORIGIN)

    def test_an_explicit_parameter_still_wins_everywhere(self):
        """A deployment serving the client from a vanity domain, a path, or
        Odoo's own origin is a topology no table describes. The override is how
        it says so, and deriving must not have taken it away."""
        for base in (PROD_BACKEND, STAGE_BACKEND, "http://localhost:8069"):
            self.assertEqual(
                self._origin_with(base, configured="https://exams.acme.test"),
                "https://exams.acme.test",
                "the explicit parameter must win over the derivation on %r"
                % base)

    def test_an_unknown_host_falls_back_to_itself(self):
        """Unchanged behaviour, stated so the new step cannot swallow it."""
        self.assertEqual(self._origin_with("https://preview-7.internal"),
                         "https://preview-7.internal")

    def test_the_link_is_the_app_exam_path_on_every_environment(self):
        """What a candidate is actually emailed."""
        cases = ((PROD_BACKEND, PROD_CLIENT),
                 (STAGE_BACKEND, STAGE_CLIENT),
                 ("http://localhost:8069", app_origins.LOCAL_APP_ORIGIN))
        for base, client in cases:
            self.icp.set_param("web.base.url", base)
            self.icp.set_param(app_origins.CANDIDATE_APP_PARAM, "")
            self.assertEqual(
                self.Evaluator._candidate_link_for("tok-123"),
                "%s/exam/tok-123" % client)

    def test_no_environment_emails_a_link_to_odoos_own_port(self):
        """The symptom that started this: an unset local database emailed
        `http://localhost:8069/exam/<token>`, which is Odoo. The exam runner is
        not there, so the candidate met a redirect at best."""
        for base in (PROD_BACKEND, STAGE_BACKEND, "http://localhost:8069"):
            self.icp.set_param("web.base.url", base)
            self.icp.set_param(app_origins.CANDIDATE_APP_PARAM, "")
            link = self.Evaluator._candidate_link_for("tok-123")
            self.assertNotIn(
                app_origins.netloc_of(base), link,
                "%s must not send a candidate to the BACKEND's own origin"
                % base)


@tagged("-at_install", "post_install")
class TestCorsOpensItselfOnlyOnADeveloperMachine(TransactionCase):
    """`cors_allow_localhost` was the other setting nobody remembers."""

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()
        # Process-wide caches: the WSGI wrapper that answers a preflight has no
        # env of its own, so these are module-level and must be restored.
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

    def _refresh_for(self, base):
        """Run the real cache refresh against a given `web.base.url`."""
        self.icp.set_param("web.base.url", base)
        ir_http._refresh_paired_origin(self.icp)

    def test_a_local_backend_trusts_the_localhost_set_with_no_parameter(self):
        """THE GAP THIS CLOSES, and it fails in the least helpful way there is:
        the preflight is refused, the browser bins the response, the Odoo log
        looks healthy, and the client shows an empty screen with a CORS error
        buried in the console.
        """
        self._refresh_for("http://localhost:8069")
        ir_http._ALLOW_LOCALHOST_CACHE = False

        self.assertTrue(ir_http._LOCAL_BACKEND_CACHE)
        self.assertEqual(ir_http._localhost_origins(),
                         ir_http.LOCALHOST_ORIGINS)
        self.assertIn("http://127.0.0.1:8200", ir_http._allowed_origins())

    def test_a_deployed_host_trusts_no_localhost(self):
        """The security property. Derived from which server this IS, never from
        who is calling - so a real hostname admits nothing extra."""
        for base in (PROD_BACKEND, STAGE_BACKEND, "https://preview-7.internal"):
            self._refresh_for(base)
            ir_http._ALLOW_LOCALHOST_CACHE = False
            self.assertFalse(
                ir_http._LOCAL_BACKEND_CACHE,
                "%s must not read as a developer machine" % base)
            # `_dev_mode` is the third way in and is a server flag, not
            # something this test controls; patched off so the assertion is
            # about the derivation and passes under `odoo-bin --dev` too.
            with patch.object(ir_http, "_dev_mode", return_value=False):
                self.assertEqual(ir_http._localhost_origins(), set())

    def test_the_parameter_still_opens_a_shared_box(self):
        """The case the parameter was written for and still owns: a staging box
        on a real hostname that front-end work points a local build at. Its own
        `web.base.url` is not localhost, so only the opt-in can admit it."""
        self._refresh_for("https://preview-7.internal")
        ir_http._ALLOW_LOCALHOST_CACHE = True

        self.assertEqual(ir_http._localhost_origins(),
                         ir_http.LOCALHOST_ORIGINS)

    def test_the_production_client_is_trusted_and_localhost_is_not(self):
        """Both halves of a production deployment's allow-list, together."""
        self._refresh_for(PROD_BACKEND)
        ir_http._ALLOW_LOCALHOST_CACHE = False
        ir_http._CONFIGURED_ORIGINS_CACHE = set()

        with patch.object(ir_http, "_dev_mode", return_value=False):
            allowed = ir_http._allowed_origins()

        self.assertEqual(allowed, {PROD_CLIENT})

    def test_the_refresh_reads_both_facts_from_one_parameter(self):
        """They are read on the same trip on purpose. Refreshed apart, a
        preflight and its request could disagree about whether localhost is
        allowed - which is a bug that only shows up under load."""
        self._refresh_for(STAGE_BACKEND)
        self.assertEqual(ir_http._PAIRED_APP_ORIGIN_CACHE, STAGE_CLIENT)
        self.assertFalse(ir_http._LOCAL_BACKEND_CACHE)

        self._refresh_for("http://localhost:8069")
        self.assertEqual(ir_http._PAIRED_APP_ORIGIN_CACHE, "")
        self.assertTrue(ir_http._LOCAL_BACKEND_CACHE)

    def test_a_refresh_failure_keeps_the_last_good_answer(self):
        """This runs on every API request. A database mid-upgrade must degrade
        to the previous answer rather than take the API down."""
        self._refresh_for(PROD_BACKEND)

        class _Exploding:
            def get_param(self, *args, **kwargs):
                raise RuntimeError("parameter table is not readable")

        try:
            ir_http._refresh_paired_origin(_Exploding())
        except Exception as exc:  # noqa: BLE001
            self.fail("_refresh_paired_origin raised %r" % (exc,))

        self.assertEqual(ir_http._PAIRED_APP_ORIGIN_CACHE, PROD_CLIENT)
        self.assertFalse(ir_http._LOCAL_BACKEND_CACHE)


@tagged("-at_install", "post_install")
class TestNoSettingIsRequiredForALocalRun(TransactionCase):
    """The claim in docs/ETP_KNOWLEDGE_BASE.md (4.3 Local validation walkthrough), made checkable.

    That guide used to end with "two settings are local-only, do not copy them
    outward". Both are now derived, so the guide says nothing has to be set - and
    a note in prose is not something anybody re-checks. This is.
    """

    def test_neither_local_only_parameter_is_needed(self):
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param("web.base.url", "http://localhost:8069")
        # Explicitly BLANK, which is the state of a database nobody has touched.
        icp.set_param(app_origins.CANDIDATE_APP_PARAM, "")
        icp.set_param(ir_http.CORS_LOCALHOST_PARAM, "")
        ir_http._refresh_paired_origin(icp)
        ir_http._ALLOW_LOCALHOST_CACHE = False
        self.addCleanup(setattr, ir_http, "_LOCAL_BACKEND_CACHE",
                        ir_http._LOCAL_BACKEND_CACHE)

        link = self.env["assessments.be.evaluator"]._candidate_link_for("t")

        self.assertEqual(link, "%s/exam/t" % app_origins.LOCAL_APP_ORIGIN,
                         "an exam link must resolve with nothing configured")
        self.assertIn("http://localhost:8200", ir_http._allowed_origins(),
                      "the client's own origin must be allowed at CORS with "
                      "nothing configured")
