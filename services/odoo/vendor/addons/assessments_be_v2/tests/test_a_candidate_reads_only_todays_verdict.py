# -*- coding: utf-8 -*-
"""apc-3 / swe-flutter-4 - a candidate sees only verdicts the current
instructions wrote.

Candidates see the grader's verdict on released answers. Verdicts written
under the OLD instructions were meant for admins ("`feedback` IS THE ONLY THING
YOU WRITE THAT THE CANDIDATE READS"), so they may name profiles, caps,
thresholds or point arithmetic.

`llm_prompt_version` records exactly which instructions graded an answer, so
the gate is one comparison, behind
`assessments_be_v2.verdict_requires_current_prompt` (default ON; never switched
off as a deploy step, `ETP_PLANS_AND_STRATEGY.md` Part 5 §5.2).

THE KEY IS NEVER DROPPED: a withheld verdict is the empty string, which the app
renders as "no verdict".
"""
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import serializers as S
from ..services import scoring as scoring_svc
from .test_individual_scoring_stays_individual import _Paper

#: Spelled out rather than read off the module: the NAME is the contract an
#: operator types into Settings, so a rename has to fail here.
_PARAM = "assessments_be_v2.verdict_requires_current_prompt"


@tagged("-at_install", "post_install")
class TestOnlyCurrentVerdictsReachACandidate(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()
        self.ev = self._candidate(1, scored={0: 80})
        self.answer = self._answers(self.ev)[0]
        self.answer.write({
            "llm_verdict": "Meets the bar on profile B, 2 of 3 checks.",
            "llm_feedback": "Good structure; say more about trade-offs.",
        })
        self.ev.results_released = True

    def _row(self):
        return S.released_answer_review_row(
            1, self.answer.question_id, self.answer, "tok")

    def test_a_verdict_from_the_old_instructions_is_withheld(self):
        self.assertEqual(self.answer.llm_prompt_version, "bundled:0ld0ld00")
        row = self._row()
        self.assertEqual(
            row["score_verdict"], "",
            "a verdict written for an admin was sent to the candidate")
        self.assertIn("score_verdict", row,
                      "older app builds read this key unconditionally")
        self.assertTrue(row["feedback"],
                        "feedback was always candidate-facing")

    def test_a_verdict_from_the_current_instructions_is_sent(self):
        self.answer.llm_prompt_version = \
            scoring_svc.current_scoring_prompt_version()
        self.assertEqual(self._row()["score_verdict"],
                         "Meets the bar on profile B, 2 of 3 checks.")

    def test_an_unversioned_verdict_is_withheld(self):
        self.answer.llm_prompt_version = False
        self.assertEqual(self._row()["score_verdict"], "")

    def test_the_switch_turns_the_gate_off(self):
        self.env["ir.config_parameter"].sudo().set_param(_PARAM, "0")
        self.assertEqual(self._row()["score_verdict"],
                         "Meets the bar on profile B, 2 of 3 checks.")

    def test_the_gate_is_on_when_nothing_is_configured(self):
        self.env["ir.config_parameter"].sudo().search(
            [("key", "=", _PARAM)]).unlink()
        self.assertEqual(self._row()["score_verdict"], "")
