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

    /// "Only release to saved addresses": on is stricter, off is weaker.
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
}
