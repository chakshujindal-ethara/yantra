"""Probe the contract-audit findings against the LIVE API.

The static audit reports keys the client sends that it could not see a route
read. That is a LEAD, not a finding: `**kw` handlers, helper functions and
shared `_update` bodies all read args somewhere the regex cannot follow.

This settles each one the only way it can be settled - send the key, then read
the record back and see whether the value landed.
"""
import json
import sys
import urllib.error
import urllib.request

import _env

_env.require_local_or_explicit()

BASE = _env.API
PROBE = "ZZAUDIT"


def _tok(login, password):
    req = urllib.request.Request(
        f"{BASE}/api/v1/auth_token",
        data=f"login={login}&password={password}".encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    return json.loads(urllib.request.urlopen(req, timeout=60).read())["data"]["access_token"]


A = _tok(_env.ADMIN_LOGIN, _env.ADMIN_PASSWORD)


def call(path, body=None, timeout=120):
    req = urllib.request.Request(
        f"{BASE}{path}", data=json.dumps(body or {}).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {A}"})
    try:
        return json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return json.loads(raw or b"{}")
        except Exception:  # noqa: BLE001
            return {"ok": False, "error": {"code": f"http{exc.code}"}}


results = []


def verdict(name, sent, got, expected):
    honoured = got == expected
    results.append((name, honoured, sent, got, expected))
    mark = "HONOURED" if honoured else "IGNORED "
    print(f"  {mark}  {name}: sent={sent!r} -> stored={got!r}")
    return honoured


print("=" * 72)
print("CONTRACT AUDIT - live verification")
print("=" * 72)

print("\n/assessments/create")
made = call("/api/v1/assessments/create", {
    "name": f"{PROBE} create probe",
    "duration_minutes": 47,
    "question_limit": 5,
    "subjective_threshold": 71.0,
})
aid = made.get("id") or (made.get("data") or {}).get("id")
if not aid:
    print("  could not create:", json.dumps(made)[:200])
else:
    d = call(f"/api/v1/assessments/{aid}").get("data") or {}
    verdict("duration_minutes", 47, d.get("duration_minutes"), 47)
    verdict("question_limit", 5, d.get("question_limit"), 5)
    verdict("subjective_threshold", 71.0,
            float(d.get("subjective_threshold") or 0), 71.0)

    print("\n/assessments/*/update")
    call(f"/api/v1/assessments/{aid}/update", {
        "name": f"{PROBE} renamed",
        "duration_minutes": 63,
        "subjective_threshold": 38.0,
    })
    d2 = call(f"/api/v1/assessments/{aid}").get("data") or {}
    verdict("name", f"{PROBE} renamed", d2.get("name"), f"{PROBE} renamed")
    verdict("duration_minutes", 63, d2.get("duration_minutes"), 63)
    verdict("subjective_threshold", 38.0,
            float(d2.get("subjective_threshold") or 0), 38.0)

print("\n/generators/create")
g = call("/api/v1/generators/create", {
    "name": f"{PROBE} gen probe",
    "sop_title": "Probe Title",
    "sop_summary": "Probe summary line.",
})
gid = g.get("id") or (g.get("data") or {}).get("id")
if gid:
    gd = call(f"/api/v1/generators/{gid}").get("data") or {}
    verdict("sop_title", "Probe Title", gd.get("sop_title"), "Probe Title")
    verdict("sop_summary", "Probe summary line.",
            gd.get("sop_summary"), "Probe summary line.")

    print("\n/generators/*/update")
    call(f"/api/v1/generators/{gid}/update", {"name": f"{PROBE} gen renamed"})
    gd2 = call(f"/api/v1/generators/{gid}").get("data") or {}
    verdict("name", f"{PROBE} gen renamed", gd2.get("name"),
            f"{PROBE} gen renamed")

print("\n/bank filter keys")
all_rows = call("/api/v1/bank", {"limit": 200}).get("data") or []
typed = call("/api/v1/bank", {"limit": 200, "type": "mcq"}).get("data") or []
qt = call("/api/v1/bank",
          {"limit": 200, "question_type": "mcq"}).get("data") or []
print(f"  no filter          -> {len(all_rows)} rows")
print(f"  type='mcq'         -> {len(typed)} rows")
print(f"  question_type='mcq'-> {len(qt)} rows")
if len(typed) == len(all_rows) and len(qt) != len(all_rows):
    print("  IGNORED   'type' does nothing; the route reads 'question_type'")
    results.append(("bank type filter", False, "type", len(typed),
                    len(qt)))
else:
    print("  (inconclusive on this dataset)")

print()
print("=" * 72)
bad = [r for r in results if not r[1]]
print(f"IGNORED KEYS CONFIRMED: {len(bad)} of {len(results)} probed")
for name, _, sent, got, exp in bad:
    print(f"  {name}: sent {sent!r}, stored {got!r} (expected {exp!r})")
json.dump({"assessment_id": aid, "generator_id": gid},
          open("/tmp/audit-probe-ids.json", "w"))
sys.exit(1 if bad else 0)
