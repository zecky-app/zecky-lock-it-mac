# The Zcash engine in Lock it for Mac

Lock it does not build its own cryptography. Keys, key derivation, proofs,
signatures and transaction building all come from the official Zcash core,
**librustzcash**, published by the Zcash developers. Lock it's own code only
connects to it. Lock it for Mac runs the same engine release as Lock it for
iPhone 0.0.19 (23).

| Part | Version | Source |
| --- | --- | --- |
| Zcash core (librustzcash crates) | NU7 releases: zcash_protocol 0.11.0, zcash_primitives 0.31.0, zcash_client_backend 0.25.0, zcash_client_sqlite 0.23.0, orchard 0.16.0, sapling-crypto 0.9.0 | crates.io, pinned with checksums in the engine's Cargo.lock |
| Engine (libzcashlc + zcashlc.h) | Zecky engine **v4.0.0-zecky.3**, tag commit `b934e9c` (built from `4637ae4`) | zecky-engine: the official zcash-swift-wallet-sdk 4.0.0 FFI, adapted only in its connection code to the NU7 crates, reviewed independently; advisory fixes, reproducible build (Rust 1.99.1, `--locked`, no builder paths), key bytes wiped when freed |
| Swift SDK (ZcashLightClientKit) | 4.0.0, from the same tag | the same repository, `Sources/` |
| Swift networking (gRPC-Swift, SwiftNIO, NIO-SSL, NIO-HTTP2, SQLite.swift) | exact versions in `Package.resolved` (committed) | Swift Package Manager |

NU7 as built into the engine: mainnet activation height 3,543,405, consensus
branch ID `0x77190AD9` (NU6.3 `0x37A5165B` the block before), 25-second
blocks (ZIP 218).

## How it gets into the app

The Xcode project uses the engine as a local Swift package at
`~/Documents/ZeckyEngine/zecky-engine` (next to this repository), checked
out at tag `v4.0.0-zecky.3`. Its `Package.swift` names the release file
`libzcashlc-swiftpm.xcframework.zip` (iPhone and Mac slices) with SHA-256
`35a3e6829555d4a3f5a5b0aafea5577318e8f81d8b27ec6a2de98ce76ba15a7c`.

That release file is not downloadable yet (GitHub answers 404 on 7 Nov 2026),
so the engine's own local mode is used with a copy of exactly that file:

```
cd ~/Documents/ZeckyEngine
shasum -a 256 "outputs/zecky.3/libzcashlc-swiftpm.xcframework.zip"   # must be 35a3e682…
mkdir zecky-engine/LocalPackages
unzip -q "outputs/zecky.3/libzcashlc-swiftpm.xcframework.zip" -d zecky-engine/LocalPackages
cp zecky-engine/BuildSupport/LocalPackages-Package.swift zecky-engine/LocalPackages/Package.swift
```

`LocalPackages/` is ignored by git. Once the release file is public, remove
`LocalPackages/` and let Swift Package Manager download and check it.

## Checks

- Every build starts with `scripts/check-engine.sh`. It stops the build
  unless the engine is at `b934e9c` without local changes, its
  `Package.swift` pins the release file's checksum, `LocalPackages/` holds
  the engine's own manifest, and the unpacked files match:

| File | SHA-256 |
| --- | --- |
| macos-arm64_x86_64/libzcashlc.framework/libzcashlc | `ec88e07329e28e5b691b389d79631e88b91aadf19f54b14416c353dfef3079fa` |
| zcashlc.h (same as the iPhone release asset) | `1d9cada2baa1c0f3c7f8035422e1feecd9f0bd696ce7b07ea686313d2844a2dc` |

- `WalletSelfTest` (run by the tests) asks the linked engine for the branch
  ID at 3,543,404 and 3,543,405 and expects NU6.3 and NU7.
- `NetworkUpgrade.engineKnowsNU7` is on; for the next network upgrade it is
  the switch that pauses sending while the engine does not know it.

The macOS framework uses the iPhone folder layout; the build step "Fix
libzcashlc layout for macOS" only rearranges and re-signs it, it does not
change the code.

## When updating the engine

1. In zecky-engine: bump the crates, `cargo test`, independent review of the
   FFI diff, reproducible rebuild on a Mac, release with the SwiftPM file.
2. Here: check out the new tag in `~/Documents/ZeckyEngine/zecky-engine`,
   update the tag, commit and fingerprints in `scripts/check-engine.sh` and
   this file.
3. Run the tests (Command-U) and `scripts/check.sh`; test on testnet, then one
   small mainnet send.

Opening a wallet with a newer engine can migrate its database one way; an
older build cannot open it afterwards (restore from the 24 words instead).

## History

- Until 5 Nov 2026: zcash-swift-wallet-sdk 3.0.0 (the Zcash team's own build),
  with sending paused 40 blocks before NU7.
- 6 Nov: Zecky engine v4.0.0-zecky.2 (commit 3a69cb0), the Mac slice from the
  same build run as the iPhone release, through LocalPackages.
- 7 Nov: v4.0.0-zecky.3, unpacked from its SwiftPM release file (checked by checksum) because the file is not downloadable yet.
