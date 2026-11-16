#!/usr/bin/env bash
# One command that says whether this addon is sound.
#
#   bash tools/verify.sh          static + config + live probes
#   bash tools/verify.sh --quick  skip the live probes
#
# Live checks are SKIPPED, not failed, when Odoo is not running: a laptop with
# the server stopped should still prove the addon compiles and its manifest is
# coherent. A skip is printed, never silently swallowed.
#
# Paths come from this script's own location, so it works from anywhere:
#   ADDON  custom_addons/assessments_be_v2
#   ROOT   the ethara-etp checkout, which owns src/, .venv and odoo.conf
#
# Overridable: CONF, API (or ETP_API), PY, DB.
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
ADDON="$(dirname "$HERE")"
ROOT="$(cd "$ADDON/../.." && pwd)"
cd "$ROOT" || exit 1

MOD=$ADDON
# THE CONFIG LIVES IN src/, NOT AT THE ROOT. This defaulted to $ROOT/odoo.conf,
# which does not exist in this checkout, so step 1's `grep` printed "No such
# file", the loop it feeds ran ZERO times, and `bad` stayed 0 - a PASS that had
# checked nothing at all, which is the exact silent-green this script exists to
# prevent. Fall back through the real locations and refuse to pretend otherwise.
if [ -n "${CONF:-}" ]; then :
elif [ -f "$ROOT/odoo.conf" ]; then CONF=$ROOT/odoo.conf
elif [ -f "$ROOT/src/odoo.conf" ]; then CONF=$ROOT/src/odoo.conf
else CONF=$ROOT/odoo.conf
fi
API=${API:-${ETP_API:-http://localhost:8069}}
PY=${PY:-$ROOT/.venv/bin/python}
[ -x "$PY" ] || PY=python3

pass=0; fail=0; skip=0
ok()  { echo "  PASS $1"; pass=$((pass+1)); }
no()  { echo "  FAIL $1"; fail=$((fail+1)); }
skp() { echo "  SKIP $1"; skip=$((skip+1)); }

echo "1 Every addons_path entry exists"
# The failure this catches is nasty: Odoo starts happily with a broken
# addons_path and still answers 200 on /web/login, while every /api/v1 route
# 404s. A health check would call that healthy.
bad=0
if [ ! -f "$CONF" ]; then
  no "no odoo.conf found (looked at \$ROOT/odoo.conf and \$ROOT/src/odoo.conf)"
else
paths=$(grep -oE '^addons_path *= *.*' "$CONF" | sed 's/^addons_path *= *//' | tr ',' ' ')
[ -n "$paths" ] || { echo "    addons_path is empty in $CONF"; bad=$((bad+1)); }
for p in $paths; do
  [ -d "$p" ] || { echo "    missing: $p"; bad=$((bad+1)); }
done
fi
[ "$bad" = 0 ] && ok "addons_path resolves" || no "$bad broken entry/entries in $CONF"

echo "2 The addon compiles"
if err=$(env -u PYTHONPATH "$PY" -m compileall -q "$MOD" 2>&1); then
  ok "all $(find "$MOD" -name '*.py' | wc -l | tr -d ' ') python files compile"
else
  echo "$err" | head -5 | sed 's/^/    /'; no "syntax error in the addon"
fi

echo "3 The manifest is coherent"
# A data file listed but absent takes the whole addon out on upgrade, and the
# traceback names the XML, not the manifest - so it reads like a broken view.
env -u PYTHONPATH "$PY" - "$MOD" <<'PY'
import ast, sys, pathlib
mod = pathlib.Path(sys.argv[1])
man = ast.literal_eval((mod / "__manifest__.py").read_text())
missing = [f for f in man.get("data", []) if not (mod / f).exists()]
if missing:
    # EXIT NON-ZERO, not just a printed line. This used to print "MISSING x"
    # and still exit 0, so the check reported PASS while naming its own
    # failure - exactly the silent-green the suite exists to prevent.
    print("MISSING " + ",".join(missing))
    sys.exit(1)
print(f"OK {len(man.get('data', []))}")
PY
[ $? = 0 ] && ok "manifest parses and its data files exist" \
           || no "manifest is broken or lists a missing file"

echo "4 Declared dependencies are present"
# api_auth_gateway owns /api/v1/auth_token. Without it the addon installs
# cleanly and the client cannot sign in at all.
#
# SEARCHED ACROSS THE WHOLE addons_path, not just custom_addons. This looked
# only in the addon's own parent directory, so every CORE dependency - base,
# mail, hr, hr_recruitment, website, auth_signup - was reported MISSING on a
# perfectly sound checkout. A check that always fails is a check nobody reads,
# and it sat next to the one real thing it is for: a missing sibling addon.
env -u PYTHONPATH "$PY" - "$MOD" "$CONF" <<'PY'
import ast, configparser, pathlib, sys
mod = pathlib.Path(sys.argv[1])
conf = pathlib.Path(sys.argv[2])
roots = [mod.parent]
if conf.is_file():
    cp = configparser.ConfigParser()
    cp.read(conf)
    for section in cp.sections():
        for p in (cp[section].get("addons_path") or "").split(","):
            p = p.strip()
            if p:
                roots.append(pathlib.Path(p))
# The Odoo core tree is not always spelled in addons_path (odoo-bin adds it),
# so look for it relative to the checkout as well.
for guess in ("src/odoo/addons", "src/addons"):
    roots.append(mod.parents[1] / guess)
man = ast.literal_eval((mod / "__manifest__.py").read_text())
missing = [d for d in man.get("depends", [])
           if not any((r / d / "__manifest__.py").is_file() for r in roots)]
if missing:
    print("MISSING " + ",".join(missing))
    print("searched: " + ", ".join(str(r) for r in roots))
    sys.exit(1)
print("OK %d dependency/ies resolve" % len(man.get("depends", [])))
PY
[ $? = 0 ] && ok "every declared dependency resolves on the addons_path" \
           || no "a declared dependency is not on the addons_path"

echo "5 Client and server agree on parameter names"
# Three bugs of this class shipped before this check existed, and NONE of them
# raised an error: an unread key is silence, not a 400.
#   person_ids  vs applicant_ids       - nobody could be assigned
#   dry_run     vs confirm             - no assessment could be launched
#   option_ids  vs selected_option_ids - every MCQ answer was refused
#
# This used to grep the audit's output for five hardcoded names, so it could
# only ever catch bugs that had already been found once. The audit now resolves
# field allow-lists and follows same-file helpers, which removed the false
# positives that made grepping look reasonable - so trust its exit code.
audit_out=$(env -u PYTHONPATH "$PY" "$HERE/contract_audit.py" 2>&1)
case $? in
  0) ok "every key the client sends is read by its route" ;;
  2) skp "$(printf '%s' "$audit_out" | tail -1)" ;;
  *) no "the client sends keys no route reads"
     printf '%s\n' "$audit_out" | grep -B1 IGNORES | head -20 | sed 's/^/    /' ;;
