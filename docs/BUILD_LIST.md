# Build list: what is still to build

Started 11 Nov 2026. One list for Lock it Mac and what the owner asked to
carry over to Lock it iPhone. Newest state on top of each section; an item
leaves the list when it is built and seen working.

Lock it Mac 0.2.0 (3), the first build with Go Max, was uploaded to
TestFlight on 11 Nov 2026 and is waiting for Apple's review.

## Both apps

- **Terms acceptance at the first start** (owner, 11 Nov). One screen
  before a wallet is made: a few plain sentences, a link to the full terms,
  and an "I understand" button. The app remembers which version was accepted
  and when, on the device only, and asks again when the terms change.
  Lock it Mac: done (12 Nov, "Before you start", `Terms.version` 1, links to
  zecky.app/terms.html and privacy.html, rows under Settings › About).
  Lock it iPhone: still open.

## Lock it Mac

Before a wider release:

- Notice before Zakura's stop height (about 5 Dec 2026) and a message when
  Lock it falls back to public servers. See NODE_UPDATES.md.
- Update to Zakura 1.8.6, Umbrel first.
- Zaino watchdog: the coin can be green while Zaino does not answer.
- Cookie (password) on the node's control port.
- Keep the Mac awake only on power.
- Warnings for a low disk and a metered connection.
- Texts that still say "about 20 GB": 15 GB to start, about 22 GB after a month.
- Rewrite the commit that contains build.log before any push of `go-max`.
- Record the exact build commands for `zakurad` and `zainod`.

Sending over Tor, left to test or finish:

- A Seal it payment over Tor.
- Sending over Tor with Go Max off.
- Sending while the own node is down.
- "Send through my own node" failed once, seconds after Wi-Fi came back;
  cause unproven.
- Tag the engine v4.0.0-zecky.6 after review.
- Research: Zakura's own peer connections over Tor, and the cost.

Asked for on 11 Nov, not built:

- Faster "No connection" on the Go Max coin, from the node's peer count
  (needs one measurement of how fast Zakura drops peers).
- Remember the last known block between sessions, so confirmations show
  right after opening.

Small flaws seen in screenshots:

- A divider line under the last row of each Settings list.
- About: the Zcash engine line is cut off.

Later:

- Phone pairing: Zaino on the home network, QR, then the Tor route.
  Rock it iPhone linking to the Mac node as well as the Umbrel (waits for
  answers from the Rock it iPhone code).
- Add a watch-only wallet from a viewing key.
- Intel Macs: not planned; count who asks.
- Windows: only after Go Max has proven itself.

## Lock it iPhone

Not touched from this repository. Written here so it is not lost:

- Terms acceptance at the first start (see Both apps).
- Check which of today's Mac changes should come over: payment details in
  Activity, sending over Tor with no silent fallback.
- Android: first step is a read-through of what in the app is iPhone-only.
