import Foundation

/// NU7, the Zcash network upgrade at block 3,543,405 (5 November 2026).
/// From there a block comes every 25 seconds instead of 75, and
/// transactions must be built for NU7.
enum NetworkUpgrade {
    static let blossomHeight = 653_600
    static let nu7Height = 3_543_405

    /// Whether this build's engine builds NU7 transactions. True since the
    /// Zecky engine v4.0.0-zecky.2 (now v4.0.0-zecky.5), checked at every build
    /// (scripts/check-engine.sh) and in WalletSelfTest. Kept as a switch for
    /// the next network upgrade: an engine that does not know it pauses here.
    static let engineKnowsNU7 = true

    /// The old engine's transactions stay valid for 40 blocks. Pausing that
    /// many blocks early means none is still waiting when the upgrade comes.
    static let pauseBefore = 40

    /// True when nothing may be sent: from 40 blocks before NU7 while the
    /// engine does not know it. An unknown height (0) also counts as paused:
    /// Lock it cannot tell which side of the upgrade it is on.
    static func releasesPaused(networkHeight: Int) -> Bool {
        guard !engineKnowsNU7 else { return false }
        return networkHeight <= 0 || networkHeight + 1 >= nu7Height - pauseBefore
    }

    static let pausedText = "Sending is paused for the Zcash network upgrade until Lock it is updated. Your Zcash is safe, and you can still receive."

    struct Paused: Error, CustomStringConvertible { var description: String { NetworkUpgrade.pausedText } }

    /// Throws `Paused` when releases are paused.
    static func checkReleases(networkHeight: Int) throws {
        if releasesPaused(networkHeight: networkHeight) { throw Paused() }
    }
}

/// Target time per block: 150 s before Blossom, 75 s from Blossom, 25 s from
/// NU7. Use this instead of multiplying blocks by 75 seconds.
enum BlockTime {
    static func spacing(at height: Int) -> Int {
        height < NetworkUpgrade.blossomHeight ? 150 : (height < NetworkUpgrade.nu7Height ? 75 : 25)
    }

    /// Target seconds of the blocks after `from`, up to and including `to`.
    static func seconds(from: Int, to: Int) -> Int {
        guard to > from else { return 0 }
        var total = 0
        var h = from + 1
        for edge in [NetworkUpgrade.blossomHeight, NetworkUpgrade.nu7Height, Int.max] where h <= to {
            let end = min(to, edge - 1)
            if end >= h { total += (end - h + 1) * spacing(at: h); h = end + 1 }
        }
        return total
    }

    /// How many blocks back from `tip` cover `seconds`, counting from
    /// Blossom on (75 s, and 25 s from NU7). Rounded up: never too few.
    static func blocksBack(seconds: Double, from tip: Int) -> Int {
        guard seconds > 0 else { return 0 }
        if tip >= NetworkUpgrade.nu7Height {
            let afterNU7 = Double(tip - NetworkUpgrade.nu7Height + 1) * 25
            if seconds <= afterNU7 { return Int((seconds / 25).rounded(.up)) }
            return (tip - NetworkUpgrade.nu7Height + 1) + Int(((seconds - afterNU7) / 75).rounded(.up))
        }
        return Int((seconds / 75).rounded(.up))
    }
}
