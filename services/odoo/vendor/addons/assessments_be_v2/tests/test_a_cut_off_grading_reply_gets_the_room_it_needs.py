# -*- coding: utf-8 -*-
"""A grading reply that was CUT OFF is asked again with more room, and the
answers that still do not fit are graded at once in smaller calls.

`_call_vertex_single` retries only while `attempt_tokens < retry_ceiling`, so
the ceiling must sit above the first ask (a 20-item batch asks for 54,000):
  * the retry is DOUBLE the first ask, capped at the model's own `max_out`;
  * it fires only on a genuine cut-off - unparseable JSON already gets its one
    re-ask in `_grade_job`, and more tokens do not fix a reply that was never
    truncated;
  * when even the model's maximum is not enough, the answers that did not fit
    are re-graded at once in smaller calls instead of waiting for a cron tick
    (or, on the last attempt, landing terminal at 0).

Cost does not move unless a reply really was cut off: output tokens are billed
as generated, not as requested, and every branch above is behind a MAX_TOKENS.
"""
import json
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from ..services import model_catalog
from ..services import scoring as scoring_svc
from ..services import vertex as vertex_svc
from .test_individual_scoring_stays_individual import _Paper


@tagged("-at_install", "post_install")
class TestTheRetryCeiling(TransactionCase):

    def test_the_retry_is_double_the_first_ask(self):
        model = "gemini-3.1-pro-preview"
        self.assertEqual(scoring_svc._retry_output_tokens(model, 20000), 40000)

    def test_it_never_asks_for_more_than_the_model_can_return(self):
        model = "gemini-3.1-pro-preview"
        ceiling = model_catalog.max_output_tokens(model)
        self.assertTrue(ceiling, "the catalog knows this model's max_out")
        self.assertEqual(
            scoring_svc._retry_output_tokens(model, 54000), ceiling)

    def test_it_is_never_below_the_first_ask(self):
        model = "gemini-3.1-pro-preview"
        for first in (16000, 24000, 54000, 64000):
            self.assertGreaterEqual(
                scoring_svc._retry_output_tokens(model, first), first,
                "a ceiling under the first ask makes the retry dead code")


@tagged("-at_install", "post_install")
class TestACutOffReplyIsRecovered(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self._pin_settings()

    def _truncating_judge(self, fits):
        """Vertex, cut off: the first reply carries only ``fits`` results and
        finishes MAX_TOKENS; anything asked afterwards comes back whole."""
        calls = []

        def judge(env, system_prompt, user_text, **kw):
            items = json.loads(user_text[user_text.index('{"items"'):])["items"]
            ids = [int(it["id"]) for it in items]
            calls.append(ids)
            kw["served_model_out"].append("gemini-new-judge")
            if len(calls) == 1:
                kw["finish_out"].append("MAX_TOKENS")
                ids = ids[:fits]
            else:
                kw["finish_out"].append("STOP")
            return json.dumps({"results": [
                {"id": i, "score": 80} for i in ids]})
        return calls, patch.object(vertex_svc, "_call_vertex", judge)

    def test_the_answers_that_did_not_fit_are_graded_in_smaller_calls(self):
        asha = self._candidate(4, requested=True)
        calls, judge = self._truncating_judge(fits=2)

        with judge:
            asha._action_llm_score()

        self.assertEqual(len(calls[0]), 4, "one call for the batch")
        self.assertEqual(
            sorted(i for call in calls[1:] for i in call),
            sorted(calls[0][2:]),
            "only the answers the cut-off reply left out are re-sent")
        self.assertTrue(all(len(call) < 4 for call in calls[1:]),
                        "and they are re-sent in SMALLER calls")
        self.assertEqual(
            self._answers(asha).mapped("llm_state"), ["scored"] * 4,
            "every answer an admin asked about ends up scored")

    def test_a_whole_reply_costs_exactly_one_call(self):
        asha = self._candidate(4, requested=True)
        calls, judge = self._judge()
        with judge:
            asha._action_llm_score()
        self.assertEqual(len(calls), 1, "cost must not move on a healthy reply")

    def test_a_cut_off_reply_warns_with_the_ids_and_the_counts(self):
        asha = self._candidate(4, requested=True)
        _calls, judge = self._truncating_judge(fits=2)

        with judge, self.assertLogs(
                "odoo.addons.assessments_be_v2.services.scoring",
                level="WARNING") as logged:
            asha._action_llm_score()

        cut_off = [line for line in logged.output if "REPLY CUT OFF" in line]
        self.assertTrue(cut_off, "the rollout check needs this WARNING")
        self.assertIn("ev=%s" % asha.id, cut_off[0])
        self.assertIn("expected=4", cut_off[0])
        self.assertIn("recovered=2", cut_off[0])
        self.assertIn("finish=MAX_TOKENS", cut_off[0])

    def test_grading_does_not_re_ask_on_unparseable_json(self):
        """Vertex's own token-doubling retry is for a cut-off reply. Garbled
        JSON already gets ONE re-ask from `_grade_job`; asking Vertex for a
        second doubling on top is paying twice for the same problem."""
        asha = self._candidate(2, requested=True)
        seen = {}

        def judge(env, system_prompt, user_text, **kw):
            seen.update(kw)
            kw["served_model_out"].append("m")
            ids = [int(it["id"]) for it in json.loads(
                user_text[user_text.index('{"items"'):])["items"]]
            return json.dumps({"results": [
                {"id": i, "score": 80} for i in ids]})

        with patch.object(vertex_svc, "_call_vertex", judge):
            asha._action_llm_score()

        self.assertFalse(seen["json_retry"])
        self.assertGreaterEqual(seen["retry_max_tokens"], seen["max_tokens"])
