# -*- coding: utf-8 -*-
"""A bearer call goes to a real project, or is refused as not configured.

  * The first call after a service-account key is saved with no project used
    to fail "not configured": minting the bearer adopts the key's project, but
    on a cursor of its own that the caller's transaction cannot see yet. The
    key's own `project_id` now stands in.
  * Every URL that names the project refuses an empty one the same way. The
    Veo lane built `projects//...`, which Google answers with a 404 that names
    nothing; the grading cache quietly went inline.
"""
import json
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from ..services import grading_cache
from ..services import secret_store
from ..services import vertex

_SA = {"type": "service_account", "project_id": "key-project",
       "client_email": "grader@key-project.iam.gserviceaccount.com",
       "private_key": "-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n",
       "token_uri": "https://oauth2.googleapis.com/token"}


@tagged("-at_install", "post_install")
class TestABearerCallFindsItsProject(TransactionCase):

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()
        for key in ("vertex_project_id", "vertex_api_key",
                    "vertex_access_token", "vertex_service_account_json"):
            self.icp.set_param("assessments_be_v2.%s" % key, "")
        self.icp.set_param("assessments_be_v2.vertex_location", "us-central1")
        # A bearer pinned the way a grading lane pins one: nothing is minted.
        self.pinned = self.env(context=dict(self.env.context,
                                            etp_vertex_bearer="token"))

    def test_the_first_call_after_a_key_is_saved_uses_the_keys_project(self):
        secret_store.set_secret(
            self.env, "assessments_be_v2.vertex_service_account_json",
            json.dumps(_SA))

        url, headers = vertex._gemini_request(
            self.pinned, "gemini-x", "generateContent")

        self.assertIn("/projects/key-project/locations/us-central1/", url)
        self.assertEqual(headers["Authorization"], "Bearer token")

    def test_an_unreadable_key_names_no_project(self):
        secret_store.set_secret(
            self.env, "assessments_be_v2.vertex_service_account_json",
            "not json")
        with self.assertRaises(vertex.VertexNotConfiguredError):
            vertex._gemini_request(self.pinned, "gemini-x", "generateContent")

    def test_a_set_project_wins_over_the_keys(self):
        secret_store.set_secret(
            self.env, "assessments_be_v2.vertex_service_account_json",
            json.dumps(_SA))
        self.icp.set_param("assessments_be_v2.vertex_project_id", "chosen")

        url, _headers = vertex._gemini_request(
            self.pinned, "gemini-x", "generateContent")

        self.assertIn("/projects/chosen/", url)

    def test_every_url_that_names_the_project_refuses_an_empty_one(self):
        builders = {
            "gemini": lambda: vertex._gemini_request(
                self.pinned, "gemini-x", "generateContent"),
            "veo": lambda: vertex._veo_url(
                self.pinned, "veo-x", "us-central1", "predictLongRunning"),
            "grading cache": lambda: grading_cache._auth(self.pinned),
        }
        for name, build in builders.items():
            with self.subTest(name):
                with self.assertRaises(
                        vertex.VertexNotConfiguredError) as caught:
                    build()
                self.assertIn("the Vertex project ID is empty",
                              str(caught.exception))
                self.assertIn("Settings > Assessments v2 > Vertex AI",
                              str(caught.exception))

    def test_a_grading_cache_with_no_project_is_not_swallowed(self):
        """Refused at the cache, the call is deferred like any refusal to
        spend (no attempt used) instead of logging a cache warning and
        failing again inline."""
        cache = type("Cache", (), {"key": "k" * 64, "create": True})()
        with patch.object(grading_cache._logger, "warning") as warned, \
                self.assertRaises(vertex.VertexNotConfiguredError):
            grading_cache.resolve(self.pinned, cache, "sys", "gemini-x", {})
        warned.assert_not_called()
