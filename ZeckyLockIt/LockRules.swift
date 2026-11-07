import Foundation

/// What each change to the lock needs, in one place, so the rules can be
/// tested for every combination. Making the lock stricter needs nothing;
/// weakening it needs the owner, or waits.
///
/// "Owner" is Touch ID or the Mac password, plus the code (or Lock it
/// password) when the lock has one.
enum LockRules {
    enum Need: Equatable {
        /// Goes through straight away.
        case nothing
        /// The owner confirms first.
        case owner
        /// Takes effect only after the current time lock has passed.
        case waitCurrentTimeLock
    }

    /// Longer or the same: straight away. Shorter or off: after the wait.
    static func timeLock(from current: Int, to new: Int) -> Need {
        new >= current ? .nothing : .waitCurrentTimeLock
    }

    /// Putting a code on, changing it or removing it always asks the owner
    /// first (and the current code when there is one).
    static func code(had: Bool, will: Bool) -> Need {
        had == will && !had ? .nothing : .owner
    }

    /// "Only send to saved addresses": on is stricter, off is weaker.
    static func addressRule(on: Bool) -> Need { on ? .nothing : .owner }

    /// A new saved address is a weakening while the rule is on.
    static func addAddress(ruleOn: Bool) -> Need { ruleOn ? .owner : .nothing }

    /// Removing or renaming a saved address only narrows what can be used.
    static let removeAddress: Need = .nothing

    /// Breaking the glass skips the time lock: always the owner.
    static let breakGlass: Need = .owner

    /// Showing the 24 words and erasing: always the owner, never the
    /// confirmation already given when unlocking.
    static let showPhrase: Need = .owner
    static let erase: Need = .owner

    /// Switching a check on is stricter; switching it off is weaker.
    static func check(on: Bool) -> Need { on ? .nothing : .owner }

    /// "Really open the lock?": a longer wait is stricter, a shorter one
    /// (or Don't ask, 0) is weaker.
    static func wait(from current: Int, to new: Int) -> Need { new >= current ? .nothing : .owner }

    // MARK: Security keys (as on the iPhone, src/lib/keyRules.ts)

    enum KeyAction { case addFirst, addMore, remove, phraseOn, phraseOff, startRemoval, cancelRemoval, test }
    enum KeyNeed: Equatable { case key, owner, nothing }

    /// What an action on the security keys asks first. Anything that weakens
    /// the keys asks a key, so someone who knows the Mac password cannot
    /// simply take them away. A new key also asks an existing one. The only
    /// way around a key is the 48-hour removal.
    static func keyAction(_ action: KeyAction, keyCount: Int) -> KeyNeed {
        switch action {
        case .addFirst, .startRemoval: return .owner
        case .addMore, .remove, .phraseOff, .cancelRemoval: return keyCount > 0 ? .key : .owner
        case .phraseOn, .test: return .nothing
        }
    }

    /// Asking the key for the phrase needs a backup key first.
    static let phraseKeyMinKeys = 2
    /// 48 hours of clock, and 48 hours of Zcash blocks (75 s each, 25 s
    /// from NU7: about 2,304 blocks before it, 6,912 after).
    static let removalSeconds: TimeInterval = 48 * 3600
    /// A server may lag a few blocks behind another; more is suspect.
    static let behindTolerance = 10

    /// Where a removal starts counting: never below the highest height seen
    /// while synced (R1). Nil when the server is clearly behind.
    static func removalStartHeight(synced: Int, seen: Int) -> Int? {
        guard synced > 0 else { return nil }
        if seen > 0 && synced < seen - behindTolerance { return nil }
        return Swift.max(synced, seen)
    }

    static func removalDue(_ removal: SecurityKeys.Removal?, now: Date, networkHeight: Int) -> Bool {
        guard let removal, removal.startHeight > 0 else { return false }
        return now.timeIntervalSince(removal.startedAt) >= removalSeconds
            && Double(BlockTime.seconds(from: removal.startHeight, to: networkHeight)) >= removalSeconds
    }
}

/// Keys to the lock: which checks the owner wants, kept in the Keychain
/// (this device only) so they cannot be changed from outside the app.
/// Defaults: ask when opening Zecky, a 10-second pause before opening the
/// lock, and the confirmation from opening Zecky reused for the lock.
enum Keys {
    static let waits = [10, 5, 3, 0]
    private static let service = "app.zecky.lockit.mac.keys"

    private struct Choice: Codable {
        var askOpeningZecky = true
        var askOpeningLock = false
        var wait = 10
    }

    private static var choice: Choice {
        get {
            guard let data = (try? KeyStore.read(service: service)) ?? nil,
                  let c = try? JSONDecoder().decode(Choice.self, from: data) else { return Choice() }
            return c
        }
        set { try? KeyStore.save(try JSONEncoder().encode(newValue), service: service) }
    }

    /// Key 1: Touch ID / password (and the Zecky code) when Lock it starts
    /// and after it locked itself.
    static var askOpeningZecky: Bool {
        get { choice.askOpeningZecky }
        set { var c = choice; c.askOpeningZecky = newValue; choice = c
              LockLog.add(.keys, newValue ? "Ask when opening Zecky: on" : "Ask when opening Zecky: off") }
    }

    /// Key 3: ask again when opening the lock, even right after opening Zecky.
    static var askOpeningLock: Bool {
        get { choice.askOpeningLock }
        set { var c = choice; c.askOpeningLock = newValue; choice = c
              LockLog.add(.keys, newValue ? "Ask again when opening the lock: on" : "Ask again when opening the lock: off") }
    }

    /// Key 2: seconds of "Really open the lock?"; 0 is Don't ask.
    static var wait: Int {
        get { choice.wait }
        set { var c = choice; c.wait = newValue; choice = c
              LockLog.add(.keys, newValue == 0 ? "Really open the lock?: don't ask" : "Really open the lock?: \(newValue) seconds") }
    }

    static func waitLabel(_ seconds: Int) -> String { seconds == 0 ? "Don't ask" : "\(seconds) s" }

    static func erase() { try? KeyStore.delete(service: service) }
}
