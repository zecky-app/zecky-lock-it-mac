#!/bin/bash
# Go Max: copies the two programs into GoMax/bin (not in git) and writes their
# SHA-256 to GoMax/bin.sha256 (in git), which the build checks. Run it from the
# repository root after building or updating either program:
#
#   scripts/gomax-helpers.sh
#
# Defaults are where the Rock it pruned prototype left them (8–9 Nov 2026):
#   zakurad  ~/.cargo/bin/zakurad            Zakura 1.8.5, cargo install --locked
#   zainod   ~/rockit-proto/zaino/bin/zainod Zaino feat/nu7 aaf8122 + the two Rock it patches
# Override with ZAKURAD=/path ZAINOD=/path.
#
# For testing only: these are local builds, not reproducible. Before a
# release both are built from pinned tags in a clean build, and those
# fingerprints are pinned instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/GoMax/bin"
ZAKURAD="${ZAKURAD:-$HOME/.cargo/bin/zakurad}"
ZAINOD="${ZAINOD:-$HOME/rockit-proto/zaino/bin/zainod}"

for p in "$ZAKURAD" "$ZAINOD"; do
  [ -x "$p" ] || { echo "gomax-helpers: $p is missing or not a program." >&2; exit 1; }
  file "$p" | grep -q "Mach-O 64-bit executable arm64" || {
    echo "gomax-helpers: $p is not a program for this Mac:" >&2; file "$p" >&2; exit 1; }
done

mkdir -p "$BIN"
cp "$ZAKURAD" "$BIN/zakurad"
cp "$ZAINOD" "$BIN/zainod"
chmod 755 "$BIN/zakurad" "$BIN/zainod"
( cd "$BIN" && shasum -a 256 zakurad zainod ) > "$ROOT/GoMax/bin.sha256"

echo "gomax-helpers: in GoMax/bin:"
"$BIN/zakurad" --version 2>/dev/null | head -1 || true
echo "gomax-helpers: fingerprints in GoMax/bin.sha256:"
cat "$ROOT/GoMax/bin.sha256"
