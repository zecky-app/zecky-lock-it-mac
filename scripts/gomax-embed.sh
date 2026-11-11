#!/bin/bash
# Build step "Go Max programs": puts the node (zakurad) and its light-wallet
# server (zainod) into the app, next to Lock it's own program in
# Contents/MacOS, signed with the app's identity and GoMax/Helpers.entitlements
# (they run inside Lock it's sandbox). Xcode signs the app itself after this.
#
# They come from GoMax/bin (not in git; scripts/gomax-helpers.sh puts them
# there) and must match their SHA-256 in GoMax/bin.sha256, or the build stops.
# Without them the app builds as before, and Settings › Go Max says this
# build has no node inside.
set -euo pipefail

ROOT="${PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$ROOT/GoMax/bin"
PINS="$ROOT/GoMax/bin.sha256"
DEST="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"

rm -f "$DEST/zakurad" "$DEST/zainod"

if [ ! -x "$SRC/zakurad" ] || [ ! -x "$SRC/zainod" ]; then
  echo "warning: Go Max: no node programs in GoMax/bin, so this build has no node inside (see scripts/gomax-helpers.sh)."
  exit 0
fi
[ -f "$PINS" ] || { echo "error: Go Max: GoMax/bin.sha256 is missing." >&2; exit 1; }
( cd "$SRC" && /usr/bin/shasum -a 256 -c "$PINS" >/dev/null ) || {
  echo "error: Go Max: the programs in GoMax/bin do not match GoMax/bin.sha256. Refused." >&2; exit 1; }

for f in zakurad zainod; do
  /bin/cp "$SRC/$f" "$DEST/$f"
  # Its own identifier under Lock it's, so App Store Connect can tell the
  # two programs apart.
  /usr/bin/codesign --force --options runtime --timestamp=none \
    --identifier "${PRODUCT_BUNDLE_IDENTIFIER:-app.zecky.lockit}.$f" \
    --entitlements "$ROOT/GoMax/Helpers.entitlements" \
    --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$DEST/$f"
done
echo "Go Max: zakurad and zainod are in the app."
