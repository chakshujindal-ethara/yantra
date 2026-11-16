# -*- coding: utf-8 -*-
"""A browser can read `Retry-After` on a 429 or 503 from another origin.

SEB review #8 (backend half): CORS lets a page read only the "simple" response
headers unless the server names more in `Access-Control-Expose-Headers`. None
was sent, so the web app saw no `Retry-After` on a shed and fell back to its
own guess. Every place that sets the allowed-origin headers now exposes it:
`_apply_cors` (dispatched responses) and the WSGI wrapper, which is the only
layer that sees the pool-full 503 (`controllers/load_shed.py`).
"""
from unittest.mock import patch

from werkzeug.datastructures import Headers

from odoo.tests.common import TransactionCase, tagged

from ..models import ir_http

ORIGIN = "https://app.example.com"


@tagged("-at_install", "post_install")
class TestABrowserCanReadRetryAfter(TransactionCase):

    def test_an_api_response_exposes_retry_after(self):
        headers = Headers([("Access-Control-Expose-Headers", "X-Old")])

        ir_http._apply_cors(headers, ORIGIN)

        self.assertEqual(headers.getlist("Access-Control-Expose-Headers"),
                         ["Retry-After"])

    def test_the_wsgi_layer_exposes_it_on_a_shed(self):
        from odoo.http import Application

        def _shed(_self, environ, start_response):
            start_response("503 Service Unavailable",
                           [("Retry-After", "2"),
                            ("Access-Control-Expose-Headers", "X-Old")])
            return [b"{}"]

        sent = {}

        def _start_response(status, headers, exc_info=None):
            sent["headers"] = headers

        # Re-wrap a shedding stand-in, as the real install wraps Odoo.
        with patch.object(Application, "__call__", _shed), \
                patch.object(Application, "_etp_cors_wrapped", False), \
                patch.object(ir_http, "_CONFIGURED_ORIGINS_CACHE", {ORIGIN}):
            ir_http._install_cors_middleware()
            Application.__call__(
                None, {"PATH_INFO": "/api/v1/exam/x/answer",
                       "HTTP_ORIGIN": ORIGIN}, _start_response)

        headers = Headers(sent["headers"])
        self.assertEqual(headers.get("Access-Control-Allow-Origin"), ORIGIN)
        self.assertEqual(headers.getlist("Access-Control-Expose-Headers"),
                         ["Retry-After"])
        self.assertEqual(headers.get("Retry-After"), "2")
