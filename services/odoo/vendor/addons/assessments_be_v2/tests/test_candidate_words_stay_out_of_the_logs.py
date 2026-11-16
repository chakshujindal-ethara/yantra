# -*- coding: utf-8 -*-
"""What a candidate wrote, and who they are, never reaches the server log.

`services/audit.py` states the rule: names and email addresses stay out of the
log store several teams can read. Four lanes broke it.

  (a) The positive-deduction WARNING logged the judge's free-text `reason`,
      and `prompts/scoring.md` tells the judge to QUOTE the worker in it
      ("missed 'navy velvet sofa' (wrote 'a blue couch')").
  (b) `_parse_results` raised with `text[:200]` of the reply and the refusal
      detector carried `t[:200]`; both are logged at ERROR with a traceback -
      and land in candidate-visible `llm_feedback` besides.
  (c) VIOLATION lines logged the candidate's name and the assessment's name,
      during live sittings.
  (d) Provisioning lines logged the name and the email address.

Ids and lengths say everything an operator needs; the excerpt stays in the
admin-only `llm_reasoning`.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc

_SCORING = "odoo.addons.assessments_be_v2.services.scoring"
_MODEL = "odoo.addons.assessments_be_v2.models.assessment"

_PII = "Priya Sharma"
_EMAIL = "priya@example.com"


@tagged("-at_install", "post_install")
class TestCandidateWordsStayOutOfTheLogs(TransactionCase):

    def test_a_positive_deduction_logs_its_points_not_its_reason(self):
        item = {"id": 4172, "score": 60, "deductions": [
            {"points": 25, "reason": "wrote 'my name is %s, %s'"
                                     % (_PII, _EMAIL),
             "evidence": _PII}]}

        with self.assertLogs(_SCORING, level="WARNING") as logged:
            scoring_svc._recompute_deductions(item)

        line = [l for l in logged.output if "POSITIVE deduction" in l][0]
        self.assertNotIn(_PII, line)
        self.assertIn("resp=4172", line)

    def test_an_unparseable_reply_is_reported_by_length(self):
        reply = "sorry, I think %s wrote: my email is %s" % (_PII, _EMAIL)
        with self.assertRaises(ValueError) as caught:
            scoring_svc._parse_results(reply)
        self.assertNotIn(_PII, str(caught.exception))
        self.assertIn(str(len(reply)), str(caught.exception))

    def test_a_refusal_is_reported_by_length(self):
        text = "I cannot fulfill this - the answer names %s <%s>" % (
            _PII, _EMAIL)
        message = vertex_svc._detect_refusal_text(text)
        self.assertTrue(message)
        self.assertNotIn(_PII, message)
        self.assertNotIn(_EMAIL, message)

    def test_a_violation_line_carries_ids_not_a_name(self):
        paper = self.env["assessments.be"].create(
            {"name": "Sitting %s" % uuid4().hex[:6]})
        applicant = self.env["hr.applicant"].create(
            {"partner_name": _PII, "email_from": _EMAIL})
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id})

        with self.assertLogs(_MODEL, level="WARNING") as logged:
            ev._record_violation("tab_switch")

        line = [l for l in logged.output if "VIOLATION" in l][0]
        self.assertNotIn(_PII, line)
        self.assertIn("evaluator=%s" % ev.id, line)
        self.assertIn("applicant=%s" % applicant.id, line)
