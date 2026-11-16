#!/usr/bin/env bash
# THE ONE PART OF THE MEDIA FIX THE TEST SUITE CANNOT COVER.
#
# `WebHtmlElementStrategy` is inert off-web: `_network_image_io.dart` stores the
# field and never reads it, and every file in `test/` is `@TestOn('vm')`. So
# `flutter test` passing says nothing about whether a no-CORS image renders.
# This measures it in a real browser instead.
#
# WHAT IT PROVES, and both halves matter:
#
#   never=FAIL fallback=OK        - the reported defect and its fix. `never` is
#                                   the Flutter default and what every designer
#                                   plate used to pass; bytes are XHR-fetched,
#                                   so a host with no `Access-Control-Allow-
#                                   Origin` renders nothing. `fallback` falls
#                                   back to a plain <img>, which a browser will
#                                   DISPLAY without CORS (CORS governs READING
#                                   pixels, not showing them).
#
#   noHeaders=OK withHeaders=FAIL - why `stimulusImage` attaches
#                                   `mediaAuthHeaders` only for our own origin.
#                                   Non-empty headers force `loadViaDecode()`
#                                   and disable the <img> path outright, so
#                                   Preview sending a bearer to every host was
#                                   strictly worse off than the designer.
#
# Requires Chromium via Playwright. This repo has no Python venv, so it borrows
# the one in ../ethara-etp/.venv, where `services/dom_capture` already uses it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fe="$(cd "$here/../.." && pwd)"
py="${PLAYWRIGHT_PYTHON:-$fe/../ethara-etp/.venv/bin/python}"
work="${TMPDIR:-/tmp}/corsprobe"

if [[ ! -x "$py" ]]; then
  echo "no python with playwright at $py" >&2
  echo "set PLAYWRIGHT_PYTHON to one that has it" >&2
  exit 2
fi

mkdir -p "$work"
trap 'jobs -p | xargs -r kill 2>/dev/null || true' EXIT

# A 4x4 red PNG, served WITHOUT Access-Control-Allow-Origin - the whole point.
"$py" - "$work" <<'PY'
import base64, pathlib, sys
pathlib.Path(sys.argv[1], "plate.png").write_bytes(base64.b64decode(
 "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAFklEQVR4nGP8z8DAwMDAxAADjDgYAJ"
 "0aAwPQdMWFAAAAAElFTkSuQmCC"))
PY

"$py" - "$work" <<'PY' &
import functools, http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(
    ("127.0.0.1", 8201),
    functools.partial(H, directory=sys.argv[1])).serve_forever()
PY
sleep 1

run_one() {  # <dart entrypoint> <out dir> <port> <key a> <key b>
  local target="$1" out="$2" port="$3" a="$4" b="$5"
  ( cd "$fe" && flutter build web --release -t "$target" --output="$out" >/dev/null )
  ( cd "$out" && "$py" -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  sleep 1
  "$py" - "$port" "$a" "$b" <<'PY'
import sys, time
from playwright.sync_api import sync_playwright
port, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    page.goto("http://127.0.0.1:%s/" % port, wait_until="load")
    title = ""
    for _ in range(60):
        title = page.title()
        if title.startswith("PROBE") and a + "=" in title and b + "=" in title:
            break
        time.sleep(0.5)
    print(title or "(no verdict - the probe never reported)")
    browser.close()
PY
}

echo "== CORS strategy: expect  never=FAIL fallback=OK"
run_one tool/corsprobe/cors_probe.dart "$work/build" 8202 never fallback

echo "== auth headers: expect  noHeaders=OK withHeaders=FAIL"
run_one tool/corsprobe/hdr_probe.dart "$work/build2" 8203 noHeaders withHeaders

# The path the app now takes for every foreign origin. Distinct from the first
# probe: that one measures Flutter's `fallback`, which reaches an `<img>` only
# after an XHR has failed; this measures OUR element-first `ImagePlate`.
#
# READ AS A DOM FACT, NOT FROM `document.title`. A platform view puts a real
# `<img>` in the page, so `complete` and `naturalWidth` ARE the verdict, and they
# are stronger than a title: a title only says the element reported no error,
# while `naturalWidth > 0` says the browser actually DECODED the bytes. Polling
# for the element also rides out the engine's headless startup, which is racy
# enough that a title-only check reported nothing on some runs while the image
# had rendered perfectly.
echo "== img platform view: expect  plate=OK"
plate_out="$work/build3"
( cd "$fe" && flutter build web --release -t tool/corsprobe/plate_probe.dart \
    --output="$plate_out" >/dev/null )
( cd "$plate_out" && "$py" -m http.server 8204 --bind 127.0.0.1 >/dev/null 2>&1 ) &
sleep 1
"$py" - 8204 <<'PY'
import sys, time
from playwright.sync_api import sync_playwright
port = sys.argv[1]
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 900, "height": 700})
    pg.goto("http://127.0.0.1:%s/" % port, wait_until="load")
    verdict = "plate=FAIL (the element never appeared)"
    # 45s: the engine's first frame is slow headless, and this is the one check
    # that cannot be re-run cheaply.
    for _ in range(90):
        if "plate=FAIL" in pg.title():
            verdict = "plate=FAIL (the element reported an error)"
            break
        if pg.eval_on_selector_all("img", "e => e.length"):
            info = pg.eval_on_selector(
                "img", "e => ({c: e.complete, w: e.naturalWidth})")
            if info["c"]:
                verdict = ("plate=OK" if info["w"] > 0
                           else "plate=FAIL (loaded 0x0 - nothing displayed)")
                break
        time.sleep(0.5)
    print("PROBE %s" % verdict)
    b.close()
PY
