# The Zcash engine in Lock it for Mac

Lock it does not build its own cryptography. Keys, key derivation, proofs,
signatures and transaction building all come from the official Zcash core,
**librustzcash**, published by the Zcash developers. Lock it's own code only
connects to it. Lock it for Mac runs the same engine as Lock it for iPhone
0.0.19 (19).

| Part | Version | Source |
| --- | --- | --- |
| Zcash core (librustzcash crates) | NU7 releases: zcash_protocol 0.11.0, zcash_primitives 0.31.0, zcash_client_backend 0.25.0, zcash_client_sqlite 0.23.0, orchard 0.16.0, sapling-crypto 0.9.0 | crates.io, pinned with checksums in the engine's Cargo.lock |
| Engine (libzcashlc + zcashlc.h) | Zecky engine **v4.0.0-zecky.2**, commit `3a69cb0` | zecky-engine: the official zcash-swift-wallet-sdk 4.0.0 FFI, adapted only in its connection code to the NU7 crates (`git diff 184d056`), reviewed independently |
| Swift SDK (ZcashLightClientKit) | 4.0.0, from the same engine commit | the same repository, `Sources/` |

NU7 as built into the engine: mainnet activation height 3,543,405, consensus
branch ID `0x77190AD9` (NU6.3 `0x37A5165B` the block before), 25-second
blocks (ZIP 218).

## How it gets into the app

The Xcode project uses the engine as a local Swift package at
`~/Documents/ZeckyEngine/zecky-engine` (next to this repository). Its
`LocalPackages/` folder (ignored by git) holds the xcframework built on
5 November 2026 in the same build run as the iPhone release: one
`cargo build --locked` for all five targets. Without `LocalPackages/` the
package's `Package.swift` would download the official 4.0.0 binary, which
does not know NU7; the build check below refuses that.

## Checks

- Every build starts with `scripts/check-engine.sh`, which stops the build
  unless the engine is at commit `3a69cb0` without local changes and these
  files match:

| File | SHA-256 |
| --- | --- |
| macos-arm64_x86_64/libzcashlc.framework/libzcashlc | `2d36d76fb804d4d560dffe74e2b8a8dbe0643bb7dae47b2891b6b34be948211e` |
| zcashlc.h (same as the iPhone release asset) | `1d9cada2baa1c0f3c7f8035422e1feecd9f0bd696ce7b07ea686313d2844a2dc` |

- `WalletSelfTest` (run by the tests) asks the linked engine for the branch
  ID at 3,543,404 and 3,543,405 and expects NU6.3 and NU7.
- `NetworkUpgrade.engineKnowsNU7` is on; for the next network upgrade it is
  the switch that pauses releases while the engine does not know it.

The macOS framework uses the iPhone folder layout; the build step "Fix
libzcashlc layout for macOS" only rearranges and re-signs it, it does not
change the code.

## When updating the engine

1. In zecky-engine: bump the crates, `cargo test`, independent review of the
   FFI diff, rebuild on a Mac (`make ffi-all`), release.
2. Here: copy the new xcframework into `LocalPackages/`, update the commit
   and fingerprints in `scripts/check-engine.sh` and this file.
3. Run the tests (Command-U) and `scripts/check.sh`; test on testnet, then one
   small mainnet send.

Opening a wallet with a newer engine can migrate its database one way; an
older build cannot open it afterwards (restore from the 24 words instead).
