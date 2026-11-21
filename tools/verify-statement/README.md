# verify-statement (experiment)

Checks a Zecky attested Go Max statement (format `zecky-attested-statement/v0`)
on your own computer. No Zecky server is involved.

```
pip install cryptography
python3 verify_statement.py statement.json --app-id <team id>.app.zecky.lockit
```

## Asking a node for a fresh statement

A Lock it debug build with the developer switch on answers challenges on its
own Mac only (127.0.0.1:8139). Send 32 random bytes and check the answer is
for exactly those:

```
c=$(openssl rand -hex 32)
curl -s "http://127.0.0.1:8139/statement?challenge=$c" > statement.json
python3 verify_statement.py statement.json --app-id <team id>.app.zecky.lockit --challenge $c
```

With "Answer over Tor too" on as well, the same endpoint is an onion
service (the address is shown under the switch). From any computer with Tor
running, one command makes a challenge, asks, and verifies:

```
./ask_over_tor.sh <address>.onion <team id>.app.zecky.lockit [socks port]
```

The SOCKS port is 9150 for Tor Browser (keep it open) and 9050 for the
`tor` service. Publishing a new onion can take a minute, so the script tries
three times.

Before answering, Lock it checks that the node it reads is its own: it
found Go Max's ports free, started the `zakurad` inside Lock it on them, the
node is still running, and that `zakurad` file is validly signed by the same
team as Lock it. It says so in the statement. macOS does not let a sandboxed
app inspect other processes, so Lock it cannot look at the listening process
itself. A verifier cannot prove the check from outside; it is as trustworthy
as the app that made it.

## What it checks

1. Apple's certificate chain: leaf, intermediate, and the pinned Apple App
   Attestation Root CA (`apple_app_attestation_root_ca.pem`, SHA-256
   `1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932`).
2. The app: Apple's record is for `<team id>.<bundle id>`, the one you name.
3. The fingerprint: the statement's hash is the SHA-256 of its fingerprint
   text, and Apple's nonce (first statement of a key) or the key's own
   signature (later statements) covers exactly that hash.
4. The key: its ID is the SHA-256 of the attested public key.

5. From v2: the node's state (up to date, syncing at block T of about E, or
   not running) is signed with the answer. A v2 answer always proves the app
   is genuine; it carries a chain fingerprint only when the node can vouch
   for that height, and otherwise says why not.
6. What Apple's App Attest service writes into the signed data itself, not
   the app: the app's build number and, when the app opted in, its code
   fingerprint (CDHash). `--build 9` and `--cdhash <hex>` require them.

It also says which App Attest environment made it: development or production.

## What a pass means, and what it does not

A pass means: an app signed by that team, with that bundle ID, on an Apple
device that supports App Attest (on a Mac: macOS 27 or later, with System
Integrity Protection on), produced this fingerprint.

It does not mean the fingerprint is right, and it does not say which version
or which source code of the app made it: every build signed by the team
passes. Fingerprint v0 also does not cover the spent-note (nullifier) sets or
the transparent coin set, so it confirms a checkpoint, not a full chain state.

## The root certificate

The pinned file is Apple's public App Attestation root. To check it yourself,
download it from Apple and compare:

```
curl -sO https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
openssl x509 -in Apple_App_Attestation_Root_CA.pem -noout -fingerprint -sha256
```

7. Apple's chain is checked at the moment Apple attested the key (its
   certificate is valid for three days; the key lives on in the Mac's
   security chip), and Apple's intermediate must be valid today. On macOS
   the key's access policy must show System Integrity Protection and full
   security on, as Apple asks.
8. Format v3 (build 10, after Andrew Miller's review): everything the
   checks rely on is read from the signed client data only: the app, when
   it was made, Lock it's version and build, the node's version, Lock it's
   own-node check, and the onion address that answered. `--onion` checks
   that the answer names the address you asked, so an answer relayed
   through another onion address is refused. In later answers the key
   attestation is bound by its own client data
   (`keyAttestationClientDataJSON`), and Apple's facts are read from the
   answer's own signed data only. Older formats (v0 to v2) are refused.
9. Which code (build 12, issue #2): answers carry `codeIdentity`, the
   running program's CodeDirectory, first page and entitlements. The
   verifier requires the CodeDirectory's SHA-256 to be the CDHash Apple
   attests in the answer, the first page and the entitlements to be the
   ones it hashes, and Apple's rpIdHash to be SHA-256 of the app ID in those
   entitlements. `--app-id` is then optional (team and bundle ID are free).
   With `--reference "<your build>.app"` it checks the answer runs exactly
   the code of your own build of the published source, whoever signed each
   (every page hash but the first, the code limit, the flags, the first
   page without its signer fields, the entitlements without team and app
   ID). `--compare-apps A.app B.app` compares two builds directly. How to
   rebuild: docs/ATTESTED_STATEMENTS.md, "Rebuild and compare".
