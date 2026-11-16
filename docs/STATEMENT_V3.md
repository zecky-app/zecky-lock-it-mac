# Genuine node answers, format v3 (spec, for build 10)

Status: draft, 16 Nov 2026, for approval before any code. Answers Andrew
Miller's review (issues #3, #4, #5, part of #6, and point 1 of #8 as far as
it touches finding other nodes).

## What changes, in one sentence

Everything a checker relies on goes into the signed client data, the key
attestation is bound to Apple's certificate in every answer, and Apple's
facts are read only from the part of the answer that was signed now.

## 1. The signed client data (v3)

Canonical JSON (sorted keys, no spaces), hashed and signed by the App
Attest key as before. New in v3: everything below except `challenge`,
`purpose`, `fingerprintSHA256` and `node.state/tip/estimate`, which v2
already signed.

```
{
  "v": 3,
  "purpose": "zecky-go-max-state",
  "challenge": "<64 hex>",
  "createdAt": "2026-11-16T15:00:00Z",
  "appId": "W2F7RNV886.app.zecky.lockit",
  "lockIt": {"version": "0.2.0", "build": "10"},
  "onion": "<56 characters>.onion",
  "node": {"state": "up-to-date", "tip": 3579300, "estimate": 3579301,
           "build": "v1.8.8", "subversion": "/Zakura:1.8.8/"},
  "nodeCheck": {"ownNode": true, "portOwnedByOwnNode": true,
                "executableSignedBySameTeamAsLockIt": true},
  "fingerprintSHA256": "<64 hex or empty>"
}
```

- `onion`: the node's own onion address while it answers over Tor, empty
  otherwise. A checker that asked an onion address requires exactly that
  address here. A relay that forwards challenges to a genuine node gets an
  answer naming the genuine node's address, not its own, and is refused
  (#8 point 1, applied to "Finding other nodes").
- `createdAt`: signed, so the "attested before the answer" check means
  something (until now it read an unsigned field).
- `lockIt`, `node.build/subversion`, `nodeCheck`, `appId`: signed (#3).
  The answer no longer repeats them outside the client data; checkers read
  them from the signed copy only.

Privacy: the onion address was already in every answer's transport; signing
it adds nothing new for an asker. A statement saved with "Make a statement"
carries it too; the explanation says so.

## 2. Binding the key attestation in every answer (#4, #5)

- When the node attests a new key, it keeps the client data that
  attestation was made over (`attest.<environment>.attestationClientData`,
  next to the attestation).
- Every assertion answer ships it as `keyAttestationClientDataJSON`.
- Checkers recompute the key attestation's nonce,
  `SHA256(attAuthData + SHA256(keyAttestationClientDataJSON))`, and require
  it in Apple's leaf certificate. Only then is the key attestation's data
  (environment, credential) trusted.
- A stored key without its client data (every key made before build 10) is
  replaced once: one more contact with Apple, written in the log.

## 3. Apple's facts (#2)

- Build number, validation category and CDHash are read only from the
  authData signed in this answer: the assertion's for an assertion, the
  attestation's for a first answer. Never from the stored key attestation:
  a key attested by one build can be used by another (seen in build 8: key
  attested by an Xcode build, category 3; answers from TestFlight build 8,
  category 2).
- The CDHash is shown when present. Comparing it with an expected value
  needs reproducible builds and depends on the signer (#2 correction); not
  in build 10.

## 4. The node behind the port (#6, first part)

- Before signing a node state or fingerprint, Lock it checks that the
  socket listening on 127.0.0.1:8232 belongs to the zakurad process Lock it
  started (its process id, read from the system on this Mac). If not:
  `ownNode` false, state `not-running`, no fingerprint.
- Not in reach, said plainly in the docs: whoever owns the Mac can give the
  node different chain data (its folder), and a genuine Lock it then signs
  what that node says. An answer means "Lock it from the Zecky team ran on a
  Mac with SIP on and asked its own node", not an independent check of the
  chain. Quorum ideas must count it that way.

## 5. Checkers (verify_statement.py and Lock it's StatementCheck)

Same rules in both, in this order:

1. Format v3; client data canonical; `v` 3 and the purpose.
2. Challenge equals the one sent.
3. Onion equals the address asked (when asked over Tor).
4. appId equals the expected app.
5. Apple's chain at the moment the key was attested; Apple's intermediate
   still valid; macOS key policy (SIP, full security).
6. First answer: its nonce. Later answers: the key attestation's nonce
   (section 2), then the assertion's signature and a counter above zero.
7. Key ID equals the attested key; credential ID equals the key ID.
8. createdAt not before the key was attested.
9. Apple's facts from the signed authData of this answer only.

Older answers (v1, v2) are shown as "older format, not fully checked" and
never count in "Genuine nodes known".

## Tests (each first reproduced, then fixed)

- #5: a hand-written answer is refused (reproduced 16 Nov: refused).
- #4: an edited environment in the key attestation is refused (reproduced 16
  Nov with the Python verifier: passed, which is the gap).
- #3: an edited lockIt.build or node.build is refused.
- #8.1: an answer relayed through another onion address is refused.
- #2: an assertion without facts does not borrow the key attestation's.
- #6: with zakurad killed and another program on port 8232, the answer
  says not-running and carries no fingerprint.

## Not in build 10

- A signer-independent digest of each helper (zakurad, zainod, arti,
  libswiftCompatibilitySpan.dylib) compiled into Lock it and checked before
  every start (#3 correction, #8 point 2). Next, separately.
- Reproducible builds and admitting by CDHash (#2).
- Pairing: channel binding, loopback TLS or a Unix socket, logs (#8).
