# -*- coding: utf-8 -*-
"""S12 (R4-03): an import that answers 422 `import_failed` keeps no rows.

The routes RETURN the failure, so `api_endpoint` never rolled back and the
rows made before the bad item were committed - live bank questions on the
native lane - while the client was told nothing was imported.
"""
import base64
import json
from uuid import uuid4

from odoo.tests.common import HttpCase, tagged

_JSON = {"Content-Type": "application/json"}


@tagged("-at_install", "post_install")
class TestAFailedImportLeavesNothingBehind(HttpCase):

    def setUp(self):
        super().setUp()
        self.authenticate("admin", "admin")
        tag = uuid4().hex[:8]
        self.native = {"assessments_be_bank": "1", "questions": [
            {"name": "Good %s" % tag, "question_type": "subjective_rubric",
             "prompt": "Describe"},
            {"name": "Bad %s" % tag, "question_type": "mcq", "prompt": "Pick",
             "dimensions": [{"options": ["x"]}]},
        ]}

    def _post(self, url, body):
        response = self.url_open(url, data=json.dumps(body), headers=_JSON,
                                 timeout=30)
        return response.status_code, response.json()

    def _bank(self):
        return self.env["assessments.be.question"].with_context(
            active_test=False).search_count([])

    def _assert_refused_and_clean(self, url, body, model, count):
        before = count()
        status, payload = self._post(url, body)
        self.assertEqual(status, 422, payload)
        self.assertEqual(payload["error"]["code"], "import_failed", payload)
        self.assertEqual(count(), before,
                         "%s rows made before the failure were kept" % model)

    def test_the_native_payload_lane(self):
        self._assert_refused_and_clean(
            "/api/v1/bank/import", {"payload": self.native},
            "question", self._bank)

    def test_the_file_lane(self):
        content = base64.b64encode(json.dumps(self.native).encode()).decode()
        self._assert_refused_and_clean(
            "/api/v1/bank/import",
            {"content": content, "filename": "bank.json"},
            "question", self._bank)

    def test_the_generator_csv_import(self):
        csv = "name,sop_question_count\nGood %s,3\nBad %s,-1\n" % (
            uuid4().hex[:6], uuid4().hex[:6])
        prompts = self.env["assessments.be.prompt"].with_context(
            active_test=False)
        self._assert_refused_and_clean(
            "/api/v1/generators/import",
            {"content": base64.b64encode(csv.encode()).decode()},
            "generator", lambda: prompts.search_count([]))
