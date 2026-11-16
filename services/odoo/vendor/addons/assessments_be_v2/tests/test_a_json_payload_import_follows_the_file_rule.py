# -*- coding: utf-8 -*-
"""qa-backend-api-5 / swe-api-models-12 / apc-5 - one rule, two doors.

W9: imported questions land as DRAFTS in Pending Approvals. `POST
/api/v1/bank/import` with a JSON `payload` routes by SHAPE, asking the same
two predicates the file lane asks: a harness payload becomes drafts; a native
round-trip export restores into the bank (the one exemption - it restores
questions already approved here); any other shape is refused (422) before
anything is created. A caller's `native` flag cannot force a body into the
bank. Recorded in `docs/ETP_PLANS_AND_STRATEGY.md` §4.4.
"""
import json
from uuid import uuid4

from odoo.tests.common import HttpCase, tagged

_JSON = {"Content-Type": "application/json"}


def _harness_payload(title):
    return {"questions": [{
        "id": "q1",
        "instruction": title,
        "fields": {"question_type": "subjective_rubric",
                   "difficulty": "medium",
                   "official_reasoning": "Because."},
    }]}


@tagged("-at_install", "post_install")
class TestTheJsonPayloadLaneRoutesByShape(HttpCase):

    def setUp(self):
        super().setUp()
        self.authenticate("admin", "admin")

    def _import(self, body):
        response = self.url_open(
            "/api/v1/bank/import", data=json.dumps(body), headers=_JSON,
            timeout=30)
        return response.status_code, response.json()

    def _counts(self):
        return (self.env["assessments.be.question"].search_count([]),
                self.env["assessments.be.prompt.question"].search_count([]))

    def test_a_harness_payload_becomes_drafts(self):
        before_bank, before_drafts = self._counts()
        status, payload = self._import(
            {"payload": _harness_payload("Harness %s" % uuid4().hex[:6])})
        self.assertEqual(status, 200, payload)
        after_bank, after_drafts = self._counts()
        self.assertEqual(after_bank, before_bank,
                         "a harness import must not touch the live bank")
        self.assertGreater(after_drafts, before_drafts)

    def test_a_question_bank_payload_is_a_json_specific_refusal(self):
        """The shape that used to write straight into the live bank."""
        before_bank, before_drafts = self._counts()
        status, payload = self._import({"payload": {
            "project": {"name": "P"},
            "question_bank": [{"title": "Question 1",
                               "question_type": "subjective_rubric",
                               "prompt": "Describe"}],
        }})
        self.assertEqual(
            status, 422,
            "a shape neither importer owns created records: %s" % payload)
        self.assertEqual(payload["error"]["code"], "invalid_json_shape")
        self.assertIn("assessments_be_bank", payload["error"]["message"])
        self.assertEqual(self._counts(), (before_bank, before_drafts))

    def test_the_native_flag_cannot_force_a_harness_body_into_the_bank(self):
        before_bank, _drafts = self._counts()
        status, payload = self._import({
            "native": True,
            "payload": _harness_payload("Flagged %s" % uuid4().hex[:6]),
        })
        self.assertEqual(status, 200, payload)
        self.assertEqual(self._counts()[0], before_bank,
                         "the SHAPE decides, as it does for a file")

    def test_a_native_export_still_restores_into_the_bank(self):
        question = self.env["assessments.be.question"].create({
            "name": "Native %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Describe",
        })
        exported = json.loads(json.dumps(
            {"assessments_be_bank": "1", "questions": question._export_native()}
        ))
        question.unlink()
        before_bank, before_drafts = self._counts()
        status, payload = self._import({"payload": exported})
        self.assertEqual(status, 200, payload)
        after_bank, after_drafts = self._counts()
        self.assertGreater(after_bank, before_bank,
                           "the round-trip restore is the one exemption")
        self.assertEqual(after_drafts, before_drafts)

    def test_rubbish_is_refused_before_anything_is_created(self):
        before = self._counts()
        for body in ({"payload": {}}, {"payload": []},
                     {"payload": "not json at all"}, {"payload": None}):
            status, payload = self._import(body)
            self.assertEqual(status, 422, (body, payload))
        self.assertEqual(self._counts(), before)


@tagged("-at_install", "post_install")
class TestTheWizardLabelsTheFormatItDetected(HttpCase):
    """The single footer button said "Import as drafts" for every format,
    including the one that writes live questions."""

    def _wizard(self, text):
        import base64
        wizard = self.env["assessments.be.bank.import.wizard"].create({
            "data_file": base64.b64encode(text.encode()).decode(),
            "data_filename": "bank.json",
        })
        wizard._onchange_count()
        return wizard

    def test_a_native_export_is_labelled_native(self):
        wizard = self._wizard(json.dumps(
            {"assessments_be_bank": "1", "questions": [{"name": "Q"}]}))
        self.assertEqual(wizard.detected_format, "native")

    def test_a_harness_file_is_labelled_harness(self):
        wizard = self._wizard(json.dumps(_harness_payload("H")))
        self.assertEqual(wizard.detected_format, "harness")
        self.assertEqual(wizard.question_count, 1)

    def test_a_csv_file_is_labelled_csv(self):
        wizard = self._wizard("title,question_type,prompt\nQ,mcq,Pick one\n")
        self.assertEqual(wizard.detected_format, "csv")
        self.assertEqual(wizard.question_count, 1)