esac

echo "5b The client can read what the serializers send"
# The MIRROR of step 5, and the direction that was never watched. Step 5's own
# three bugs were all client-to-server; the next one went the other way.
# `draft_detail` sent `dimensions` out of a column that is empty for every mcq
# and msq, so a question with five options and three correct arrived as an empty
# key - rendered as "no correct option marked" over a question the server had
# stored correctly, with every check in this file green.
#
# REPORT-ONLY for now, on purpose. The Dart side reads most keys through a
# two-spelling `??` chain, so the first pass is mostly aliases rather than
# defects - and step 5's own history shows what happens to a checker whose
# output nobody trusts. Set ETP_RESPONSE_AUDIT_STRICT=1 to make it fail.
resp_out=$(env -u PYTHONPATH "$PY" "$HERE/response_audit.py" 2>&1)
case $? in
  0) if printf '%s' "$resp_out" | grep -q '^REVIEW'; then
       ok "$(printf '%s' "$resp_out" | grep '^REVIEW' | head -1) (report-only)"
     else
       ok "every key the client reads is sent by its serializers"
     fi ;;
  2) skp "$(printf '%s' "$resp_out" | tail -1)" ;;
  *) no "the client reads keys nothing sends"
     printf '%s\n' "$resp_out" | sed -n '/^FAIL/,$p' | head -20 \
       | sed 's/^/    /' ;;
esac

echo "6 CORS: an unknown origin gets NO headers, a known one gets its own"
# The failure this catches is invisible in a server log: the request reaches
# Odoo, Odoo answers 200, and the BROWSER discards the response. Odoo's stock
# handler also answers a preflight with `Allow-Origin: *`, which must not
# survive on an authenticated API.
pre() { curl -s -i -m 10 -X OPTIONS "$API/api/v1/settings" -H "Origin: $1" \
        -H 'Access-Control-Request-Method: POST' \
        | tr -d '\r' | grep -i '^access-control-allow-origin:' \
        | head -1 | cut -d' ' -f2-; }
