#!/bin/bash
# Static checks on the app's code, like the iPhone app's lint rules.
# Run from the repository root: scripts/check.sh
cd "$(dirname "$0")/../ZeckyLockIt" || exit 1
fail=0
bad() { echo "FAIL: $1"; fail=1; }

# Nothing is ever logged.
if grep -nE '\b(print|debugPrint|NSLog|os_log|dump)\(|Logger\(' *.swift; then bad "logging in the app"; fi

# Every Keychain write goes through KeyStore, this device only, never synced.
for f in $(grep -lE 'SecItem(Add|Update|CopyMatching|Delete)' *.swift); do
  [ "$f" = "KeyStore.swift" ] || bad "Keychain call outside KeyStore: $f"
done
if grep -nE 'kSecAttrSynchronizable as String: true|AfterFirstUnlock|kSecAttrAccessibleAlways|kSecAttrAccessibleWhenUnlocked[^T]' *.swift; then
  bad "weaker or synced Keychain protection"
fi

# The clipboard only for the receive address; the web only for the price.
for f in $(grep -l 'NSPasteboard' *.swift); do [ "$f" = "ReceiveView.swift" ] || bad "clipboard used in $f"; done
for f in $(grep -lE 'URLSession|URLRequest' *.swift); do [ "$f" = "PriceFeed.swift" ] || bad "web request in $f"; done
if grep -n 'NSSharingService' *.swift; then bad "sharing sheet in the app"; fi

# Programs and connections: only Go Max starts programs (its own two) and
# connects to its node, and only on this Mac.
for f in $(grep -lE 'Process\(\)|NWConnection\(' *.swift); do [ "$f" = "GoMaxNode.swift" ] || bad "program or connection outside GoMaxNode: $f"; done
if grep -n 'NWConnection(host' GoMaxNode.swift | grep -v '"127.0.0.1"'; then bad "Go Max connects beyond this Mac"; fi

# The engine never logs.
grep -q 'loggingPolicy: .noLogging' *.swift || bad "engine logging is not switched off"

[ $fail -eq 0 ] && echo "All checks passed."
exit $fail
