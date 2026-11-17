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
v1.8.5, v1.8.6 and v1.8.8 (checked 16 Nov 2026: v1.8.8 moved its
`ESTIMATED_RELEASE_HEIGHT` to 3,575,919 but kept `MAINNET_EOS_HEIGHT` at
3,643,309). The comment there says the date is fixed even when release
preparation advances, so only a release that changes `MAINNET_EOS_HEIGHT`
buys time. Warnings start three days before.

Not checked: whether Zaino has a stop date of its own.

## Sprout: build zakurad with `--features sprout` (17 Nov 2026)

Since v1.8.8 Zakura verifies Sprout JoinSplits only when built with the
`sprout` Cargo feature (PR #2466; v1.8.6 and v1.8.7 had it on by default,
v1.8.5 had no switch and always verified). The official Docker image of
v1.8.8 and v1.8.9 is built without it (`FEATURES="default-release-binaries"`).

A build without it only verifies pre-NU7 blocks above the last checkpoint
badly, by refusing them. With Zakura's checkpoints that range is empty on
mainnet (NU7 at 3,543,405, last checkpoint 3,565,551 in v1.8.8). But Go Max
syncs with `checkpoint_sync = false`, so it verifies every block since
Canopy itself, and a build without Sprout stops for good at the first
post-Canopy block with a Sprout JoinSplit. The error is retryable
(`SproutVerifierNotBuilt`), so the block is not recorded as invalid and a
Sprout build carries on from where it stopped.

Lock it Mac builds 9 and 10 shipped zakurad 1.8.8 without Sprout. A node
already past that point (synced with build 8 or older) is not affected.
Build 11 ships v1.8.9 with Sprout; a node stuck on build 10 carries on from
where it stopped (v1.8.8 never marks the database).

`scripts/check-sprout.sh` now refuses a zakurad without Sprout, in
`gomax-helpers.sh` and again in every Xcode build (`gomax-embed.sh`). It
looks for Zakura's Sprout Groth16 verifying key, which is compiled in only
with the feature (`GoMax/sprout-groth16.vk`, pinned by SHA-256).

v1.8.9 adds a trap (PR #2204): a build without Sprout marks the database at
the first Sprout commitments it skips, and a Sprout build then refuses that
database until its tip is past NU7 and the last checkpoint. So from v1.8.9
on, a node must have Sprout from its first block. v1.8.9 also moves the
database to format 31.0.0, which older releases cannot open.

## Versions (the one place they are written down)

| | Shipped now | Newest seen (16 Nov 2026) |
|---|---|---|
| Zakura | Lock it Mac: v1.8.9, commit `23b79de`, with `--features sprout`, from build 11 (builds 9 and 10: v1.8.8 without Sprout). Rock it: v1.8.5, commit `fe180bc` | v1.8.9, commit `23b79de`, released 16 Nov 2026; same stop height |
| Zaino | branch `feat/nu7`, commit `aaf8122` (2 Nov 2026) + the two Rock it patches | `feat/nu7` still at `aaf8122`. Tag `zainod-0.10.2` (11 Oct 2026) predates NU7; not checked whether it follows the chain after NU7 |

Sources: github.com/zakura-core/zakura, github.com/zingolabs/zaino.

Where each product pins them:

| Product | Runs a node | Pinned in |
|---|---|---|
| Rock it (Umbrel) | yes | the Rock it repository (0.3.17 = Zakura 1.8.5) |
| Lock it Mac, Go Max | yes, bundled in the app | `GoMax/bin.sha256`, header of `scripts/gomax-helpers.sh` |
| Lock it Mac without Go Max, Lock it iPhone, Pocket | no | nothing to update; they only lose a server if they point at a node that stopped |
| Rock it iPhone | not looked at when this was written | |

Rock it and Lock it Mac ship the same two commits (exception, 16 Nov 2026: Lock it Mac build 9 took Zakura 1.8.8 before Rock it, and build 11 took 1.8.9, on the owner's call; 1.8.9 moves the database to format 31.0.0, so Rock it needs a Sprout build of its own before it follows). When this table changes,
both change, Rock it first.

## What 1.8.9 changes for Go Max (read in its code, 17 Nov 2026)

- Database format 30 → 31: no data rewritten (`NoMigration`); Zakura renames
  `state/v30/mainnet` to `state/v31/mainnet` in place. One way: 1.8.8 cannot
  open it, so going back means a fresh sync. The data seal walks the whole
  folder, so the rename does not break it.
- Every config key Go Max writes is unchanged.
- Metrics: `zcash.net.in/out.bytes.total` unchanged. The endpoint now serves
  at most 16 connections and closes idle ones after 30 s; Lock it makes one
  short request at a time.
- RPC: `getblockchaininfo`, `getblock`, `z_gettreestate`, `getinfo` answer as
  before. `getblock`/`getblockheader` now report a state failure as -1 instead
  of "not found". Oversized blocks and transactions are refused before parsing.
- Peers: misbehaving peers are banned reliably; reconnects after a restart.
- Licenses and Rust version (1.97) unchanged.
- `getinfo` may show `"errors": "chain tip metrics channel closed"`. Harmless:
  Go Max does not switch on Zakura's health endpoint, so nothing receives
  those progress updates, and Zakura logs that once at start (same in 1.8.8).

Run on the owner's Go Max node, 17 Nov 2026: the 1.8.8 data opened under
1.8.9 without a resync, reached the tip (3,581,933, pruned, 15.9 GB), and
Lock it's own check over Tor answered Genuine ✓ with a chain fingerprint
(data seal intact after the folder rename, cross-check agreed). Sending and
receiving worked.

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
   Also compare `[features]` in `crates/zakurad/Cargo.toml` and
   `crates/zakura-consensus/Cargo.toml` between the two tags: a feature that
   leaves `default` drops out of our build without any error (Sprout, 1.8.8).
2. Read the new stop height from `end_of_support.rs`, write it at the top
   of this file, and set `GoMaxSupport.stopHeight` in `ZeckyLockIt/GoMax.swift`
   to it. Lock it's notice and its stop message follow that number.
3. Build both programs with the home folder remapped. zakurad, with Sprout:

   ```
   RUSTFLAGS="--remap-path-prefix=$HOME=/build" CFLAGS="-ffile-prefix-map=$HOME=/build" CXXFLAGS="-ffile-prefix-map=$HOME=/build" cargo install --locked --git https://github.com/zakura-core/zakura --tag v1.8.9 zakura --bin zakurad --features sprout --root ~/rockit-proto/release
   ```

   Then `scripts/check-sprout.sh ~/rockit-proto/release/bin/zakurad`.
   Rock it: build its image with `FEATURES="default-release-binaries,sprout"`
   if it syncs with `checkpoint_sync = false`.
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
