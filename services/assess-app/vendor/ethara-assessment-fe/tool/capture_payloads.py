#!/usr/bin/env python3
"""Capture live API payloads as test fixtures.

WHY THIS EXISTS. `live_payload_test.dart` checks that the client's parsers
survive what the module actually sends. It used to read from /tmp/payloads,
which macOS clears: after a reboot every fixture vanished, `rowsOf` returned an
empty list, and the whole file reported GREEN while checking nothing. Fixtures
now live in the repo, and this script refreshes them.

Run against a live backend:

    python3 tool/capture_payloads.py                  # localhost:8069
    python3 tool/capture_payloads.py http://host:port

Re-run whenever a serializer changes, then run the suite and fix whatever
breaks - a break here means the client and the module have drifted apart.
"""
from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
    "ETP_API", "http://localhost:8069")
OUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "test", "assessment", "payloads",
)

# From the environment, never literals. These used to be `("admin", "admin")`
# and a candidate password in the source, in a file destined for git.
ADMIN = (os.environ.get("ETP_ADMIN_LOGIN", "admin"),
         os.environ.get("ETP_ADMIN_PASSWORD", "admin"))
CANDIDATE = (os.environ.get("ETP_CANDIDATE_LOGIN", ""),
             os.environ.get("ETP_CANDIDATE_PASSWORD", ""))

#: Keys redacted before a payload is written to disk.
#:
#: `access_token` is not a password but it IS a capability: it resolves
#: straight to an attempt and drives /exam/<token>/{state,begin,answer,submit}.
#: A previous capture committed a live one into two fixtures. The fixtures are
#: only used by live_payload_test, which asserts the parsers survive real
#: shapes - it never inspects a value - so redaction costs nothing.
REDACT = ("access_token", "token", "candidate_link",
          "email", "email_from", "login")
REDACTED = "REDACTED"

#: Collection routes: saved as-is, the client parses `data` as a list.
LIST_ROUTES = {
    "assessments": "/api/v1/assessments",
    "generators": "/api/v1/generators",
    "bank": "/api/v1/bank",
    "drafts": "/api/v1/drafts",
    "tags": "/api/v1/tags",
    "responses": "/api/v1/responses",
    "ledger": "/api/v1/ledger",
}


def token(login: str, password: str) -> str:
    body = urllib.parse.urlencode({"login": login, "password": password})
    req = urllib.request.Request(
        f"{BASE}/api/v1/auth_token",
        data=body.encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=60) as res:
        return json.loads(res.read())["data"]["access_token"]


def get(path: str, tok: str):
    req = urllib.request.Request(
        f"{BASE}{path}", headers={"Authorization": f"Bearer {tok}"})
    with urllib.request.urlopen(req, timeout=120) as res:
        return json.loads(res.read())


def redact(node):
    """Blank capability tokens and PII anywhere in a captured payload."""
    if isinstance(node, dict):
        return {k: (REDACTED if k in REDACT and node[k] else redact(v))
                for k, v in node.items()}
    if isinstance(node, list):
        return [redact(v) for v in node]
    return node


def save(name: str, body) -> str:
    os.makedirs(OUT, exist_ok=True)
    body = redact(body)
    with open(os.path.join(OUT, f"{name}.json"), "w") as fh:
        json.dump(body, fh, indent=1)
    data = body.get("data")
    if isinstance(data, list):
        return f"{len(data)} rows"
    return "object"


