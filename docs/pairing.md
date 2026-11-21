# Go Max phone pairing (spec, not built)

Status: approved 15 Nov 2026; the Mac side is built first. Nothing here is
built yet. One design
for every combination: any phone (Lock it iPhone now, Android later) pairs with
any Go Max (Lock it Mac now, Lock it Windows next). The desktop side is built
once per desktop app, the phone side once per phone app; the QR code, the
connection and the rules below are the same everywhere.

Goal: a phone reads the chain from its owner's own Go Max node, at home and
away, over Tor, without an account, a server or an extra app, and without
opening anything on the computer to anyone else.

## 1. The QR code

Shown on the Go Max page under "Pair a phone", one QR per phone, after Touch ID
or the computer's password. It is a URI:

```
zecky-pair:1?onion=<56 chars>.onion&auth=<client key, base32>&check=<6 chars>&name=<node name>
```

- `onion`: the node's wallet onion address. A v3 onion address is the node's
  own public key, so a phone that connects to it reaches this node and no
  other: it is the node's fingerprint and cannot be faked.
- `auth`: the private half of a client authorization key (x25519) made for
  this one phone. The computer keeps only the public half, under the phone's
  name. The private half exists in the QR and on the phone, nowhere else.
- `check`: a short code shown on both screens after pairing (derived from the
  onion address and the client key), so the owner sees the phone scanned this
  computer's QR and not another one.
- `name`: what the phone calls the node (for example "Home Mac", chosen by the
  owner), nothing more.
- `1`: format version. A phone refuses versions it does not know.

Because the QR holds a secret: it is shown only after Touch ID or the
password, hidden from screen capture (as the recovery phrase is), and it
disappears after 5 minutes or as soon as a phone confirms the pairing. A QR
that was photographed or shared is a pairing someone else can use, so the
screen says "Only scan this with your own phone".

No home-network (LAN) address in the QR for now: a LAN route means Zaino
listening on the network, which breaks rule 5. It can be added later as a
separate, explicit choice.

## 2. How the phone connects

- The phone runs Tor (Arti, inside the phone app) and connects to
  `<onion>:443` with its client authorization key. Tor's onion client
  authorization means the service's address and descriptor are useless
  without a valid client key: unpaired phones and strangers cannot even reach
  the service, let alone send it requests.
- On the computer, Arti runs a second onion service, separate from the
  Genuine node one: `zecky-wallet`, with client authorization on, forwarding
  to Lock it's read-only filter on 127.0.0.1, which forwards to Zaino
  (127.0.0.1:8137).
- Everything stays inside Tor end to end: no TLS certificates, no ports on the
  router, no relay or server run by Zecky.
- The phone keeps the same order it has today: when the paired node cannot
  be reached, it says so and offers its usual server, as a choice, never by
  itself.

## 3. What the phone can do

Read only: wallet sync through Zaino's light-wallet interface (blocks, compact
blocks, tree states, transactions, mempool for the phone's own view). Nothing
else:

- No control of the node: no start, stop, settings, logs or Zakura RPC. The
  Zakura RPC (8232) is never reachable from outside, paired or not.
- Sending: the phone broadcasts its own payments over Tor, as Lock it does
  today, never through the node: through the node, the home node would be the
  one that first relays the phone's payment.
- A filter in Lock it between Arti and Zaino passes only the read calls and
  refuses everything else, so a newer Zaino with more calls cannot widen what
  a phone can do by accident.

## 4. Paired phones, removing one, a lost phone

- Go Max page, Advanced box: "Paired phones", a list of names with the date
  each was paired, and "Remove" per phone.
- Remove: the phone's public client key is deleted from Arti and the wallet
  onion service is restarted; from then on that phone cannot reach the node.
  Its wallet keeps working on its usual server.
- Tor does not tell the service which client connected, so the list cannot
  show "last seen" per phone. It says so instead of guessing.
- Lost phone: remove it. The phone could only ever read chain data from the
  node; the node never held the phone's keys, and the phone's own wallet is
  protected by the phone and its recovery phrase as before.
- "Remove all and change address": a new wallet onion address; every phone
  pairs again. For when the owner is unsure who has seen a QR.
- Up to 10 phones per node.

## 5. What stays off until paired

- No phone paired: the wallet onion service does not run. Nothing on the
  computer accepts connections from outside, exactly as today.
- Zaino and Zakura keep listening on 127.0.0.1 only, paired or not.
- The Genuine node onion service is separate and keeps its own switch (off by
  default).
- Removing the last phone stops the wallet onion service again.

## 6. Room for attestation later (not built now)

Where the Genuine node work fits, after Andrew Miller's idea of apps proving
they are genuine:

- Phone checks the node: right after pairing, and later now and then, the
  phone asks the node over the paired channel for a statement with a fresh
  challenge (`/statement`, as Genuine node does today) and checks it is
  genuine Lock it on a real Mac. The pairing screen can then show "Genuine
  node" next to the check code. Windows has no App Attest, so a Windows node
  shows "not attested" there, honestly.
- Node checks the phone: the phone app could prove it is genuine Lock it
  iPhone (iOS App Attest) or Lock it Android (key attestation) when it
  pairs; the computer would show it in the paired phones list.
- Both need nothing new in the QR: the `1` version leaves room for a field
  later, and the checks run over the channel the pairing already makes.

### What an attested Zaino needs (Andrew Miller's review, issue #8)

