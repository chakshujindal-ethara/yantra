#!/bin/sh
# Renders the security headers every response carries (/tmp/assess-config/headers.conf, included by nginx.conf).
# The content security policy keeps scripts to this origin plus the hashes of index.html's own inline scripts
# (csp-script-hashes.txt, computed when the bundle was built) and the two video players the app embeds.
# STORAGE_URL is the object store's public origin, where presigned media is played from and uploaded to.
# Fail closed: outside YANTRA_ENV=local the container refuses to start without STORAGE_URL or ODOO_UPSTREAM.
set -eu
dir=/tmp/assess-config
mkdir -p "$dir"
# before 20-envsubst-on-templates.sh, which renders the server block into this directory and needs it to exist
mkdir -p "${NGINX_ENVSUBST_OUTPUT_DIR:-/tmp/assess-nginx}"
if [ "${YANTRA_ENV:-}" != "local" ] && { [ -z "${STORAGE_URL:-}" ] || [ -z "${ODOO_UPSTREAM:-}" ]; }; then
  echo "assess-app: STORAGE_URL and ODOO_UPSTREAM are required (YANTRA_ENV=${YANTRA_ENV:-unset}; local skips this)" >&2
  exit 1
fi
hashes_file=/usr/share/nginx/html/csp-script-hashes.txt
if [ ! -s "$hashes_file" ]; then
  echo "assess-app: $hashes_file is missing; the bundle was not built by build.sh or the Dockerfile" >&2
  exit 1
fi
hashes=$(tr '\n' ' ' < "$hashes_file")
storage="${STORAGE_URL:-}"
video="https://www.youtube.com https://player.vimeo.com"
fonts="https://fonts.gstatic.com"   # the engine's fallback glyphs for characters the bundled fonts lack
csp="default-src 'self'; script-src 'self' 'wasm-unsafe-eval' $hashes $video; style-src 'self' 'unsafe-inline'"
csp="$csp; img-src 'self' data: blob: $storage https://i.ytimg.com https://i.vimeocdn.com; font-src 'self' data: $fonts"
csp="$csp; connect-src 'self' $storage $fonts; media-src 'self' blob: $storage; worker-src 'self' blob:"
csp="$csp; frame-src https://www.youtube.com https://www.youtube-nocookie.com https://player.vimeo.com"
csp="$csp; frame-ancestors 'none'; base-uri 'self'; form-action 'self' $storage"
{
  echo 'add_header X-Content-Type-Options "nosniff" always;'
  echo 'add_header X-Frame-Options "DENY" always;'
  echo 'add_header Referrer-Policy "strict-origin-when-cross-origin" always;'
  # proctoring and recorded answers use the camera and microphone, on this origin only
  echo 'add_header Permissions-Policy "camera=(self), microphone=(self), geolocation=(), payment=()" always;'
  echo "add_header Content-Security-Policy \"$csp\" always;"
} > "$dir/headers.conf"
echo "assess-app: wrote $dir/headers.conf"
