# Node updates: Zakura and Zaino across the Zecky products

Written 11 Nov 2026. Read this before changing the version of either program
in any product.

## Why this is a rhythm, not a one-time job

Every Zakura release stops following the chain at a fixed block height, about
45 days after it comes out (`EOS_PANIC_AFTER = 45` in
`crates/zakurad/src/components/sync/end_of_support.rs`). A node that is not
updated before that height halts. So a new node version is due roughly every
six weeks.

**Next stop: height 3,643,309, about 5 Dec 2026.** Read from the code of both
v1.8.5 and v1.8.6; the comment there says the date is fixed even for later
release preparation, so only a release after 1.8.6 can move it.

Not checked: whether Zaino has a stop date of its own.

## Versions (the one place they are written down)

| | Shipped now | Newest seen (11 Nov 2026) |
|---|---|---|
| Zakura | v1.8.5, commit `fe180bc` | v1.8.6, commit `eabee4d`, released 10 Nov 2026 |
| Zaino | branch `feat/nu7`, commit `aaf8122` (2 Nov 2026) + the two Rock it patches | `feat/nu7` still at `aaf8122`. Tag `zainod-0.10.2` (11 Oct 2026) predates NU7; not checked whether it follows the chain after NU7 |

Sources: github.com/zakura-core/zakura, github.com/zingolabs/zaino.

Where each product pins them:

| Product | Runs a node | Pinned in |
|---|---|---|
| Rock it (Umbrel) | yes | the Rock it repository (0.3.17 = Zakura 1.8.5) |
| Lock it Mac, Go Max | yes, bundled in the app | `GoMax/bin.sha256`, header of `scripts/gomax-helpers.sh` |
| Lock it Mac without Go Max, Lock it iPhone, Pocket | no | nothing to update; they only lose a server if they point at a node that stopped |
| Rock it iPhone | not looked at when this was written | |

Rock it and Lock it Mac ship the same two commits. When this table changes,
both change, Rock it first.

## What 1.8.6 changes (from its CHANGELOG, not yet run by us)

- Security: four limits on what misbehaving peers can make the node hold or occupy.
- Two fixes where header sync could shut the node down by mistake.
- RPC: admin methods refuse requests that carry a browser `Origin` header.
  Not checked against our open item (cookie on the control port).
- No mention of pruning or of the state format. Whether the synced data
  carries over is unverified until it is run.

## The checklist, same every time

1. Read the CHANGELOG between the shipped and the new version. Note anything
   about pruning, the state format, RPC, config names and the stop height.
2. Read the new stop height from `end_of_support.rs`, write it at the top
   of this file, and set `GoMaxSupport.stopHeight` in `ZeckyLockIt/GoMax.swift`
   to it. Lock it's notice and its stop message follow that number.
3. Build both programs with the home folder remapped (the exact build
   commands are not written down yet: record them here at the first update).
4. Rock it on the owner's Umbrel first, with the owner's OK. Let it run for
   a few days.
5. Lock it Mac: run the new `zakurad` on the existing Go Max data. Watch for
   a resync, which would mean the data did not carry over.
6. `scripts/gomax-helpers.sh`, commit the new `GoMax/bin.sha256`, update the
   header of that script and the table above.
6b. Acknowledgements: update the version and commit in `scripts/notices.py` (go_max) and in `ZeckyLockIt/Acknowledgements.md`, and copy the new release's license files into `scripts/licenses/` if they changed. Both programs ship inside the app, so their licenses must travel with it.
7. Tests: `xcodebuild test`, then by hand: receive, send over Tor, send with
   Wi-Fi off, Go Max off and on, quit and reopen.
8. Update `SettingsView` (About, How Zecky works) if any statement changed.
9. New build number, TestFlight.

## The gap this leaves on Mac

On Umbrel an update is quick. On Mac the node is inside the app, so each node
update is an app build that has to pass TestFlight, later App Store review.
If a Zakura release is late, Go Max users can reach the stop height before
the update reaches them.

Built on 12 Nov 2026 (`GoMaxSupport`), not yet seen at a real stop:

- Two weeks of blocks before the stop: "Go Max needs an update before
  <date>" on the Go Max page and on the coin. No pop-up.
- At the stop: the programs are stopped, the node's data is kept, and the
  Go Max page opens once with the choice: the public server from before, or
  wait for the update. Lock it's server is not changed until the owner
  chooses. The choice is remembered until Go Max runs again.
- After the update Go Max starts by itself (it stays switched on) and Lock
  it goes back to the node once it is at the tip.

## Reminder

Three weeks before each stop date, check github.com/zakura-core/zakura for a
new release. For the 5 Dec 2026 stop that is 14 Nov 2026.
