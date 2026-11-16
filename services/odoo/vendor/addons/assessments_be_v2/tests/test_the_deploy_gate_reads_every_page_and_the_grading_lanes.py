# -*- coding: utf-8 -*-
"""S14: `tools/deploy_gate.py` pages through every attempt (the API says
`has_more`, not `hasMore`) and refuses a deploy while a grading lane runs."""
import importlib.util
import os
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged


def _gate():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(here, "tools", "deploy_gate.py")
    spec = importlib.util.spec_from_file_location("deploy_gate", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = _gate()
DONE = {"started_at": "2026-09-20 10:00:00",
        "submitted_at": "2026-09-20 11:00:00"}
LIVE = {"started_at": "2026-09-23 09:00:00", "submitted_at": False,
        "is_locked": False, "state": "in_progress", "candidate": {"name": "X"}}


@tagged("-at_install", "post_install")
class TestTheDeployGateReadsEveryPage(TransactionCase):

    def _check(self, pages, scoring=0):
        asked = []

        def api(_tok, path, payload=None):
            asked.append((path, payload))
            if path == "/api/v1/scoring":
                return {"ok": True, "data": {"lanes": {"scoring": scoring}}}
            page = payload["offset"] // 200
            return {"ok": True, "data": pages[page], "meta": {
                "has_more": page + 1 < len(pages)}}
        with patch.object(gate, "api", api):
            return gate.check("tok"), asked

    def test_a_sitting_past_the_first_page_blocks_the_deploy(self):
        rc, asked = self._check([[DONE] * 200, [DONE, LIVE]])
        self.assertEqual(rc, 1)
        self.assertEqual([p["offset"] for path, p in asked
                          if path == "/api/v1/attempts"], [0, 200])

    def test_a_running_grading_lane_blocks_the_deploy(self):
        self.assertEqual(self._check([[DONE]], scoring=2)[0], 1)

    def test_nothing_sat_and_nothing_graded_lets_it_through(self):
        self.assertEqual(self._check([[DONE] * 200, [DONE]])[0], 0)
