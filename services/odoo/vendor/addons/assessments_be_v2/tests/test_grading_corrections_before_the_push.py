# -*- coding: utf-8 -*-
"""Small grading corrections: the prompt-writing mark (N2), the SOP claim (N3),
the verdict gate's failure log (N10) and the worker-facing wording (Q19)."""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import tagged

from ..controllers.api import serializers
from ..services import scoring as scoring_svc
from .test_the_grader_is_sent_only_what_it_marks_against import _Base

_TEN_OFF = [{"points": -10, "reason": "missed %s" % e, "evidence": "-"}
            for e in ("sofa", "lamp", "rug")]


@tagged("-at_install", "post_install")
class TestGradingCorrectionsBeforeThePush(_Base):

    def test_prompt_writing_is_not_capped_for_missed_elements(self):
        """R3-01: 100 x hits / elements already costs each miss; the 55 cap
        on top turned a 70 into a 55."""
        for qtype, mark in (("image_prompt", 70.0), ("video_prompt", 70.0),
                            ("subjective_rubric", 55.0)):
            with self.subTest(qtype=qtype):
                question = (self._written() if qtype == "subjective_rubric"
                            else self._prompt_writing(qtype))
                resp = self._grade(self._answer(question), score=70,
                                   deductions=_TEN_OFF,
                                   checklist_zero_count=3)
                self.assertEqual(resp.llm_raw_100, mark)

    def test_only_the_sop_title_claims_rules(self):
        """B3-06: Q122's Form Studio generator is named "... Q7r ..." with no
        SOP title, which flagged every written answer under it."""
        form = self.env["assessments.be.prompt"].create({
            "name": "Form: Q7r + Grade & Fix %s" % uuid4().hex[:6]})
        question = self._written(form)
        self.assertEqual(scoring_svc._grading_rules(question), ("GENERAL", []))

        form.sop_title = "Q7r defect annotation"
        self.assertEqual(scoring_svc._grading_rules(question),
                         ("GENERAL", ["profile_mismatch"]))

    def test_a_failed_verdict_gate_is_logged_and_withholds(self):
        """R9-07: the gate withheld verdicts without a trace."""
        resp = self._answer(self._written())
        resp.llm_prompt_version = "bundled:00000000"
        with patch.object(scoring_svc, "current_scoring_prompt_version",
                          side_effect=OSError("prompt unreadable")), \
                self.assertLogs(serializers.__name__, "WARNING") as logs:
            self.assertFalse(
                serializers._verdict_is_for_current_instructions(resp))
        self.assertIn("verdict gate check failed", logs.output[0])
        # N10: one line per answer, not a traceback.
        self.assertIn("OSError: prompt unreadable", logs.output[0])
        self.assertNotIn("Traceback", logs.output[0])

    def test_the_worker_facing_fields_use_plain_words(self):
        text = scoring_svc._get_scoring_prompt()
        self.assertIn("Deduction and credit reasons are read by the worker",
                      text)
        self.assertIn('say "invented details"', text)
