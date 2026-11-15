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

1. Mac: the `zecky-wallet` onion service with client authorization, the
   read-only filter, the QR, the paired phones list.
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
