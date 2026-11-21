#!/bin/bash
# Reproducible build of Zecky Lock it for Mac (issue #2, Andrew Miller).
#
# Why fixed paths: Swift's #file and C's __FILE__ put the full path of each
# source file into the program. Built in place, that is this Mac's user
# folder and Xcode's DerivedData folder (a random name per Mac): 468 such
# paths in build 11, so no two Macs built the same program. Built from the
# same fixed folders, the paths are the same everywhere (and name no user).
#
#   TEAM=<your team id> scripts/reproducible-archive.sh [label]
#
# Copies this repository and the engine (at ../ZeckyEngine/zecky-engine) to
# /tmp/zecky-build, builds the Release archive there with its own DerivedData,
# and puts the archive where Xcode's Organizer finds it (to upload) or in
# $OUT. Needs the same Xcode as the build you compare with (docs/
# ATTESTED_STATEMENTS.md, "Rebuild and compare"). Signing changes nothing
# that the comparison looks at, so any team works.
set -euo pipefail

TEAM="${TEAM:?set TEAM to your Apple team ID, e.g. TEAM=ABCDE12345}"
LABEL="${1:-repro}"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$(cd "$SRC/../ZeckyEngine/zecky-engine" && pwd)"
BUILD=/tmp/zecky-build
OUT="${OUT:-$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/ZeckyLockIt $LABEL $(date +%H.%M).xcarchive}"

echo "reproducible-archive: Lock it $(git -C "$SRC" rev-parse --short HEAD), engine $(git -C "$ENGINE" rev-parse --short HEAD)"
if [ -n "$(git -C "$SRC" status --porcelain -- . ':!ZeckyLockIt.xcodeproj/project.pbxproj')" ]; then
  echo "reproducible-archive: note: uncommitted changes besides the team line; the build will not match the commit." >&2
fi

rm -rf "$BUILD"
mkdir -p "$BUILD/ZeckyEngine"
# The engine with its built libraries (LocalPackages is not in git), and
# Lock it with GoMax/bin (not in git either; both pinned by hash).
/usr/bin/rsync -a --exclude target/ --exclude .build/ "$ENGINE/" "$BUILD/ZeckyEngine/zecky-engine/"
/usr/bin/rsync -a --exclude DerivedData/ --exclude build/ "$SRC/" "$BUILD/ZeckyLockItMac/"

cd "$BUILD/ZeckyLockItMac"
xcodebuild archive \
  -project ZeckyLockIt.xcodeproj -scheme ZeckyLockIt -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD/DerivedData" \
  -clonedSourcePackagesDirPath "$BUILD/SourcePackages" \
  -archivePath "$OUT" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" | grep -E "error:|warning: Go Max|ARCHIVE (SUCCEEDED|FAILED)|Go Max:" || true

APP="$OUT/Products/Applications/Zecky Lock it.app"
[ -d "$APP" ] || { echo "reproducible-archive: no app in the archive." >&2; exit 1; }
LEFT=$(strings -a "$APP/Contents/MacOS/Zecky Lock it" | grep -c "$HOME" || true)
echo "reproducible-archive: $LEFT paths with this Mac's home folder left in the program (should be 0)."
echo "reproducible-archive: archive at $OUT"
echo "Compare with another build:  python3 tools/verify-statement/verify_statement.py --compare-apps \"$APP\" \"<other>.app\""
