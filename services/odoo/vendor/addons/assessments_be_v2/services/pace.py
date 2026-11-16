# -*- coding: utf-8 -*-
"""Time analysis for a sitting: how long it took, the paper's median, a pace tag.

The server owns the median. The admin console used to work it out from whatever
attempts the browser happened to have cached, so an attempt opened by direct link
was compared with itself. One helper serves the attempt detail route and the
Results export, so the two cannot disagree.
"""
from decimal import ROUND_HALF_UP, Decimal

from ..constants import PACE_FAST_AT_OR_BELOW, PACE_SLOW_AT_OR_ABOVE


def span_seconds(started_at, submitted_at, deadline=None):
    """Whole seconds a sitting ran, or None when there is no usable span.

    The span runs from ``started_at`` to the EARLIER of ``submitted_at`` and
    ``deadline`` (the evaluator's ``deadline_datetime``); with no deadline, to
    ``submitted_at``. The cap is not optional: ``submitted_at`` is stamped when a
    sitting is SETTLED, not when it ended, so a paper that expired and was
    settled later (by the cron, or on the candidate's next visit) is stamped
    after the deadline it actually ended on. Counting that delay would inflate
    "time taken", drag the median, and tag people Slow for a wait that was not
    theirs. Either end missing, or a span that is not positive, is no span.
    This is the ONE place the rule lives: the median, `time_taken_minutes` and
    `pace` all come through here.
    """
    if not (started_at and submitted_at):
        return None
    end = min(submitted_at, deadline) if deadline else submitted_at
    seconds = int((end - started_at).total_seconds())
    return seconds if seconds > 0 else None


def median_seconds(assessment):
    """The median sitting length of ``assessment`` in whole seconds, or None.

    One read of three columns for every sitting of the paper, not one per
    evaluator. Each sitting's span is capped at its deadline (`span_seconds`).
    Read as sudo on purpose: the median is a property of the paper, and a
    record rule that narrows what the caller may open must not narrow it.
    Even count: ``(a + b + 1) // 2`` of the two middles, which is how the client
    rounds.
    """
    rows = assessment.env["assessments.be.evaluator"].sudo().search_fetch(
        [("assessment_id", "=", assessment.id),
         ("started_at", "!=", False), ("submitted_at", "!=", False)],
        ["started_at", "submitted_at", "deadline_datetime"])
    spans = sorted(
        s for s in (span_seconds(r.started_at, r.submitted_at,
                                 r.deadline_datetime) for r in rows)
        if s)
    if not spans:
        return None
    mid = len(spans) // 2
    if len(spans) % 2:
        return spans[mid]
    return (spans[mid - 1] + spans[mid] + 1) // 2


def minutes(seconds):
    """``seconds`` as minutes to one decimal (half up), or "" when there is none."""
    if not seconds:
        return ""
    return float((Decimal(seconds) / 60).quantize(
        Decimal("0.1"), rounding=ROUND_HALF_UP))


def pace(taken_seconds, median):
    """``Fast``, ``Normal`` or ``Slow``; "" without a time or a median.

    The ratio is rounded half up to two decimals BEFORE it meets the cut-offs,
    in Decimal, so the rule is exact and is the same half-up rule the client
    uses. A float ``round()`` is half-to-even and does tie differently in
    general, but it never changes a tag at 0.75 or 1.25: checked for every
    whole-second pair up to a 1,499 s median.
    """
    if not (taken_seconds and median):
        return ""
    ratio = (Decimal(taken_seconds) / Decimal(median)).quantize(
        Decimal("0.01"), rounding=ROUND_HALF_UP)
    if ratio <= Decimal(str(PACE_FAST_AT_OR_BELOW)):
        return "Fast"
    if ratio >= Decimal(str(PACE_SLOW_AT_OR_ABOVE)):
        return "Slow"
    return "Normal"
