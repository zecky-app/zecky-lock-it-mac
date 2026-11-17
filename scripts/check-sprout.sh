#!/bin/bash
# Refuses a zakurad that was built without Zakura's `sprout` feature.
#
#   scripts/check-sprout.sh path/to/zakurad
#
# Why: since Zakura 1.8.8 Sprout verification is opt-in (`--features sprout`,
# zakura PR #2466). Go Max syncs with checkpoint_sync = false, so every block
# since Canopy is verified here, and a build without Sprout stops for good at
# the first post-Canopy block with a Sprout JoinSplit (SproutVerifierNotBuilt).
# Builds 9 and 10 shipped like that.
#
# How: Zakura only compiles its Sprout Groth16 verifying key into the program
# when `sprout` is on (zakura-consensus primitives/groth16 is behind that
# feature, and the key is include_bytes!("sprout-groth16.vk")). GoMax/
# sprout-groth16.vk is a copy of that public key, pinned below; the program
# must contain it byte for byte.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="$ROOT/GoMax/sprout-groth16.vk"
KEY_SHA256="4f8894d5456596e912d8a55c138c155f338131ea4ec747847b5dd6dba5efabdc"
PROGRAM="${1:?usage: check-sprout.sh path/to/zakurad}"

[ -f "$KEY" ] || { echo "error: Go Max: GoMax/sprout-groth16.vk is missing." >&2; exit 1; }
echo "$KEY_SHA256  $KEY" | /usr/bin/shasum -a 256 -c - >/dev/null || {
  echo "error: Go Max: GoMax/sprout-groth16.vk is not Zakura's Sprout key." >&2; exit 1; }

/usr/bin/python3 - "$PROGRAM" "$KEY" <<'PY' || {
import sys
program = open(sys.argv[1], "rb").read()
key = open(sys.argv[2], "rb").read()
sys.exit(0 if key in program else 1)
PY
  echo "error: Go Max: $PROGRAM was built without Sprout. Rebuild Zakura with --features sprout (docs/NODE_UPDATES.md). Refused." >&2
  exit 1
}
echo "check-sprout: $(basename "$PROGRAM") has Sprout verification."
