#!/bin/bash
# Runs as the first build step. Stops the build unless the Zcash engine is
# exactly the Zecky engine release Lock it iPhone ships: v4.0.0-zecky.4
# (tag commit 556a838), without local changes, and its Mac slice and header
# (unpacked from the release's SwiftPM file) match their fingerprints. See docs/ENGINE.md. Never
# change a pin without rebuilding the engine from its tag and comparing first.
set -euo pipefail

ENGINE_TAG="v4.0.0-zecky.4"
ENGINE_COMMIT="556a8386f45e6cfb57cfd5c7d5846c93e4a603a9"
SWIFTPM_ZIP_SHA256="35a3e6829555d4a3f5a5b0aafea5577318e8f81d8b27ec6a2de98ce76ba15a7c"
MAC_LIB_SHA256="ec88e07329e28e5b691b389d79631e88b91aadf19f54b14416c353dfef3079fa"
HEADER_SHA256="1d9cada2baa1c0f3c7f8035422e1feecd9f0bd696ce7b07ea686313d2844a2dc"

ROOT="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
E="$ROOT/../ZeckyEngine/zecky-engine"
fail() { echo "error: Zecky engine check: $1" >&2; exit 1; }
sha() { /usr/bin/shasum -a 256 "$1" | cut -d ' ' -f 1; }

[ -d "$E/.git" ] || fail "the engine folder ~/Documents/ZeckyEngine/zecky-engine is missing."
got=$(git -C "$E" rev-parse HEAD)
[ "$got" = "$ENGINE_COMMIT" ] || fail "the engine is at commit ${got:0:7}, not $ENGINE_TAG (${ENGINE_COMMIT:0:7})."
[ -z "$(git -C "$E" status --porcelain --untracked-files=no)" ] || fail "the engine source has local changes."
grep -q "checksum: \"$SWIFTPM_ZIP_SHA256\"" "$E/Package.swift" || fail "Package.swift does not pin the $ENGINE_TAG release file's checksum."

# The release file is not downloadable yet, so the engine comes from a copy
# of it: LocalPackages/libzcashlc.xcframework, unpacked from the release zip
# whose SHA-256 is the one Package.swift pins (see docs/ENGINE.md). Checked
# byte for byte here, together with the engine's own LocalPackages manifest.
L="$E/LocalPackages"
F="$L/libzcashlc.xcframework/macos-arm64_x86_64/libzcashlc.framework"
[ -f "$L/Package.swift" ] || fail "LocalPackages is missing: unpack the $ENGINE_TAG release zip there (docs/ENGINE.md)."
cmp -s "$L/Package.swift" "$E/BuildSupport/LocalPackages-Package.swift" || fail "LocalPackages/Package.swift is not the engine's own manifest."
[ "$(sha "$F/libzcashlc")" = "$MAC_LIB_SHA256" ] || fail "the Mac engine library does not match its fingerprint."
[ "$(sha "$F/Headers/zcashlc.h")" = "$HEADER_SHA256" ] || fail "the engine header does not match its fingerprint."
# The Sapling parameters bundled in the app (never downloaded by it).
P="$ROOT/ZeckyLockIt/SaplingParams"
[ "$(sha "$P/sapling-spend.params" 2>/dev/null)" = "8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13" ] &&
[ "$(sha "$P/sapling-output.params" 2>/dev/null)" = "2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4" ] ||
    fail "the Sapling parameters are missing or do not match: run scripts/fetch-sapling-params.sh."
echo "Zecky engine $ENGINE_TAG (${ENGINE_COMMIT:0:7}) checked."
