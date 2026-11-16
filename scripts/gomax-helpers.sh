#!/bin/bash
# Go Max: copies the two programs into GoMax/bin (not in git) and writes their
# SHA-256 to GoMax/bin.sha256 (in git), which the build checks. Run it from the
# repository root after building or updating either program:
#
#   scripts/gomax-helpers.sh
#
# Defaults are the builds with neutral paths (11 Nov 2026, see docs/GO_MAX.md):
#   zakurad  ~/rockit-proto/release/bin/zakurad  Zakura v1.8.8 (009b60b)
#   zainod   ~/rockit-proto/release/bin/zainod   Zaino feat/nu7 aaf8122 + the two Rock it patches
# Override with ZAKURAD=/path ZAINOD=/path.
#
# Optional, for the attested-statement experiment only (debug builds):
#   arti     ~/rockit-proto/arti/bin/arti        Arti 2.8.0 with onion services
# Override with ARTI=/path; skipped when it is not there. The build puts it
# into debug builds only, never into an archive.
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
ARTI="${ARTI:-$HOME/rockit-proto/arti/bin/arti}"
PROGRAMS="zakurad zainod"

for p in "$ZAKURAD" "$ZAINOD"; do
  [ -x "$p" ] || { echo "gomax-helpers: $p is missing or not a program." >&2; exit 1; }
  file "$p" | grep -q "Mach-O 64-bit executable arm64" || {
    echo "gomax-helpers: $p is not a program for this Mac:" >&2; file "$p" >&2; exit 1; }
done

mkdir -p "$BIN"
cp "$ZAKURAD" "$BIN/zakurad"
cp "$ZAINOD" "$BIN/zainod"
chmod 755 "$BIN/zakurad" "$BIN/zainod"
rm -f "$BIN/arti"
if [ -x "$ARTI" ] && file "$ARTI" | grep -q "Mach-O 64-bit executable arm64"; then
  cp "$ARTI" "$BIN/arti"
  chmod 755 "$BIN/arti"
  PROGRAMS="$PROGRAMS arti"
fi
for f in $PROGRAMS; do
  /usr/bin/strip -S "$BIN/$f"
  if grep -q "$HOME" "$BIN/$f"; then
    echo "gomax-helpers: $f still names this Mac's home folder ($HOME). Refused:" >&2
    strings -a "$BIN/$f" | grep "$HOME" | head -3 >&2
    rm -f "$BIN/zakurad" "$BIN/zainod" "$BIN/arti"
    exit 1
  fi
done
# Inside Lock it's sandbox a program can only load macOS's own libraries,
# so anything linked to Homebrew (/opt/homebrew) or elsewhere is refused.
for f in $PROGRAMS; do
  other=$(otool -L "$BIN/$f" | tail -n +2 | awk '{print $1}' | grep -v -e '^/usr/lib/' -e '^/System/Library/' || true)
  if [ -n "$other" ]; then
    echo "gomax-helpers: $f needs libraries outside macOS, which the sandbox blocks. Refused:" >&2
    echo "$other" >&2
    rm -f "$BIN/zakurad" "$BIN/zainod" "$BIN/arti"
    exit 1
  fi
done
( cd "$BIN" && shasum -a 256 zakurad zainod ) > "$ROOT/GoMax/bin.sha256"
# Arti's fingerprint apart, so a build without Arti still checks the two.
if [ -x "$BIN/arti" ]; then ( cd "$BIN" && shasum -a 256 arti ) > "$ROOT/GoMax/arti.sha256"; fi

echo "gomax-helpers: in GoMax/bin:"
"$BIN/zakurad" --version 2>/dev/null | head -1 || true
echo "gomax-helpers: fingerprints in GoMax/bin.sha256:"
cat "$ROOT/GoMax/bin.sha256"
