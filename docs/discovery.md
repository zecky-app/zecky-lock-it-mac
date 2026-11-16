# Go Max nodes finding each other (built for build 9, not yet tested)

Status: 16 Nov 2026. Built in `GenuineNodes` (AttestedStatement.swift), not yet tested.
Every check is Lock it's own full check (`StatementCheck`): Apple's chain to
the pinned root, the key, the signature over a fresh challenge, the app ID.
The list is kept in GoMax/genuine-nodes.json (addresses and check times only).

Goal: a Go Max node finds other genuine Go Max nodes by itself, checks each
one, keeps the genuine ones and drops the rest, without a Zecky server and
over Tor only. Uses: a new node starting faster from a point many genuine
nodes confirm, and more nodes to check against.

Not for the Zcash peers a node syncs with: those run all kinds of software,
and the node checks every block they send against consensus. Genuine node
does not apply to them.

## Choice: gossip between Go Max nodes

Considered and not chosen: a list on a Zecky server (a central point), a
list in the repository (public forever, manual), the Zcash network's own
address messages (meant for Zcash peers), Nostr or an on-chain registry (an
outside dependency; dsmack uses a chain). Gossip needs nothing outside the
nodes themselves; Bitcoin nodes find each other the same way.

## How it works

1. **Two roles.** Asking (looking for genuine nodes) gives nothing away and
   is always allowed while Genuine node is on. Being found is a separate
   switch: "Share my address with other Go Max nodes".
2. **Start.** The nodes the owner checked by hand ("Check another node") are
   the first known nodes. Owners can paste more addresses from the test group.
3. **Asking around.** A node with sharing on also answers `GET /peers` over
   its onion service: up to 20 addresses it has checked as genuine in the
   last week and that have sharing on themselves. Same request limit as
   `/statement`.
4. **Checking.** Every new address is asked for a fresh statement before it
   counts. Only genuine nodes (the expected app ID, Apple's chain, a fresh
   challenge) are kept.
5. **Keeping the list fresh.** Known nodes are checked again about once a day
   at a random time; a node that fails three times in a row, or answers but
   is not genuine, is dropped. At most 50 known nodes.
6. **In the app.** One line in the Genuine node card: "Genuine nodes known:
   4". Tapping it shows the list (address shortened, last checked, build).

## Defaults

- While testing: sharing off by default; testers are asked to switch it on.
- At go-live, together with Genuine node: on by default with Go Max, said in
  one line in the Go Max explanation, with the switch to turn it off.

## What it costs and what can go wrong

- An address with sharing on spreads to every node that knows it. Others can
  see when that node is online and that it is always the same node. The IP
  address stays hidden behind Tor.
- A node can pass on fake or dead addresses; they cost a check each and are
  never kept.
- A few nodes could fill everyone's lists. With a test group of ten that is
  no issue; later, prefer addresses learned from several nodes and cap what
  one node may add.
- Every check is a Tor connection; once a day per node keeps the load small.

## Not in this step

- Using the known nodes for a faster start (the group check). That needs the
  full chain-state fingerprint (see ATTESTED_STATEMENTS.md).
- Preferring genuine Go Max nodes among the Zcash peers.
