#!/bin/bash
# Go Max: copies the two programs into GoMax/bin (not in git) and writes their
# SHA-256 to GoMax/bin.sha256 (in git), which the build checks. Run it from the
# repository root after building or updating either program:
#
#   scripts/gomax-helpers.sh
#
# Defaults are the builds with neutral paths (11 Nov 2026, see docs/GO_MAX.md):
#   zakurad  ~/rockit-proto/release/bin/zakurad  Zakura v1.8.5 (fe180bc)
#   zainod   ~/rockit-proto/release/bin/zainod   Zaino feat/nu7 aaf8122 + the two Rock it patches
# Override with ZAKURAD=/path ZAINOD=/path.
#
# Both were built with the home folder remapped to /build. What the linker
# still leaves behind (paths to the Rust toolchain in the debug symbol
# table) is stripped here, and a program that still names this Mac's home
# folder is refused: it would put the user name in a public app.
#
# Built on this Mac, not reproducible yet. Before a public release both are
# built from pinned tags in a clean build, and those fingerprints are pinned.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/GoMax/bin"
ZAKURAD="${ZAKURAD:-$HOME/rockit-proto/release/bin/zakurad}"
ZAINOD="${ZAINOD:-$HOME/rockit-proto/release/bin/zainod}"

for p in "$ZAKURAD" "$ZAINOD"; do
  [ -x "$p" ] || { echo "gomax-helpers: $p is missing or not a program." >&2; exit 1; }
  file "$p" | grep -q "Mach-O 64-bit executable arm64" || {
    echo "gomax-helpers: $p is not a program for this Mac:" >&2; file "$p" >&2; exit 1; }
done

mkdir -p "$BIN"
cp "$ZAKURAD" "$BIN/zakurad"
cp "$ZAINOD" "$BIN/zainod"
chmod 755 "$BIN/zakurad" "$BIN/zainod"
for f in zakurad zainod; do
  /usr/bin/strip -S "$BIN/$f"
  if grep -q "$HOME" "$BIN/$f"; then
    echo "gomax-helpers: $f still names this Mac's home folder ($HOME). Refused:" >&2
    strings -a "$BIN/$f" | grep "$HOME" | head -3 >&2
    rm -f "$BIN/zakurad" "$BIN/zainod"
    exit 1
  fi
done
( cd "$BIN" && shasum -a 256 zakurad zainod ) > "$ROOT/GoMax/bin.sha256"

echo "gomax-helpers: in GoMax/bin:"
"$BIN/zakurad" --version 2>/dev/null | head -1 || true
echo "gomax-helpers: fingerprints in GoMax/bin.sha256:"
cat "$ROOT/GoMax/bin.sha256"
