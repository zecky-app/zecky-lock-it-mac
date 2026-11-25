# Build list: what is still open

Updated 25 Nov 2026, with build 14. Built and tested items leave the list;
what changed per build is in [CHANGELOG.md](CHANGELOG.md).

## Before 5 December

- **Zakura's stop.** The node version inside Go Max (Zakura 1.8.9) stops at
  block 3,643,309, about 5 Dec. Lock it already says so on the Go Max page,
  and at the stop it keeps the node's data and asks before reading from a
  public server (tested 25 Nov). It ships the Zakura release that moves the
  stop the day it is out. See [NODE_UPDATES.md](NODE_UPDATES.md).

## December

- **NU 7.1** (expected mid-December): a second node update, and an engine
  update if the upgrade needs one.
- **Internal security review, round 1**: one work package at a time, keys
  and sending first. Its report is published with 1.0. It is not an
  outside audit.

## Before 1.0 (target January 2027)

- Restore tests on another Mac, with and without Go Max.
- A notarized download from zecky.app, with signed checksums and a "how to
  verify" page, next to TestFlight.
- The engine library and the two node programs reproducible from pinned
  sources.

## After 1.0

- Payment requests with a memo and a payment link; Lock it behind a payment
  service (CipherPay, BTCPay Server).
- More signing devices that sign over QR codes.
