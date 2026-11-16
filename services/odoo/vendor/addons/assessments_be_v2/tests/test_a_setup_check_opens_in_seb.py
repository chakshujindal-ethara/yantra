# -*- coding: utf-8 -*-
"""R4: `GET /api/v1/seb/check-config` hands SEB the setup check's .seb.

A candidate on their own laptop presses "Test in Safe Exam Browser" on the
public `/seb-check` page; SEB fetches this file with no session and opens the
check page with the camera allowed. It carries no quit password, so a
candidate who is only testing can always get out.
"""
import plistlib
from unittest.mock import patch

from odoo.http import Response
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import candidate as candidate_api
from ..services import app_origins

ORIGIN = "https://exam.example.com"


@tagged("-at_install", "post_install")
class TestASetupCheckOpensInSeb(TransactionCase):

    def _get(self):
        class _Req:
            def __init__(self, env):
                self.env = env
                self.params = {}

            # A `type="http"` route: Odoo's wrapper accepts only a real
            # Response from it.
            def make_response(self, data, headers=None, status=200):
                return Response(data, headers=headers, status=status)

        fake = _Req(self.env(user=self.env.ref("base.public_user")))
        with patch.object(candidate_api, "request", fake):
            return candidate_api.EtpAssessmentApiCandidate().seb_check_config()

    def test_the_file_opens_the_check_page_with_the_camera_and_no_password(
            self):
        self.env["ir.config_parameter"].sudo().set_param(
            app_origins.CANDIDATE_APP_PARAM, ORIGIN + "/")
        out = self._get()

        self.assertIsInstance(out, Response)
        self.assertEqual(out.status_code, 200)
        self.assertEqual(out.headers["Content-Type"], "application/seb")
        served = plistlib.loads(out.data)
        self.assertEqual(served["startURL"], ORIGIN + "/seb-check")
        self.assertEqual(served["quitURL"], ORIGIN + "/seb-check/quit")
        self.assertIs(served["browserMediaCaptureCamera"], True)
        self.assertNotIn("hashedQuitPassword", served)
