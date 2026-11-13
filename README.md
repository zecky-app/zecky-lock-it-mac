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

## Try it

For an Apple silicon Mac with macOS 13 or later. To test, sign up at
https://zecky.app and we email you the TestFlight invite.

Feedback is very welcome: use TestFlight's feedback, or email
dev@zecky.app. To report a security problem, see [SECURITY.md](SECURITY.md)
and please report it privately.

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
