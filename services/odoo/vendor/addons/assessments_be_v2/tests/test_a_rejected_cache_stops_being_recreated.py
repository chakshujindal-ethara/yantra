# -*- coding: utf-8 -*-
"""A grading cache Vertex refuses is not created again for the next candidate.

When a cached call comes back 404, or 400/403 mentioning the cache, the row is
expired and the call goes inline - correct, and free. But `forget()` wrote only
`expires_at`, so the NEXT candidate of the same question group found no live
cache, `create=True` and no backoff: it paid for a fresh create that Vertex
rejected exactly the same way, once per candidate, in silence (every candidate
still scored). At ~7k-token groups that is roughly $15 of pure waste on a
704-candidate paper, with the round trip doubled.

`failed_until` is the backoff a failed CREATE already gets and `_resolve`
already honours it, so the only thing missing was writing it. A row that had
genuinely run out of time is left alone: re-creating that one is right.
"""
from datetime import timedelta
from types import SimpleNamespace
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from ..services import grading_cache


@tagged("-at_install", "post_install")
class TestARejectedCacheStopsBeingRecreated(TransactionCase):

    def _row(self, expires_in):
        now = fields.Datetime.now()
        return self.env["assessments.be.scoring.cache"].sudo().create({
            "key": uuid4().hex,
            "resource_name": "cachedContents/%s" % uuid4().hex[:8],
            "model": "gemini-3.1-pro-preview",
            "location": "global",
            "token_count": 5000,
            "created_at": now,
            "expires_at": now + expires_in,
        })

    def test_a_cache_rejected_while_live_backs_the_group_off(self):
        row = self._row(timedelta(seconds=grading_cache.TTL_SECONDS))

        grading_cache.forget(
            self.env, SimpleNamespace(key=row.key), row.resource_name)

        now = fields.Datetime.now()
        self.assertTrue(
            grading_cache._failed(row, now),
            "the next candidate must grade inline instead of paying for a "
            "create that will be rejected the same way")
        self.assertFalse(grading_cache._live(row, now))

    def test_a_cache_that_simply_ran_out_of_time_is_not_penalised(self):
        row = self._row(-timedelta(seconds=30))

        grading_cache.forget(
            self.env, SimpleNamespace(key=row.key), row.resource_name)

        self.assertFalse(
            grading_cache._failed(row, fields.Datetime.now()),
            "an expiry is not a rejection - that key may be created again")
