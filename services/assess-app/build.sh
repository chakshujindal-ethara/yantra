#!/usr/bin/env bash
# Build the exam app's web bundle on this machine into dist/, for Dockerfile.prebuilt (the local rig's VM is too
# small to run the Flutter build itself). CI and real images build inside the Dockerfile instead.
#
# The vendored tree is never built in place: it is copied to a scratch directory first, so neither the fetched
# proctoring models nor Flutter's build output can read as drift to `yantra vendor check`.
#
#   services/assess-app/build.sh            # needs flutter 3.44.x and python3 on PATH
#   YANTRA_APP_URL=https://app.example services/assess-app/build.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/vendor/ethara-assessment-fe"
work="${ASSESS_BUILD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/yantra-assess-build}"
out="$here/dist"

rm -rf "$work/app"
mkdir -p "$work/app"
# the vendored tree minus local build state; the proctoring models are cached between runs in $work/mediapipe
tar -C "$src" --exclude=./build --exclude=./.dart_tool -cf - . | tar -C "$work/app" -xf -
if [ -d "$work/mediapipe" ]; then cp -R "$work/mediapipe/." "$work/app/web/mediapipe/"; fi
cd "$work/app"
bash tool/fetch_mediapipe.sh
rsync -a --delete "$work/app/web/mediapipe/" "$work/mediapipe/"
flutter pub get
# PROCTOR_SIM=false: the simulator drives the real violation route (see the upstream Dockerfile).
# --pwa-strategy=none: no service worker caching an old bundle. --no-web-resources-cdn: CanvasKit from this origin.
flutter build web --release --no-web-resources-cdn --pwa-strategy=none \
  --dart-define=API_BASE_URL=same-origin \
  --dart-define=PROCTOR_SIM=false \
  --dart-define=YANTRA_APP_URL="${YANTRA_APP_URL-http://localhost:8095}"
grep -qF same-origin build/web/main.dart.js || { echo "build: API_BASE_URL=same-origin missing from the bundle" >&2; exit 1; }
python3 "$here/tool/csp_hashes.py" build/web/index.html > build/web/csp-script-hashes.txt
find build/web/mediapipe -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.wasm' -o -name '*.tflite' \) \
  -size +1k -exec gzip -9 -k -n -f {} +
rm -rf "$out"
cp -R build/web "$out"
echo "build: $(du -sh "$out" | cut -f1) in $out"
