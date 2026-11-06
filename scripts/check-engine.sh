#!/bin/bash
# Runs as the first build step. Stops the build unless the Zcash engine is
# exactly the Zecky engine Lock it iPhone 0.0.19 (19) ships: release
# v4.0.0-zecky.2, commit 3a69cb0, without local changes, and the Mac slice
# of libzcashlc (built in the same run as the iPhone release) and its header
# match their fingerprints. See docs/ENGINE.md. Never change a pin without
# rebuilding the engine from its commit and comparing first.
set -euo pipefail

ENGINE_COMMIT="3a69cb02c6ebecb17f4ad11137da71b78d459a8e"
MAC_LIB_SHA256="2d36d76fb804d4d560dffe74e2b8a8dbe0643bb7dae47b2891b6b34be948211e"
HEADER_SHA256="1d9cada2baa1c0f3c7f8035422e1feecd9f0bd696ce7b07ea686313d2844a2dc"

E="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}/../ZeckyEngine/zecky-engine"
F="$E/LocalPackages/libzcashlc.xcframework/macos-arm64_x86_64/libzcashlc.framework"
fail() { echo "error: Zecky engine check: $1" >&2; exit 1; }
sha() { /usr/bin/shasum -a 256 "$1" | cut -d ' ' -f 1; }

[ -d "$E/.git" ] || fail "the engine folder ~/Documents/ZeckyEngine/zecky-engine is missing."
[ -f "$E/LocalPackages/Package.swift" ] || fail "LocalPackages is missing, so the engine package would download the official 4.0.0 binary, which does not know NU7."
got=$(git -C "$E" rev-parse HEAD)
[ "$got" = "$ENGINE_COMMIT" ] || fail "the engine is at commit ${got:0:7}, not 3a69cb0."
[ -z "$(git -C "$E" status --porcelain --untracked-files=no)" ] || fail "the engine source has local changes."
[ "$(sha "$F/libzcashlc")" = "$MAC_LIB_SHA256" ] || fail "the Mac engine library does not match its fingerprint."
[ "$(sha "$F/Headers/zcashlc.h")" = "$HEADER_SHA256" ] || fail "the engine header does not match its fingerprint."
echo "Zecky engine v4.0.0-zecky.2 (3a69cb0) checked."
