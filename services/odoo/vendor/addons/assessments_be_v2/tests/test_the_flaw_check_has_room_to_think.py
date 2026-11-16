# -*- coding: utf-8 -*-
"""The planted-flaw check must fit a THINKING model's thoughts on its first try.

Local ledger, 2026-09-29: `verify_planted_flaws` at max_tokens=4000 on
gemini-3.1-pro-preview spent 3,837 tokens thinking + 149 output and stopped on
MAX_TOKENS; its retry used 6,178 thoughts, so every check was paid for twice.
Same fix, and the same pin, as `draft_task_template_from_sop`
(test_draft_task_template).
"""
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from ..services import vertex


@tagged("-at_install", "post_install")
class TestTheFlawCheckHasRoomToThink(TransactionCase):

    def test_the_first_call_fits_the_thoughts_and_a_retry_gets_more(self):
        with patch.object(vertex, "_call_vertex", return_value=(
                '[{"flaw": "a smudge", "present": true, "note": ""}]'
        )) as call:
            out = vertex.verify_planted_flaws(
                self.env, b"png", ["a smudge"],
                model="gemini-3.1-pro-preview")

        kwargs = call.call_args.kwargs
        self.assertGreaterEqual(kwargs["max_tokens"], 12000)
        retry = (kwargs.get("retry_max_tokens")
                 or vertex._RETRY_OUTPUT_TOKENS_CEILING)
        self.assertGreater(retry, kwargs["max_tokens"])
        self.assertTrue(out["all_present"])
