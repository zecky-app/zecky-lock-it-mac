# Zecky Lock it for Mac

A calm, self-custody Zcash wallet for the Mac, made for holding, not trading.
Your 24 words stay on your Mac, sealed in the Secure Enclave or the Keychain.
Payments leave over Tor.

**Go Max** is optional: one switch starts your own Zcash node inside the
wallet, and Lock it then reads the chain from your own Mac instead of a
server. It uses about 15 GB of disk to start, and the first check of the
chain takes most of a day.

> **Status: in testing, not audited.** Lock it has had no independent security
> review yet. Start with a small amount.

## What it does

- **Receive and keep, shielded.** Amounts, senders and receivers stay
  encrypted on the blockchain. Zcash that arrives on a transparent address
  is locked in with one step.
- **Send with care.** Nothing leaves without a receipt; the lock opens with
  your keys (Touch ID, a code, a security key), and payments leave over Tor.
- **Several wallets on one key ring**, each named, each with its own history.
- **Signing devices.** Pair a Keystone (Cypherpunk firmware) or Cupcake over
  QR codes: the keys stay on the device, Lock it writes the payment and the
  device signs it. Pairing asks whether the wallet is new or already used.
- **For a business.** Watch a wallet from its viewing key (Lock it can see,
  never spend), share a viewing key as text or QR code, and export a
  wallet's payments as CSV for the books (Settings › Business).
- **Go Max**, your own node (below).

## Try it

For an Apple silicon Mac with macOS 13 or later. To test, sign up at
https://zecky.app and we email you the TestFlight invite.

Feedback is very welcome: use TestFlight's feedback, or email
dev@zecky.app. To report a security problem, see [SECURITY.md](SECURITY.md)
and please report it privately.

## How to recognise genuine Zecky Lock it

- **Only from these places:** the TestFlight invite you get through
  https://zecky.app, and later the App Store under the developer name Zecky.
  Not from other sites, links in replies or direct messages from strangers.
- **Signed by team `W2F7RNV886`.** Every genuine build is signed with this
  Apple team. On your Mac you can check an installed copy:

  ```
  codesign -dv "/Applications/Zecky Lock it.app" 2>&1 | grep TeamIdentifier
  ```

  It must say `TeamIdentifier=W2F7RNV886`.
- **A Go Max node can prove it from the outside.** With Genuine node on, it
  answers a fresh challenge with a statement signed through Apple's App
  Attest, which anyone can check with [tools/verify-statement](tools/verify-statement)
  and `--app-id W2F7RNV886.app.zecky.lockit`. A copy built by someone else
  cannot pass as this app. An app can never vouch for itself on its own
  screen; check it from another device or with the verifier.

The code is open (Apache-2.0), so anyone may build it. Only builds signed by
this team are Zecky Lock it.

## What is inside

- **Wallet engine:** the Zcash developers' own core, librustzcash, through
  the Zecky engine (a lightly adapted zcash-swift-wallet-sdk). Lock it does
  not build its own cryptography. See [docs/ENGINE.md](docs/ENGINE.md).
- **Go Max:** Zakura (Zcash node, a fork of Zebra) and Zaino (light-wallet
  server, by Zingo Labs), built from source and shipped inside the app. Both
  listen only on this Mac. See [docs/GO_MAX.md](docs/GO_MAX.md).
- **Everything else** is in [ZeckyLockIt/Acknowledgements.md](ZeckyLockIt/Acknowledgements.md),
  with each project's license.

What changed per build: [docs/CHANGELOG.md](docs/CHANGELOG.md).
What is still open: [docs/BUILD_LIST.md](docs/BUILD_LIST.md).
The camera is used only while a scan screen is open; the green light shows it.

## Building

Building from source is possible but not yet simple, and not yet
reproducible:

1. Xcode on an Apple silicon Mac.
2. The Zecky engine checked out next to this repository, at
   `../ZeckyEngine/zecky-engine`, on its `tor-submit` branch. Its library
   file is not downloadable yet; [docs/ENGINE.md](docs/ENGINE.md) explains
   the local package it uses meanwhile.
3. The Sapling parameters: `scripts/fetch-sapling-params.sh` (checked by
   SHA-256).
4. Optional, for Go Max: `zakurad` and `zainod` built from the versions named
   in [docs/NODE_UPDATES.md](docs/NODE_UPDATES.md), then
   `scripts/gomax-helpers.sh`. Without them the app builds and says it has no
   node inside.
5. Your own Apple development team:

   ```
   xcodebuild test -scheme ZeckyLockIt -destination 'platform=macOS' DEVELOPMENT_TEAM=<your team>
   ```

Making the engine library and the two node programs reproducible from pinned
sources is on the list before a public release.

## Principles

Zecky stands for four things: **Savings** (keeping, not trading), **Safety**
(protecting you at the moment of risk), **Dignity** (plain words, your
choices, nothing hidden) and **Quiet** (no noise).

## License

Apache License 2.0, see [LICENSE](LICENSE). The software Lock it builds on
keeps its own licenses, listed in the acknowledgements.
