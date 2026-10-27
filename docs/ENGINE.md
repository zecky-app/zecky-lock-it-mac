# The Zcash engine in Lock it for Mac

Lock it uses the Zcash developers' own Swift SDK, pinned to one exact version.

| What | Value |
|---|---|
| Package | https://github.com/zcash/zcash-swift-wallet-sdk |
| Version | 3.0.0 (exact, in `ZeckyLockIt.xcodeproj` and `Package.resolved`) |
| Engine binary | `libzcashlc.xcframework.zip` from the SDK's own 3.0.0 GitHub release |
| Checksum (SHA-256) | `122bff46bb5b34ee354170e261d9ac7f61efe09962a411a99419782cb94857fc` |

Swift Package Manager downloads the binary from the Zcash team's release and
refuses it when the checksum does not match the one in the SDK's
`Package.swift`. Nobody in between builds or repackages it.

The macOS copy inside the binary uses the iPhone folder layout; the build
step "Fix libzcashlc layout for macOS" only rearranges and re-signs it, it
does not change the code. (To report upstream.)

## When updating

1. Read the SDK's release notes (and the librustzcash version it brings).
2. Change the exact version in Xcode, let Package.resolved update, and
   record the new version and checksum in this file.
3. Run the tests (Command-U), `scripts/check.sh`, and the Mac regression
   steps, including a restore and a release to yourself.
