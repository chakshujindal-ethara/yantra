# -*- coding: utf-8 -*-
"""Shared harness for the offset-paging tests: a request stub and a page walker.

NOT a test module. `tests/__init__.py` deliberately does not import it - Odoo
loads every module listed there as a test suite, and this one has no cases.

WHY A REQUEST STUB RATHER THAN HttpCase. Every route under test reads its
paging arguments off `request.params` and returns the `paged()` envelope as a
plain dict, so driving the shipped controller method with a stub tests the
route's own ordering decision. An HttpCase would add a bearer-token dance this
suite has no helper for and would be measuring werkzeug. This is the pattern
`test_task_template_api`, `test_admin_can_see_exam_media` and
`test_candidate_identity` already use.
"""
from unittest.mock import patch

from odoo.addons.assessments_be_v2.controllers.api import common as api_common

#: Hard stop on a walk, so a route whose `has_more` never clears cannot hang
#: the suite. Deliberately generous: a 500-row population at limit=1 is 500
#: pages and must still complete.
MAX_PAGES = 2000


class RequestStub:
    """The three things these routes and their helpers read off `request`.

    `env` for the ORM in the route bodies, `params` for `body()`/`int_arg()`/
    `str_arg()`/`paging()`, and `make_json_response` because `fail()` builds its
    envelope through it.
    """

    def __init__(self, env, params):
        self.env = env
        self.params = params

    def make_json_response(self, payload, headers=None, status=200):
        return {"__status": status, **payload}


def call_route(module, controller, method, env, path=None, **params):
    """Call a shipped route with a request stub.

    Both bindings are patched: the controller module's `request` is what the
    route body reads, `common.request` is what the decorators, the argument
    readers, `paging()` and `fail()` read.

    `path` carries the URL components Odoo would pass as keyword arguments
    (`assessment_id`, `kind`, `record_id`); everything else travels in the
    request body, which is where json2 puts filters and paging.
    """
    path = dict(path or {})
    fake = RequestStub(env, {**path, **params})
    with patch.object(module, "request", fake), \
            patch.object(api_common, "request", fake):
        return getattr(controller, method)(**path)


def status_of(response):
    """`ok()`/`paged()` return a bare dict (HTTP 200); `fail()` carries its
    status through the stub's `make_json_response`."""
    return response.get("__status", 200)


def walk(page_call, limit, id_key="id"):
    """Walk an offset-paged route from 0 and return (ids, pages, last_meta).

    `page_call(limit, offset)` must return the `paged()` envelope. This is the
    walk `app_store.dart:1033 _loadAttempts()` performs: fetch a page, append
    its rows, advance the offset by the page size, stop when `has_more` clears.
    It does NOT de-duplicate - collecting duplicates is the whole point.
    """
    ids = []
    offset = 0
    pages = 0
    meta = {"total": 0, "limit": limit, "offset": 0, "has_more": False}
    while pages < MAX_PAGES:
        response = page_call(limit, offset)
        assert status_of(response) == 200, response
        rows = response["data"]
        meta = response["meta"]
        ids.extend(row[id_key] for row in rows)
        pages += 1
        if not rows or not meta["has_more"]:
            break
        offset += limit
    return ids, pages, meta


def losses(ids, population_ids):
    """(duplicated ids, ids never returned) for one walk. The counterexample."""
    seen = {}
    for rid in ids:
        seen[rid] = seen.get(rid, 0) + 1
    duplicated = sorted(rid for rid, n in seen.items() if n > 1)
    missing = sorted(set(population_ids) - set(ids))
    return duplicated, missing
