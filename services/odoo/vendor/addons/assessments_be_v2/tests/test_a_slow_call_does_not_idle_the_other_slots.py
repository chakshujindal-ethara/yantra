# -*- coding: utf-8 -*-
"""A lane stores whichever candidate comes back first.

`_drain_in_parallel` kept up to `workers` candidates on the wire and then
drained them strictly oldest-first - `in_flight.popleft()` followed by
`pending.result()`. One slow call therefore idled every other slot behind it:
the stress harness measured 73% slot use against an ideal 100%, which is most
of the gap between the planned 35-45 minutes for a 704-candidate paper and the
54-62 it models at.

Storing whoever is ready is safe because candidates do not depend on each
other: each is written inside its own savepoint and committed on its own.
"""
from concurrent.futures import Future
from collections import deque
from types import SimpleNamespace

from odoo.tests.common import TransactionCase, tagged

from ..models.assessment import _pop_first_ready


def _run(*futures):
    return SimpleNamespace(pending=[(None, f) for f in futures])


@tagged("-at_install", "post_install")
class TestASlowCallDoesNotIdleTheOtherSlots(TransactionCase):

    def test_the_ready_candidate_is_stored_before_the_slow_one(self):
        slow, quick = Future(), Future()
        quick.set_result(("results", None))
        in_flight = deque([("oldest", _run(slow)), ("quick", _run(quick))])

        ev, run = _pop_first_ready(in_flight)

        self.assertEqual(ev, "quick",
                         "the oldest call is still out; its slot must not "
                         "hold up a candidate that is already back")
        self.assertEqual([e for e, _r in in_flight], ["oldest"])

    def test_a_candidate_is_only_ready_when_all_its_calls_are(self):
        half, rest = Future(), Future()
        half.set_result(("results", None))
        whole = Future()
        whole.set_result(("results", None))
        in_flight = deque([("split", _run(half, rest)), ("whole", _run(whole))])

        ev, _run_back = _pop_first_ready(in_flight)

        self.assertEqual(ev, "whole")

    def test_a_candidate_with_nothing_dispatched_is_ready(self):
        in_flight = deque([("nothing to send", _run())])
        ev, _run_back = _pop_first_ready(in_flight)
        self.assertEqual(ev, "nothing to send")
