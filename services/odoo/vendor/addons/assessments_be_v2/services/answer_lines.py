# -*- coding: utf-8 -*-
"""Moving a stored answer's chosen options to a new set, writing only the diff.

WHY THIS IS A SERVICE AND NOT A CONTROLLER HELPER. It used to live at module
level in `controllers/portal.py` and be imported OUT of there by
`controllers/api/candidate.py` - one controller reaching into another for its
core write rule. That made the QWeb runner load-bearing for the JSON API: the
import was function-local, so deleting the portal would not have failed at
install time, it would have failed at REQUEST time, as a 500 on every answer
save. Neither controller owns this rule. It touches no `request`, only records,
so it belongs beside the other record-level rules in `services/`.

There is exactly one implementation on purpose. Two versions of "which option
rows should this answer hold" is how one runner ends up storing a candidate's
answer differently from the other, on the same question.
"""


def reconcile_response_lines(response, line_vals):
    """Move `response.line_ids` to exactly `line_vals`, writing only the diff.

    WHY NOT `unlink()` THEN RE-ADD, which is what this replaced: deleting every
    line and re-inserting the same ones makes each save write rows a sibling
    save is reading, so two posts of the SAME answer collide in Postgres with
    "could not serialize access due to concurrent delete". A runner posts an
    answer more than once by design - an autosave and every navigation - so the
    two writers are the normal path, not an edge case. At 588 concurrent
    candidates on 2026-09-03 that exhausted Odoo's five retries and surfaced as
    a 500 on a third of all answer saves.

    Re-posting an UNCHANGED answer now writes NOTHING - no delete, no insert,
    so no row for a sibling to collide with. That is what the return value
    reports, and `test_resaving_an_answer_writes_only_the_diff` pins it.

    A FUNCTION, NOT A METHOD ON THE RESPONSE MODEL. The caller has two update
    sites - the normal path and the IntegrityError fold, where a sibling request
    won the unique index and is writing this very payload - and both need it
    before they hold a settled recordset to call a method on.
    """
    wanted = {
        (vals["question_dimension_id"], vals["selected_option_id"])
        for _cmd, _id, vals in line_vals
    }
    held = {
        (line.question_dimension_id.id, line.selected_option_id.id): line.id
        for line in response.line_ids
    }
    stale = [line_id for key, line_id in held.items() if key not in wanted]
    fresh = [
        (0, 0, {"question_dimension_id": dimension_id,
                "selected_option_id": option_id})
        for dimension_id, option_id in sorted(wanted - set(held))
    ]
    if stale:
        # `response.env`, NOT `request.env`: this helper is called from a
        # controller and from tests, and only the controller has a request.
        response.env["assessments.be.response.line"].sudo().browse(
            stale).unlink()
    if fresh:
        response.write({"line_ids": fresh})
    return bool(stale or fresh)


# The controllers imported it under a leading underscore while it lived in
# `controllers/portal.py`. Kept working so a stale import site fails loudly at
# the name rather than silently resolving to something else.
_reconcile_response_lines = reconcile_response_lines
