"""An exam route's failure log names the attempt, never the token.

THE GAP (items_to_do #12). A 500 on an exam route logged only the route name:
the token is a credential and is kept out of the logs, and nothing else said
WHICH attempt failed - so after an incident the affected candidates could not
be listed. `evaluator_from_token` now leaves the attempt id on the request and
`api_endpoint` logs it as `evaluator_id=`.

The load shed's 503 warning, which fires before any route runs, named the raw
request path - for an exam route that IS the token. It is redacted now.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from psycopg2.pool import PoolError

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAnExamFailureLogNamesTheAttempt(TransactionCase):

    def _evaluator(self):
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Failure log %s" % uuid4().hex[:6]})
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric",
            "prompt": "Explain",
            "generator_id": generator.id,
        })
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, question.ids)],
            "duration_minutes": 60,
            "state": "in_progress",
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Failure Log",
            "email_from": "%s@example.com" % uuid4().hex[:10],
        })
        return self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": json.dumps(question.ids),
            "access_token": uuid4().hex,
        })

    def test_a_500_logs_the_evaluator_id_and_not_the_token(self):
        from ..controllers.api import common as api_common

        evaluator = self._evaluator()

        class _Req:
            def __init__(self, env):
                self.env = env
                self.params = {}

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        @api_common.api_endpoint
        def handler(token):
            api_common.evaluator_from_token(token)
            raise RuntimeError("stubbed exam handler failure")

        with patch.object(api_common, "request", _Req(self.env)), \
                self.assertLogs(api_common._logger.name, "ERROR") as logs:
            reply = handler(token=evaluator.access_token)

        self.assertEqual(reply.get("__status"), 500, reply)
        text = "\n".join(logs.output)
        self.assertIn("evaluator_id=%s" % evaluator.id, text)
        self.assertNotIn(evaluator.access_token, text)

    def test_the_load_shed_warning_does_not_carry_the_token(self):
        from odoo.http import Request

        from ..controllers import load_shed

        token = uuid4().hex

        def _raises(_self):
            raise PoolError("The Connection Pool Is Full")

        class _Req:
            httprequest = type(
                "H", (), {"path": "/api/v1/exam/%s/answer" % token})()

        with patch.object(Request, "_serve_db", _raises):
            wrapped = Request._serve_db
            try:
                load_shed._install()
                with self.assertLogs(load_shed._logger.name,
                                     "WARNING") as logs:
                    response = Request._serve_db(_Req())
            finally:
                Request._serve_db = wrapped

        self.assertEqual(response.status_code, 503)
        text = "\n".join(logs.output)
        self.assertIn("/exam/<redacted>/answer", text)
        self.assertNotIn(token, text)
