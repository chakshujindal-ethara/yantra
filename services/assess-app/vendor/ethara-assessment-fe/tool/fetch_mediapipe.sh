#!/usr/bin/env bash
# Fetch the self-hosted MediaPipe assets for AI proctoring into web/mediapipe/.
#
# The ~42 MB of wasm and models are not committed (see .gitignore). This pulls
# each pinned file from the exact URL in web/mediapipe/NOTICE.md and checks it
# against the SHA-256 recorded there; NOTICE.md is the single source of both.
# A file already present with the right hash is left alone, so a local rig, or
# a Docker context that already carries the files, does not download again.
# Any mismatch fails loudly and leaves nothing half-written behind.
#
#   bash tool/fetch_mediapipe.sh
#
# Run by `make build` / `make build-portable` and by the Dockerfile before
# `flutter build web`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/web/mediapipe"
notice="$dir/NOTICE.md"

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}
get() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$2" "$1"
  else
    wget -q -O "$2" "$1"
  fi
}

# Table rows: | `file` | url | version | `sha256` |
rows="$(awk -F'|' '/^\| `/ { gsub(/[ `]/, "", $2); gsub(/ /, "", $3); gsub(/[ `]/, "", $5); print $2, $3, $5 }' "$notice")"
if [ -z "$rows" ]; then
  echo "fetch_mediapipe: no asset rows found in $notice" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
total=0
fetched=0
while read -r file url want; do
  total=$((total + 1))
  dest="$dir/$file"
  if [ -f "$dest" ] && [ "$(sha "$dest")" = "$want" ]; then
    # A file an older run left at 0600 keeps that mode otherwise.
    chmod 644 "$dest"
    continue
  fi
  get "$url" "$tmp"
  got="$(sha "$tmp")"
  if [ "$got" != "$want" ]; then
    echo "fetch_mediapipe: SHA-256 MISMATCH for $file" >&2
    echo "  url:  $url" >&2
    echo "  want: $want" >&2
    echo "  got:  $got" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$tmp" "$dest"
  # mktemp makes the file 0600 and cp keeps that; nginx's worker (not root)
  # could then not read it in the image and every asset would 403.
  chmod 644 "$dest"
  fetched=$((fetched + 1))
done <<< "$rows"
echo "fetch_mediapipe: $total assets verified, $fetched downloaded"
