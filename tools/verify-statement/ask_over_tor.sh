#!/bin/sh
# Ask a Go Max node for an attested statement over Tor, with a fresh
# challenge, and verify the answer. Runs on any computer with Tor running
# (Tor Browser: SOCKS port 9150; the tor service: 9050; Lock it's own Arti in
# a debug build: 9150), curl, openssl and Python 3 with `cryptography`.
#
#   ./ask_over_tor.sh <address>.onion <team id>.<bundle id> [socks port]
#
# HEIGHT=<block height> asks for that height instead of the node's tip − 100
# (a node behind it, or no longer keeping it, says so).
# Saves the answer as statement-<time>.json in the current folder.
# Licence: Apache-2.0, as the rest of Zecky Lock it.
set -eu
[ $# -ge 2 ] || { echo "usage: $0 <address>.onion <team id>.<bundle id> [socks port]" >&2; exit 2; }
ONION=$1
APP_ID=$2
PORT=${3:-9150}
HEIGHT=${HEIGHT:-}
case "$HEIGHT" in ''|*[!0-9]*) [ -z "$HEIGHT" ] || { echo "HEIGHT must be a number" >&2; exit 2; } ;; esac

case "$ONION" in *.onion) ;; *) echo "not an onion address: $ONION" >&2; exit 2 ;; esac
HERE=$(cd "$(dirname "$0")" && pwd)
CHALLENGE=$(openssl rand -hex 32)
OUT="statement-$(date +%Y%m%d-%H%M%S).json"
QUERY="challenge=$CHALLENGE${HEIGHT:+&height=$HEIGHT}"
echo "Challenge: $CHALLENGE"
echo "Asking $ONION through Tor (SOCKS 127.0.0.1:$PORT)…"
try=1
while :; do
  code=$(curl -s --max-time 120 --socks5-hostname "127.0.0.1:$PORT" \
          -o "$OUT" -w '%{http_code}' "http://$ONION/statement?$QUERY" || true)
  [ "$code" = 200 ] && break
  if [ "$code" != 000 ]; then
    # The node answered, but not with a statement: say why (behind, not
    # settled, no longer kept, busy) and stop.
    echo "The node answered $code: $(cat "$OUT")" >&2; rm -f "$OUT"; exit 1
  fi
  [ $try -lt 3 ] || { echo "No answer after 3 tries. Is the node on, and Tor running on port $PORT?" >&2; rm -f "$OUT"; exit 1; }
  echo "No answer yet (try $try of 3); the onion may still be publishing. Again in 30 s…"
  try=$((try + 1)); sleep 30
done
echo "Saved $OUT"
exec python3 "$HERE/verify_statement.py" "$OUT" --app-id "$APP_ID" --challenge "$CHALLENGE" ${HEIGHT:+--height "$HEIGHT"}
