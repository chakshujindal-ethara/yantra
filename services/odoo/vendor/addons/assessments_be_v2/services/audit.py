# -*- coding: utf-8 -*-
"""One structured line per candidate lifecycle event.

WHY A LOG LINE AND NOT A TABLE. The cohort this was built for is 650 people
answering at once, and the answer path is already the whole write budget:
`_update_response` exists because ONE extra UPDATE on that row turned into a
500 on a third of every save during the 2026-09-03 sitting. An audit ROW would
put an INSERT on exactly that path, thousands of times a minute, on the table
nobody may slow down - so there is no model here, no `ir.model.access` row and
no migration. A log line costs no SQL, no lock and no connection, and the
platform it lands in already indexes it:

    {container="etp-be"} |= "ETP_AUDIT" | json

That is also why it is observable the moment the pods restart, rather than
after an upgrade.

WHAT A LINE DELIBERATELY DOES NOT CARRY:

  * the exam token - it is a CAPABILITY. Anyone holding it can sit the paper,
    and the access log already leaks enough of them (see the password-reset
    tokens sitting in cleartext in Loki today). An attempt is named by its
    integer id instead, which is useless without database access and is what
    every table joins on anyway;
  * the answer text, the justification and any option the candidate picked;
  * the candidate's name, email and login. `cand` (hr.applicant id) and `uid`
    (res.users id) identify a person to anyone entitled to look them up, and
    to nobody else. An operator holding a complaining candidate's email looks
    the applicant up in Odoo - one extra step, in exchange for no PII in a log
    aggregator that several teams can read.

EMISSION NEVER RAISES. `emit` is called from the middle of the exam runner, so
a bad format argument, or a record deleted under us, must cost an audit line
and nothing else - never the candidate's answer.

EVERY FIELD READ HERE IS ALREADY IN THE ORM CACHE. `evaluator.assessment_id`
and `.applicant_id` are stored columns of a row each call site has already
read, and `.id` on a Many2one never loads the target record, so an event adds
no query to the request.
"""
import json
import logging
import socket
import time

from odoo.http import request

_logger = logging.getLogger(__name__)

#: The grep anchor. Never change it without changing every dashboard.
PREFIX = "ETP_AUDIT "

#: Resolved once at import: on Kubernetes the container hostname IS the pod
#: name, so this joins a line to a pod without a Loki label lookup - and the
#: pods are replaced often enough (six in twelve hours) that it matters.
POD = socket.gethostname()

#: Hard ceiling on the one free-text field a line can carry. An error message
#: can be a whole traceback frame; a log line that grows with its input is how
#: an error becomes an outage.
MAX_ERR = 160


def start():
    """Monotonic mark to pass back as ``t0``. Never a wall clock: a clock step
    mid-request would report a negative duration."""
    return time.monotonic()


def err_sig(error):
    """A bounded, low-cardinality signature: ``ExceptionType: first line``.

    Low cardinality is the point - the signature is what a Loki panel groups
    by, so it must be the same string for every instance of one defect.
    """
    if isinstance(error, str):
        return error[:MAX_ERR]
    text = (str(error) or "").strip().split("\n", 1)[0]
    return ("%s: %s" % (type(error).__name__, text))[:MAX_ERR]


def request_id():
    """An id shared by every event of one HTTP request, or "" off-request.

    Derived from the request object's identity rather than a generated uuid:
    it is stable for the life of the request, unique among the requests in
    flight on this pod, and costs no allocation on a path that runs thousands
    of times a minute. `pod` and the timestamp disambiguate a reused address.

    An ingress-supplied `X-Request-Id` wins when there is one, so a line can be
    joined to the edge. There is none today - the mesh does TCP passthrough
    and emits no L7 telemetry at all - which is half the reason this file
    exists.
    """
    if not request:
        return ""
    req = request.httprequest
    return (req.headers.get("X-Request-Id") or "")[:40] \
        or "%012x" % (id(req) & 0xFFFFFFFFFFFF)


def emit(event, evaluator=None, outcome="ok", t0=None, error=None, **fields):
    """Write one ETP_AUDIT line. Returns nothing and raises nothing.

    ``evaluator`` is an ``assessments.be.evaluator`` record (the attempt) or
    None for events that are not about one sitting.
    """
    try:
        rec = {
            "ts": int(time.time() * 1000),
            "ev": event,
            "outcome": outcome,
            "rid": request_id(),
            "pod": POD,
        }
        if t0 is not None:
            rec["ms"] = int((time.monotonic() - t0) * 1000)
        if evaluator is not None:
            rec["attempt"] = evaluator.id
            rec["assess"] = evaluator.assessment_id.id
            rec["cand"] = evaluator.applicant_id.id
        if request:
            rec["uid"] = request.env.uid
        if error is not None:
            rec["err"] = err_sig(error)
        # STRUCTURAL KEYS WIN. `setdefault` rather than `update` so a caller
        # passing `ev=`, `outcome=`, `rid=` or `pod=` as an extra field adds a
        # value it cannot see instead of silently rewriting the one every
        # dashboard groups by - a mislabelled event is worse than a dropped one,
        # because nothing about it looks wrong.
        for key, value in fields.items():
            rec.setdefault(key, value)
        _logger.info(
            "%s%s", PREFIX,
            json.dumps(rec, separators=(",", ":"), default=str))
    except Exception:  # noqa: BLE001 - an audit line may never break a sitting
        # DEBUG, not WARNING: if the emitter is broken it is broken on every
        # request, and a warning per answer save is the log flood this whole
        # file is meant to make readable.
        _logger.debug("ETP_AUDIT emit failed for %s", event, exc_info=True)
