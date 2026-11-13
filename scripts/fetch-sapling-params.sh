#!/bin/bash
# The Sapling parameters ship inside the app, so Lock it never downloads them
# from download.z.cash itself (as Lock it iPhone, audit C-24). They are 50 MB,
# so they are not kept in git: this script puts them in
# ZeckyLockIt/SaplingParams/ and refuses them unless both match the published
# SHA-256 checksums. It copies them from SAPLING_PARAMS_FROM when that folder
# is given and holds them, else downloads them. The engine checks their SHA-1 again before use.
set -euo pipefail

SOURCE="https://download.z.cash/downloads"
SPEND_SHA256="8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13"
OUTPUT_SHA256="2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ZeckyLockIt/SaplingParams"
# Optional: a folder that already holds both files (for example another
# Zecky project), so they are copied instead of downloaded.
LOCAL="${SAPLING_PARAMS_FROM:-}"

sha256() { shasum -a 256 "$1" 2>/dev/null | cut -d ' ' -f 1 || sha256sum "$1" | cut -d ' ' -f 1; }

fetch() {
  local name="$1" want="$2"
  if [[ -f "$DEST/$name" ]] && [[ "$(sha256 "$DEST/$name")" == "$want" ]]; then return 0; fi
  local tmp; tmp="$(mktemp)"
  if [[ -n "$LOCAL" && -f "$LOCAL/$name" ]]; then cp "$LOCAL/$name" "$tmp"; else curl -fsSL --retry 3 -o "$tmp" "$SOURCE/$name"; fi
  if [[ "$(sha256 "$tmp")" != "$want" ]]; then
    rm -f "$tmp"; echo "fetch-sapling-params: $name does not match its checksum. Refused." >&2; exit 1
  fi
  mv "$tmp" "$DEST/$name"; echo "fetch-sapling-params: $name installed."
}

mkdir -p "$DEST"
fetch sapling-spend.params "$SPEND_SHA256"
fetch sapling-output.params "$OUTPUT_SHA256"
