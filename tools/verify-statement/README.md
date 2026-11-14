# verify-statement (experiment)

Checks a Zecky attested Go Max statement (format `zecky-attested-statement/v0`)
on your own computer. No Zecky server is involved.

```
pip install cryptography
python3 verify_statement.py statement.json --app-id <team id>.app.zecky.lockit
```

## Asking a node for a fresh statement (v1)

A Lock it debug build with the developer switch on answers challenges on its
own Mac only (127.0.0.1:8139). Send 32 random bytes and check the answer is
for exactly those:

```
c=$(openssl rand -hex 32)
curl -s "http://127.0.0.1:8139/statement?challenge=$c" > statement.json
python3 verify_statement.py statement.json --app-id <team id>.app.zecky.lockit --challenge $c
```

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