def main() -> int:
    try:
        admin = token(*ADMIN)
    except urllib.error.URLError as exc:
        print(f"CANNOT REACH {BASE} ({exc.reason})")
        print("Start the backend first, then re-run.")
        return 1

    for name, path in LIST_ROUTES.items():
        print(f"  {name:<18} {save(name, get(path, admin))}")

    print(f"  {'settings':<18} {save('settings', get('/api/v1/settings', admin))}")

    # THE FORM STUDIO IMPORT TEMPLATE, decoded out of its envelope.
    #
    # Saved as the DOCUMENT an operator downloads rather than the
    # `{filename, mimetype, content}` wrapper that carries it, because
    # `form_template_test.dart` feeds it to the real importer and the importer
    # reads a form document. It is the one fixture here that is not a
    # serialiser's output: it is rendered from `constants.FORM_ITEM_KINDS`, so a
    # kind added on the module side and missing from this client's
    # `FormItemKind` enum turns up as a failure in that test rather than as a
    # silent degrade to short answer at import time.
    envelope = (get("/api/v1/forms/template/json", admin).get("data") or {})
    document = json.loads(
        base64.b64decode(envelope["content"]).decode("utf-8"))
    items = sum(len(s.get("items") or []) for s in document.get("sections", []))
    print(f"  {'form_template':<18} {save('form_template', document)} "
          f"({items} item(s))")

    # A DETAIL payload, which nests records the list route only counts. Pick a
    # generator that HAS a resource, else the fixture proves nothing.
    gens = (get("/api/v1/generators", admin).get("data") or [])
    with_file = [g for g in gens if (g.get("resource_count") or 0) > 0]
    if with_file:
        gid = with_file[0]["id"]
        detail = get(f"/api/v1/generators/{gid}", admin)
        res = ((detail.get("data") or {}).get("tabs") or {}).get("resources") or []
        print(f"  {'generator_detail':<18} "
              f"{save('generator_detail', detail)} ({len(res)} resource(s))")
    else:
        print("  generator_detail   SKIPPED: no generator has an attached file")

    # THE TWO DETAIL ROUTES THAT CARRY AN ANSWER KEY, and the reason this
    # block exists at all.
    #
    # Only the list routes and `generator_detail` were ever captured, so
    # `/drafts/<id>` and `/bank/<id>` - the ONLY payloads that carry a
    # question's options, its correct answers, its rubric and its media - were
    # never once checked against the parser. The client read `dimensions` on a
    # draft, the server sent that key from a column that is empty for every mcq
    # and msq, and nothing in this repo could notice: the list fixture has no
    # answer key to be wrong about.
    #
    # Pick a draft that HAS a key rather than the first one. An objective draft
    # is the only kind that can prove the key survives the wire, and a fixture
    # that proves nothing is worse than none - the suite goes green either way.
    drafts = (get("/api/v1/drafts", admin).get("data") or [])
    keyed = [d for d in drafts
             if d.get("question_type") in ("mcq", "msq", "image_ab")
             and (d.get("dimension_count") or 0) > 0]
    if keyed:
        did = keyed[0]["id"]
        body = get(f"/api/v1/drafts/{did}", admin)
        dims = (body.get("data") or {}).get("dimensions") or []
        print(f"  {'draft_detail':<18} {save('draft_detail', body)} "
              f"(draft {did}, {len(dims)} axis/axes)")
    else:
        print("  draft_detail       SKIPPED: no objective draft carries a key")

    bank_rows = (get("/api/v1/bank", admin).get("data") or [])
    keyed_bank = [q for q in bank_rows if (q.get("dimension_count") or 0) > 0]
    if keyed_bank:
        qid = keyed_bank[0]["id"]
        body = get(f"/api/v1/bank/{qid}", admin)
        dims = (body.get("data") or {}).get("dimensions") or []
        print(f"  {'bank_detail':<18} {save('bank_detail', body)} "
              f"(question {qid}, {len(dims)} dimension(s))")
    else:
        print("  bank_detail        SKIPPED: no bank question carries a key")

    asms = (get("/api/v1/assessments", admin).get("data") or [])
    # A roster that HAS attempts. Picking blindly overwrote a good fixture
    # with an empty one, which is worse than no fixture: the suite goes green
    # while checking nothing.
    rosters = []
    for asm in asms:
        rows = get(f"/api/v1/assessments/{asm['id']}/candidates", admin)
        rosters.append((asm["id"], rows, len(rows.get("data") or [])))
    rosters.sort(key=lambda item: item[2], reverse=True)
    if rosters and rosters[0][2] > 0:
        aid, body, count = rosters[0]
        print(f"  {'candidates':<18} {save('candidates', body)} "
              f"(assessment {aid})")
    else:
        print("  candidates         SKIPPED: no assessment has a sitting")

    # The candidate's own list has a DIFFERENT shape from the admin roster.
    try:
        cand = token(*CANDIDATE)
        print(f"  {'me_assessments':<18} "
              f"{save('me_assessments', get('/api/v1/me/assessments', cand))}")
    except (urllib.error.HTTPError, urllib.error.URLError):
        print("  me_assessments     SKIPPED: candidate login unavailable")

    print(f"\nWrote fixtures to {os.path.normpath(OUT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
