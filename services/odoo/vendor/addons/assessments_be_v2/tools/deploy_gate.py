#!/usr/bin/env python3
"""Refuse a rollout while somebody is sitting an exam (SNo 144).

WHY THIS IS A GATE AND NOT A NOTE IN THE RUNBOOK. Upgrading this module
restarts the workers and runs migrations. A candidate mid-sitting loses their
connection at best; at worst a schema step holds a lock on the table their next
answer writes to, their save fails, and the clock keeps running. Nothing about
that is recoverable afterwards - an exam is not a job that can be retried, and
the candidate is the one who pays.

The deploy checklist already says "do not upgrade while any assessment is in
progress" (SNo 80). A sentence in a checklist is advisory at 9pm on a Friday;
this is the same sentence with an exit code.

HOW TO WIRE IT. One step, before the module upgrade:

    python3 tools/deploy_gate.py            # exits 1 while a sitting is live
    python3 tools/deploy_gate.py --wait 900 # or wait up to 15 minutes for it

    ETP_BASE_URL / ETP_DB / ETP_LOGIN / ETP_PASSWORD as everywhere else.
    ETP_LOGIN must be an assessments Admin (`group_assessment_manager`):
    `/api/v1/scoring` is Admin-only, so a Manager login gets 403 there and
    the gate exits 2 on every deploy.

A GRADING RUN BLOCKS TOO: `/api/v1/scoring` showing `lanes.scoring > 0` means
a lane is mid-call, and a restart throws that paid call away.

WHAT COUNTS AS LIVE, and why it is narrower than "an assessment is open". An
assessment in `in_progress` with nobody actually sitting it is not a reason to
block a deploy - launched papers stay open for days, and a gate that refused for
the whole window would be turned off within a week. What blocks is an ATTEMPT
that has started and not finished: `started_at` set, not submitted, not locked.
That is the set of people who would actually lose something.

EXIT CODES, so CI can branch on them:

    0  nothing is being sat or graded; safe to roll
    1  at least one sitting is live, or a grading lane is running
    2  could not tell - auth failed, route missing, server unreachable

TWO IS NOT ZERO, deliberately. A gate that cannot reach the server has not
established that the deploy is safe, and "the check broke so we shipped" is how
a gate becomes theatre. Failing closed costs a human thirty seconds; failing
open costs a candidate their exam.
"""
import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("ETP_BASE_URL", "http://localhost:8069").rstrip("/")
DB = os.environ.get("ETP_DB", "etp_local")
LOGIN = os.environ.get("ETP_LOGIN", "admin")
PASSWORD = os.environ.get("ETP_PASSWORD", "admin")

CTX = ssl.create_default_context()


def bearer():
    body = urllib.parse.urlencode(
        {"login": LOGIN, "password": PASSWORD, "db": DB}).encode()
    req = urllib.request.Request(
        BASE + "/api/v1/auth_token", data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=30, context=CTX) as r:
        return json.loads(r.read().decode())["data"]["access_token"]


def api(tok, path, payload=None):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(payload or {}).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + tok})
    with urllib.request.urlopen(req, timeout=120, context=CTX) as r:
        return json.loads(r.read().decode())


def live_sittings(tok):
    """Attempts started and not finished, across every assessment.

    Paged: the roster of a large programme runs to thousands, and a gate that
    only looked at the first page would wave a deploy through over the very
    cohort it exists to protect.
    """
    live, offset = [], 0
    while offset < 50000:
        body = api(tok, "/api/v1/attempts", {"limit": 200, "offset": offset})
        rows = body.get("data") or []
        if not rows:
            break
        for r in rows:
            if not r.get("started_at"):
                continue
            if r.get("submitted_at") or r.get("is_locked"):
                continue
            if str(r.get("state")) in ("submitted", "expired"):
                continue
            live.append(r)
        meta = body.get("meta") or {}
        if not meta.get("has_more"):
            break
        offset += 200
    return live


def grading_lanes(tok):
    """Candidates a grading lane holds right now (`lanes.scoring`)."""
    lanes = (api(tok, "/api/v1/scoring").get("data") or {}).get("lanes") or {}
    return int(lanes.get("scoring") or 0)


def check(tok):
    live = live_sittings(tok)
    grading = grading_lanes(tok)
    if grading:
        print("deploy gate: BLOCKED - %d candidate(s) being graded "
              "(/api/v1/scoring lanes.scoring)" % grading)
    if not live:
        if grading:
            return 1
        print("deploy gate: OK - no sitting or grading is in progress")
        return 0
    print("deploy gate: BLOCKED - %d sitting(s) in progress" % len(live))
    for r in live[:10]:
        who = (r.get("candidate") or {})
        print("  %-34s %-28s started %s"
              % (str(who.get("name") or "?")[:34],
                 str(r.get("assessment_name") or "?")[:28],
                 r.get("started_at")))
    if len(live) > 10:
        print("  ... and %d more" % (len(live) - 10))
    return 1


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wait", type=int, default=0, metavar="SECONDS",
                    help="poll until every sitting finishes, or give up")
    ap.add_argument("--every", type=int, default=30, metavar="SECONDS",
                    help="how often to re-check while waiting")
    args = ap.parse_args()

    try:
        tok = bearer()
    except Exception as exc:                                    # noqa: BLE001
        print("deploy gate: CANNOT TELL - could not authenticate against %s "
              "(%s). Refusing rather than assuming: an unreachable check has "
              "established nothing." % (BASE, type(exc).__name__))
        return 2

    deadline = time.time() + args.wait
    while True:
        try:
            rc = check(tok)
        except Exception as exc:                                # noqa: BLE001
            print("deploy gate: CANNOT TELL - %s while reading /attempts or "
                  "/scoring (%s)"
                  % (type(exc).__name__, str(exc)[:120]))
            return 2
        if rc == 0 or time.time() >= deadline:
            if rc != 0 and args.wait:
                print("deploy gate: still blocked after %ds" % args.wait)
            return rc
        time.sleep(max(5, args.every))


if __name__ == "__main__":
    sys.exit(main())
