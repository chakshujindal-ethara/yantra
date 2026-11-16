#!/bin/sh
# Renders /config.json from the container's environment so one image serves every environment: the app
# reads it at start and falls back to the values baked in at build time for anything left out. The file lives
# under /tmp (nginx serves it from there) because the root filesystem is read-only in the cluster.
# GATEWAY_URL and KEYCLOAK_URL are origins (https://api.example.org); DIRECT_LOGIN is true or false.
# It also renders the security headers every response carries (headers.conf, included by nginx.conf): the
# content security policy names the gateway, Keycloak and object storage (STORAGE_URL, where presigned media is
# played from and uploaded to) as the only other origins the page may talk to.
# Fail closed: outside YANTRA_ENV=local the container refuses to start without GATEWAY_URL and KEYCLOAK_URL, and
# the policy never falls back to a wildcard (unset locally, the page may talk to its own origin only).
set -eu
dir=/tmp/yantra-config
out=$dir/config.json
mkdir -p "$dir"

if [ "${YANTRA_ENV:-}" != "local" ] && { [ -z "${GATEWAY_URL:-}" ] || [ -z "${KEYCLOAK_URL:-}" ]; }; then
  echo "yantra: GATEWAY_URL and KEYCLOAK_URL are required (YANTRA_ENV=${YANTRA_ENV:-unset}; local skips this)" >&2
  exit 1
fi
origins="${GATEWAY_URL:-} ${KEYCLOAK_URL:-} ${STORAGE_URL:-}"
fonts="https://fonts.gstatic.com"   # the engine's fallback glyphs for characters the bundled fonts lack
csp="default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'"
csp="$csp; img-src 'self' data: blob: ${STORAGE_URL:-}; font-src 'self' data: $fonts"
csp="$csp; connect-src 'self' $origins $fonts; media-src 'self' blob: ${STORAGE_URL:-}; worker-src 'self' blob:"
csp="$csp; frame-ancestors 'none'; base-uri 'self'; form-action 'self' ${KEYCLOAK_URL:-}"
{
  echo 'add_header X-Content-Type-Options "nosniff" always;'
  echo 'add_header X-Frame-Options "DENY" always;'
  echo 'add_header Referrer-Policy "strict-origin-when-cross-origin" always;'
  echo 'add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;'
  echo "add_header Content-Security-Policy \"$csp\" always;"
} > "$dir/headers.conf"
echo "yantra: wrote $dir/headers.conf"
if [ -z "${GATEWAY_URL:-}" ] && [ -z "${KEYCLOAK_URL:-}" ] && [ -z "${DIRECT_LOGIN:-}" ]; then
  rm -f "$out"
  exit 0
fi
case "${DIRECT_LOGIN:-}" in
  true|false) direct="${DIRECT_LOGIN}" ;;
  "") direct="null" ;;
  *) echo "DIRECT_LOGIN must be true or false, got '${DIRECT_LOGIN}'" >&2; exit 1 ;;
esac
json_string() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
printf '{"gateway_url": %s, "keycloak_url": %s, "direct_login": %s}\n' \
  "$(json_string "${GATEWAY_URL:-}")" "$(json_string "${KEYCLOAK_URL:-}")" "$direct" > "$out"
echo "yantra: wrote $out"
