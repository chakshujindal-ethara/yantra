#!/usr/bin/env bash
# One command that says whether this app is sound.
#
#   bash tool/verify.sh          static + tests + build, then live if reachable
#   bash tool/verify.sh --quick  skip the release build
#
# Live checks are SKIPPED, not failed, when no backend answers: a laptop with
# Odoo stopped should still be able to prove the app compiles and its tests
# pass. A skip is printed, never silently swallowed.
set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1

API=${API:-${ETP_API:-http://localhost:8069}}
# Credentials from the environment, never literals - this file is committed.
ADMIN_LOGIN=${ETP_ADMIN_LOGIN:-admin}
ADMIN_PASSWORD=${ETP_ADMIN_PASSWORD:-admin}
CANDIDATE_LOGIN=${ETP_CANDIDATE_LOGIN:-}
CANDIDATE_PASSWORD=${ETP_CANDIDATE_PASSWORD:-}
QUICK=${1:-}
pass=0; fail=0; skip=0
ok()   { echo "  PASS $1"; pass=$((pass+1)); }
no()   { echo "  FAIL $1"; fail=$((fail+1)); }
skp()  { echo "  SKIP $1"; skip=$((skip+1)); }

echo "1 Static analysis"
ERR=$(dart analyze lib/ test/ 2>&1 | grep -cE "^ +error")
[ "$ERR" = "0" ] && ok "0 errors" || no "$ERR error(s) - run: dart analyze lib/ test/"

echo "2 Tests on the VM"
VM=$(flutter test 2>&1 | tail -1)
echo "    $VM"
grep -q "All tests passed" <<<"$VM" && ok "vm $(grep -oE '\+[0-9]+' <<<"$VM")" || no "vm suite red"

echo "3 Tests on Chrome - the environment that actually ships"
# Not redundant with the VM. Compiled to JavaScript there is ONE numeric type,
# so `0.0 is int` is true on the web and false on the VM. That difference once
# truncated every currency value on the budget screen while the VM stayed green.
WEB=$(flutter test --platform chrome 2>&1 | grep -E "All tests passed|Some tests failed" | head -1)
echo "    ${WEB:-no result}"
grep -q "All tests passed" <<<"$WEB" && ok "chrome $(grep -oE '\+[0-9]+' <<<"$WEB")" || no "chrome suite red"

echo "4 An invitation deep link is honoured"
# The one URL that matters. If this parsing breaks, every invited candidate
# lands on a login screen and then their own list, having to find the exam by
# hand - and the failure is silent.
grep -q "examTokenFrom(Uri.base)" lib/main.dart \
  && grep -q "loadExamByToken" lib/assessment/screens/exam/exam_screen.dart \
  && ok "the URL is read at startup and the sitting is fetched by token" \
  || no "deep-link handling is missing - invited candidates cannot reach their exam"

echo "5 The app is detached from the host portal it was ported out of"
H=$(grep -rl "workflow_management_app_v2" lib test 2>/dev/null | wc -l | tr -d ' ')
S=$(grep -rl "api_client.dart' as host" lib 2>/dev/null | wc -l | tr -d ' ')
[ "$H$S" = "00" ] && ok "no host package or client references" \
                  || no "host refs remain (package=$H client=$S)"

if [ "$QUICK" = "--quick" ]; then
  skp "release build (--quick)"
else
  echo "6 Release build"
  # WITH the defines: a bare `flutter build web --release` here overwrote
  # build/web with a bundle that had no backend URL, so the served app POSTed
  # at its own file server. Verifying may not leave a broken artefact behind.
  URL="${API_BASE_URL:-$API}"
  # The API_DB fallback below must match the Makefile's (etp_local). It used to
  # say `ethara_ops` - a database this app is not served from - so running this
  # script directly baked the WRONG database name into the release bundle while
  # every other path used the right one. Nothing failed; the app just talked to
  # the wrong place.
  # PROCTOR_SIM must be passed here too. `kProctorSim` defaults to TRUE so the
  # widget tests can find the rig, and the Makefile turns it off for a built
  # bundle - but this script builds directly and omitted the flag, so every
  # `make verify` overwrote build/web with an artefact that shipped the
  # violation simulator to candidates. The rig drives the REAL violation
  # route: at a cap of 1 it ends your own exam with one click.
  B=$(flutter build web --release --pwa-strategy=none \
        --dart-define=API_BASE_URL="$URL" \
        --dart-define=API_DB="${API_DB:-etp_local}" \
        --dart-define=PROCTOR_SIM="${PROCTOR_SIM:-false}" 2>&1 | tail -1)
  grep -q "Built" <<<"$B" && ok "web bundle built" || no "$B"
  # Prove the rig is really gone, the same way the backend URL is proved to
  # have landed. A define that silently failed to apply looks identical to one
  # that worked, and this is the one whose failure ships an integrity hole.
  #
  # ALWAYS RUNS, and asserts in BOTH directions. The first cut was
  # `if [ "$PROCTOR_SIM" = "false" ]`, which had two holes that both reported
  # success. `bool.fromEnvironment` treats anything that is not exactly "true"
  # as its default - and kProctorSim's default is TRUE - so PROCTOR_SIM=FALSE,
  # 0 or no shipped the rig AND skipped the check, with nothing in the totals
  # to say so. And this script runs without `set -e`, so after a failed build
  # the grep ran against a missing file, exited non-zero, took the `||` branch
  # and printed "stripped" - strictly weaker than no check at all, on the one
  # run where it mattered most.
  if [ ! -f build/web/main.dart.js ]; then
    no "no bundle to check for the proctoring simulator"
  elif grep -qF "PROCTORING SIMULATOR" build/web/main.dart.js; then
    [ "${PROCTOR_SIM:-false}" = "true" ] \
      && ok "proctoring simulator present, as PROCTOR_SIM=true asked" \
      || no "the bundle still contains the proctoring simulator"
  else
    [ "${PROCTOR_SIM:-false}" = "true" ] \
      && no "PROCTOR_SIM=true but the simulator is not in the bundle" \
      || ok "proctoring simulator stripped from the bundle"
  fi
  # Prove it LANDED rather than trusting the flag - the check that would have
  # caught the breakage.
  grep -qF "$URL" build/web/main.dart.js \
    && ok "backend URL baked into the bundle" \
    || no "bundle does not contain $URL"
  # And that no service worker is REGISTERED: it caches the bundle outside
  # HTTP, so one stale registration outlives every rebuild. `--pwa-strategy=
  # none` still emits an empty placeholder file, so presence proves nothing -
  # what matters is whether the loader is handed a serviceWorkerVersion.
  grep -q 'serviceWorkerVersion: "' build/web/flutter_bootstrap.js \
    && no "the bundle registers a service worker" \
    || ok "no service worker registered"
fi

echo "7 Live backend"
TOK=$(curl -s -m 5 -X POST "$API/api/v1/auth_token" \
      -d "login=$ADMIN_LOGIN&password=$ADMIN_PASSWORD" \
      | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['access_token'])" 2>/dev/null)
if [ -z "${TOK:-}" ]; then
  skp "no backend at $API - static checks above still stand"
else
  # Ask the module for its own role decision, then confirm it ENFORCES it.
  # The portal a user sees is the server's answer, never the client's guess.
  probe() {
    curl -s -m 15 -X POST "$API/api/v1/$2" -H "Content-Type: application/json" \
      -H "Authorization: Bearer $1" -d '{}' \
      | python3 -c "import json,sys;print(json.load(sys.stdin).get('ok'))" 2>/dev/null
  }
  BAD=0
  for p in auth/me assessments generators bank drafts tags responses ledger settings; do
    [ "$(probe "$TOK" "$p")" = "True" ] || { echo "    admin /$p refused"; BAD=$((BAD+1)); }
  done
  [ "$BAD" = "0" ] && ok "9/9 operator routes answer headlessly" || no "$BAD operator route(s) failed"

  if [ -z "$CANDIDATE_PASSWORD" ]; then
    CTOK=""
  else
    CTOK=$(curl -s -m 5 -X POST "$API/api/v1/auth_token" \
           -d "login=$CANDIDATE_LOGIN&password=$CANDIDATE_PASSWORD" \
           | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['access_token'])" 2>/dev/null)
  fi
  if [ -z "${CTOK:-}" ]; then
    skp "no candidate account - boundary not exercised"
  else
    LEAK=0
    for p in assessments generators bank ledger settings; do
      [ "$(probe "$CTOK" "$p")" = "False" ] || { echo "    LEAK /$p"; LEAK=$((LEAK+1)); }
    done
    [ "$LEAK" = "0" ] && ok "5/5 operator routes refuse a candidate token" \
                      || no "$LEAK route(s) leaked to a candidate"
  fi
fi

echo
echo "PASS $pass  FAIL $fail  SKIP $skip"
[ "$fail" -eq 0 ]
