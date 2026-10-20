import Foundation

/// Where to start scanning the chain. Same numbers as the iPhone app.
enum Birthday {
    /// Sapling activation: the earliest block a Zecky wallet can have funds in.
    static let earliest = 419_200

    // A block every 75 s since Blossom (block 653,600, 11 Dec 2019), 150 s before.
    private static let blossomHeight = 653_600
    private static let blossomTime = DateComponents(
        calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
        year: 2019, month: 12, day: 11, hour: 18).date!
    // Real block times drift and starting too late would miss funds, so aim
    // a few percent (plus about two days) early.
    private static let margin = 1.03
    private static let extraBlocks = 2_000

    /// A rough chain height for "now", for when the network can't be asked.
    static func estimatedTip(now: Date = Date()) -> Int {
        blossomHeight + Int(now.timeIntervalSince(blossomTime) / 75)
    }

    /// The block to start from for a wallet created in `year`/`month` (1–12).
    static func estimate(year: Int, month: Int, tip: Int, now: Date = Date()) -> Int {
        let target = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
            year: year, month: month, day: 1).date!
        var height: Int
        if target >= blossomTime {
            let secondsBack = max(0, now.timeIntervalSince(target))
            height = tip - Int((secondsBack / 75 * margin).rounded(.up))
        } else {
            let secondsBefore = blossomTime.timeIntervalSince(target)
            height = blossomHeight - Int((secondsBefore / 150 * margin).rounded(.up))
        }
        height -= extraBlocks
        return min(tip, max(earliest, height))
    }
}