A light-wallet server never sees keys, but it sees the phone's sync ranges,
timing, transparent lookups and submitted transactions, and decides which
chain data the phone gets. "Genuine node" on the pairing screen only means
something for the phone if these three hold. Requirements before pairing
shows it:

1. **Bind the channel to the attestation.** A statement must name the
   address that served it, or anyone can run their own onion, forward
   `/statement` to a genuine node and serve their own Zaino. Done for Genuine
   node answers in format v3 (16 Nov 2026, commit ad5548a): the signed client
   data names the node's onion address and checkers require it to equal the
   address they asked. For pairing: the wallet onion (`zecky-wallet`) is a
   second address, so its address (or the TLS key Zaino serves, see 3) goes
   into the signed data too, and the phone checks it equals the address in
   the QR it scanned. Statements asked over the paired channel only.
2. **Measure the helpers, not just the app.** App Attest (with the CDHash)
   measures only Lock it's main binary; zainod and zakurad are separate
   programs, and until build 11 Lock it only checked they carry the same team ID. Per
   Andrew's correction, a CDHash pinned per helper breaks with every signer
   (TestFlight re-signing, self-builds). Instead: a signer-independent digest
   of each nested Mach-O (zakurad, zainod, arti, libswiftCompatibilitySpan
   .dylib), compiled into Lock it and checked against the file on disk
   before every start; Lock it refuses a helper that does not match. Lock
   it's own CDHash, attested, then covers that check. **Done for build 12**
   (`NestedCode` in GoMaxNode.swift, `scripts/nested-code-pins.py`), with
   `libzcashlc` added. Next code item after
   the review fixes; needed before pairing ships.
3. **Close the plain loopback hop.** Arti hands onion traffic to a port on
   127.0.0.1 in plain TCP (today 8139; for pairing, the read-only filter in
   front of Zaino). An administrator on the Mac could record lo0 and read
   every request without touching any process. Options: TLS between Arti
   and the filter (a key made and kept by Lock it, its public half in the
   signed statement, so the phone can pin it), or a Unix socket inside Lock
   it's container if Arti can forward to one. To decide when building; one
   of the two before pairing ships.
4. **Logs.** zainod and zakurad write logs into Lock it's folder. What they
   log is part of the audited code: no wallet addresses, transaction IDs or
   phone-identifying data at the log level Go Max runs them at. To check per
   release.

With these, #2 (CDHash) and reproducible builds, the trust model for a paired
phone becomes Apple's root, the published source and macOS with SIP on; the
Mac's owner is mostly excluded, except for the node's chain data (issue #6:
the data seal and the cross-check narrow that).

## 7. Test matrix

| Phone | Node | Pair | Sync at home (Wi-Fi) | Sync away (mobile data) | Remove | Lost-phone path | Attestation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Lock it iPhone | Lock it Mac | first | first | first | first | first | later |
| Lock it iPhone | Lock it Windows | second | second | second | second | second | not attested |
| Lock it Android | Lock it Mac | later | later | later | later | later | later |
| Lock it Android | Lock it Windows | later | later | later | later | later | not attested |

Each row also checks: an unpaired phone with the onion address cannot
connect; a removed phone cannot connect; Zakura RPC is unreachable over the
pairing; the computer accepts no outside connections with no phone paired;
the QR disappears after 5 minutes and after pairing; node offline gives the
phone a clear message and a choice.

## Build order (after approval)

1. Mac: the helper digests (section 6, point 2; done for build 12); then the `zecky-wallet`
   onion service with client authorization, the read-only filter behind TLS
   or a Unix socket (point 3), the QR, the paired phones list.
2. iPhone: Arti, scanning the QR, syncing through the paired node.
3. Test row 1, then Windows (row 2), then Android.

## Decided (15 Nov 2026)

- Read only. The phone syncs its wallet through the node and sends its own
  payments over Tor itself, never through the node, so a payment is never
  first seen from the home internet address ("own node for reading, Tor for
  sending").
- Up to 10 phones per node.
- Tor only, at home too: no home-network address in the QR for now.
- Port 443 on the onion.
- The phone syncs through the node while the app is open first; background
  sync over Tor is tested before it is promised.

## Findings before building (16 Nov 2026)

- Arti 2.8.0 as bundled with Lock it already has restricted discovery
  (Tor's new name for client authorization) compiled in: the config
  section `restricted_discovery` with `enabled`, `static_keys` and
  `key_dirs`. No new Arti build and no change to the Arti pin needed.
- One file per phone in a key directory, `<phone id>.auth`, holding
  `descriptor:x25519:<public key, base32>`. With `watch_configuration` on,
  Arti picks up an added or removed file by itself: no restart. Each change
  publishes a new descriptor, so changes are batched.
- Ten phones is far below the limit (the descriptor size caps it).
- **Correction to section 4.** Tor says removing a client "doesn't
  guarantee" its access ends: a removed phone may still reach the service
  through introduction points it already knows, for a while. And: restricted
  discovery is protection against being found and flooded, "not a
  substitute for conventional access control". So removal needs a second
  lock that works at once:
  - Proposed: the QR also carries a per-phone secret (`token=`, 32 random
    bytes), sent by the phone with every request (a gRPC header). The
    read-only filter refuses any request without a known token. Remove
    deletes the token (instant) and the `.auth` file (Tor side).
  - The Tor key keeps the service hidden from everyone without a QR; the
    token decides who may read. "Remove all and change address" stays for
    when the owner is unsure who has seen a QR.
  - Decided 16 Nov 2026: yes, the per-phone secret is part of pairing.
