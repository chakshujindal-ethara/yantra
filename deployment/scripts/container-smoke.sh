#!/usr/bin/env bash
# Run the images the way the chart runs them and prove each one serves: read-only root filesystem, only /tmp
# writable, every capability dropped, the chart's user and a deployed environment's env (YANTRA_ENV=staging, no rig
# secrets). CI runs it on every change to the images' inputs; it needs Docker only.
#   * python: the migrate hook (`python -m yantra_common.migrate`, only YANTRA_ENV, YANTRA_SERVICES_ROOT and
#     YANTRA_DATABASE_URL, against a throwaway Postgres) and the gateway's /health
#   * app: / answers 200 with the content security policy naming the gateway; unset URLs refuse to start
#
#   deployment/scripts/container-smoke.sh [--no-build]   # PYTHON_IMAGE / APP_IMAGE pick the tags (default *:smoke)
set -euo pipefail

PYTHON_IMAGE="${PYTHON_IMAGE:-yantra/python:smoke}"
APP_IMAGE="${APP_IMAGE:-yantra/app:smoke}"
POSTGRES_IMAGE="postgres:16.4"
GATEWAY_URL="https://api.smoke.yantra.example"
KEYCLOAK_URL="https://auth.smoke.yantra.example"
STORAGE_URL="https://files.smoke.yantra.example"
build=true
for arg in "$@"; do
  case "$arg" in
    --no-build) build=false ;;
    *) echo "usage: $0 [--no-build]" >&2; exit 2 ;;
  esac
done

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
net="yantra-smoke-$$"
containers=()
cleanup() {
  if ((${#containers[@]})); then docker rm -f "${containers[@]}" > /dev/null 2>&1 || true; fi
  docker network rm "$net" > /dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# the pod security the chart applies to every container
hardened=(--read-only --tmpfs "/tmp:rw,size=64m" --cap-drop ALL --security-opt no-new-privileges --network "$net")
wait_for() { # <url>: 200 within 30 s
  for _ in $(seq 1 30); do
    curl -fs -o /dev/null "$1" && return 0
    sleep 1
  done
  return 1
}

if "$build"; then
  echo "== build $PYTHON_IMAGE and $APP_IMAGE"
  docker build -q -t "$PYTHON_IMAGE" "$repo" > /dev/null
  docker build -q -t "$APP_IMAGE" --build-arg GATEWAY_URL="$GATEWAY_URL" --build-arg KEYCLOAK_URL="$KEYCLOAK_URL" \
    --build-arg DIRECT_LOGIN=false "$repo/app" > /dev/null
fi
docker network create "$net" > /dev/null

echo "== python: the migrate hook in a deployed environment (no PII or bank key set)"
pg="smoke-postgres-$$"
containers+=("$pg")
docker run -d --name "$pg" --network "$net" -e POSTGRES_USER=owner -e POSTGRES_PASSWORD=smoke-only-owner-password \
  -e POSTGRES_DB=yantra "$POSTGRES_IMAGE" > /dev/null
for _ in $(seq 1 30); do
  docker exec "$pg" pg_isready -U owner -d yantra > /dev/null 2>&1 && break
  sleep 1
done
docker run --rm "${hardened[@]}" --user 10001:10001 \
  -e YANTRA_ENV=staging -e YANTRA_SERVICES_ROOT=/app/services \
  -e YANTRA_DATABASE_URL="postgresql+psycopg://owner:smoke-only-owner-password@$pg:5432/yantra" \
  "$PYTHON_IMAGE" python -m yantra_common.migrate || fail "the migrate hook failed"
schemas="$(docker exec "$pg" psql -U owner -d yantra -Atc "select count(*) from information_schema.schemata where schema_name in ('market','talent','assess','quality','payout','notify','tracker','analytics')")"
[[ "$schemas" == 8 ]] || fail "expected 8 module schemas after migrating, found $schemas"
echo "ok: 8 schemas migrated"

echo "== python: the gateway's /health"
gw="smoke-gateway-$$"
containers+=("$gw")
docker run -d --name "$gw" "${hardened[@]}" --user 10001:10001 -p 127.0.0.1::8090 \
  -e YANTRA_ENV=staging -e YANTRA_GATEWAY_KEYCLOAK_ISSUER="$KEYCLOAK_URL/realms/yantra" \
  "$PYTHON_IMAGE" uvicorn --factory yantra_gateway.app:default_app --host 0.0.0.0 --port 8090 --no-access-log > /dev/null
gw_port="$(docker port "$gw" 8090/tcp | head -1 | cut -d: -f2)"
wait_for "http://127.0.0.1:$gw_port/health" || { docker logs "$gw" >&2; fail "the gateway's /health did not answer"; }
echo "ok"

echo "== app: / with the chart's env"
app="smoke-app-$$"
containers+=("$app")
docker run -d --name "$app" "${hardened[@]}" --user 101:101 -p 127.0.0.1::8080 \
  -e YANTRA_ENV=staging -e GATEWAY_URL="$GATEWAY_URL" -e GATEWAY_ORIGIN="$GATEWAY_URL" \
  -e KEYCLOAK_URL="$KEYCLOAK_URL" -e KEYCLOAK_ORIGIN="$KEYCLOAK_URL" -e DIRECT_LOGIN=false -e STORAGE_URL="$STORAGE_URL" \
  "$APP_IMAGE" > /dev/null
app_port="$(docker port "$app" 8080/tcp | head -1 | cut -d: -f2)"
wait_for "http://127.0.0.1:$app_port/" || { docker logs "$app" >&2; fail "the app did not answer / with 200"; }
csp="$(curl -fsS -D - -o /dev/null "http://127.0.0.1:$app_port/" | tr -d '\r' | grep -i '^content-security-policy:' || true)"
[[ "$csp" == *"connect-src 'self' $GATEWAY_URL $KEYCLOAK_URL"* ]] || fail "the CSP does not name the gateway: ${csp:-none}"
[[ "$csp" != *" http: "* && "$csp" != *" https: "* ]] || fail "the CSP allows any origin: $csp"
echo "ok"

echo "== app: refuses to start without its URLs outside local"
bare="smoke-app-bare-$$"
containers+=("$bare")
docker run -d --name "$bare" "${hardened[@]}" --user 101:101 -e YANTRA_ENV=staging "$APP_IMAGE" > /dev/null
for _ in $(seq 1 15); do
  [[ "$(docker inspect -f '{{.State.Status}}' "$bare")" == exited ]] && break
  sleep 1
done
[[ "$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$bare")" == "exited 1" ]] \
  || fail "the app started without GATEWAY_URL and KEYCLOAK_URL"
echo "ok"