KNOWN=$(pre http://localhost:8200)
UNKNOWN=$(pre https://not-configured.example.com)
if [ -z "${KNOWN:-}" ] && [ -z "${UNKNOWN:-}" ]; then
  skp "no Odoo at $API - CORS unverified"
else
  echo "    known -> '${KNOWN:-NONE}' | unknown -> '${UNKNOWN:-NONE}'"
  [ "$KNOWN" = "http://localhost:8200" ] && [ -z "$UNKNOWN" ] \
    && ok "known origin echoed, unknown refused, no wildcard" \
    || no "known='${KNOWN:-NONE}' unknown='${UNKNOWN:-NONE}'"
fi

echo "7 Live: the addon actually LOADED"
tok=$(curl -s -m 5 -X POST "$API/api/v1/auth_token" \
      -d "login=${ETP_ADMIN_LOGIN:-admin}&password=${ETP_ADMIN_PASSWORD:-admin}" \
      | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["data"]["access_token"])' 2>/dev/null)
if [ -z "${tok:-}" ]; then
  skp "no Odoo at $API - static checks above still stand"
elif [ "${1:-}" = --quick ]; then
  skp "live probes (--quick)"
else
  # /web/login answers even with zero custom addons. Only an addon-owned route
  # proves this tree is the one being served.
  probe() { curl -s -m 15 -X POST "$API/api/v1/$1" -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $tok" -d '{}' \
    | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("ok"))' 2>/dev/null; }
  bad=0
  for r in auth/me assessments generators bank drafts tags responses ledger settings; do
    [ "$(probe "$r")" = True ] || { echo "    /$r refused"; bad=$((bad+1)); }
  done
  [ "$bad" = 0 ] && ok "9/9 operator routes answer from this tree" || no "$bad route(s) failed"

  if [ -z "${ETP_CANDIDATE_PASSWORD:-}" ]; then
    skp "ETP_CANDIDATE_PASSWORD unset - the role boundary is not exercised"
  else
    ctok=$(curl -s -m 5 -X POST "$API/api/v1/auth_token" \
           -d "login=${ETP_CANDIDATE_LOGIN:-priya.sharma@example.com}&password=$ETP_CANDIDATE_PASSWORD" \
           | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["data"]["access_token"])' 2>/dev/null)
    if [ -z "${ctok:-}" ]; then
      skp "candidate sign-in failed - the boundary is not exercised"
    else
      leak=0
      for r in assessments generators bank ledger settings; do
        out=$(curl -s -m 15 -X POST "$API/api/v1/$r" -H 'Content-Type: application/json' \
              -H "Authorization: Bearer $ctok" -d '{}' \
              | "$PY" -c 'import json,sys;print(json.load(sys.stdin).get("ok"))' 2>/dev/null)
        [ "$out" = False ] || { echo "    LEAK /$r"; leak=$((leak+1)); }
      done
      [ "$leak" = 0 ] && ok "5/5 operator routes refuse a candidate token" \
                      || no "$leak route(s) leaked to a candidate"
    fi
  fi

  # INVARIANT: the pre-submit checklist must not carry the answer key. This is
  # a regression guard for a real leak - /review used the post-release row
  # builder, so an in-progress candidate could read `correct[]` and a live
  # Correct/Incorrect verdict for every MCQ, then go back and fix their answers.
  if [ -z "${ETP_EXAM_TOKEN:-}" ] || [ -z "${ETP_CANDIDATE_PASSWORD:-}" ]; then
    skp "ETP_EXAM_TOKEN/ETP_CANDIDATE_PASSWORD unset - the /review answer-key guard is not exercised"
  else
    # MUST be signed in as the bound candidate. An unauthenticated call gets a
    # gate response with no rows, which would pass this check while the leak sat
    # wide open - the check has to reach the code path it is guarding.
    jar=$(mktemp)
    curl -s -m 10 -o /dev/null -c "$jar" -X POST "$API/api/v1/auth/session" \
      -H 'Content-Type: application/json' \
      -d "{\"login\":\"${ETP_CANDIDATE_LOGIN:-priya.sharma@example.com}\",\"password\":\"$ETP_CANDIDATE_PASSWORD\"}"
    verdict=$(curl -s -m 15 -b "$jar" -X POST "$API/api/v1/exam/$ETP_EXAM_TOKEN/review" \
             -H 'Content-Type: application/json' -d '{}' \
             | "$PY" -c 'import json,sys
d = json.load(sys.stdin)
if not d.get("ok"):
    print("UNREACHED " + (d.get("error") or {}).get("code", "?")); raise SystemExit
rows = (d.get("data") or {}).get("rows") or []
if not rows:
    print("UNREACHED no rows"); raise SystemExit
bad = [k for r in rows for k in ("correct", "verdict", "kind", "score_raw",
                                 "feedback", "deductions", "credit") if k in r]
print("LEAK " + ",".join(sorted(set(bad))) if bad else "CLEAN %d rows" % len(rows))' 2>/dev/null)
    rm -f "$jar"
    case "${verdict:-}" in
      CLEAN*)     ok "/review carries no answer key and no verdict ($verdict)" ;;
      UNREACHED*) skp "/review guard did not reach the code path ($verdict)" ;;
      *)          no "/review leaked correctness: ${verdict:-no response}" ;;
    esac
  fi
fi

echo
echo "PASS $pass  FAIL $fail  SKIP $skip"
[ "$fail" -eq 0 ]
