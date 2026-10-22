import CoreGraphics
import Foundation

/// Which screen is showing, and the wallet behind it.
@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable {
        case loading
        case welcome
        case backup(StoredWallet)
        case confirm(StoredWallet)
        case restore
        case home
        /// The phrase is sealed and this step needs it: ask first.
        case unseal(Unseal)
        /// This Mac has no login password. `hasWallet`: one is already sealed.
        case noMacPassword(hasWallet: Bool)
        case problem(String)
    }

    enum Unseal: Equatable { case sealOlder, finishBackup, finishStart }

    @Published var screen: Screen = .loading
    /// The sheet over the home screen, also opened from the menu bar.
    enum Sheet: Identifiable { case receive, send, settings, activity, ironwood, lockIn; var id: Self { self } }
    @Published var sheet: Sheet?
    /// The lock on the home screen: asking first, then open while releasing.
    @Published var asking = false
    /// ZEC or zats, and amounts hidden for bystanders. Remembered.
    @Published var unit: Amount.Unit = Amount.unit { didSet { Amount.unit = unit } }
    @Published var amountsHidden: Bool = Amount.hidden { didSet { Amount.hidden = amountsHidden } }
    /// Dark (default), light, or the same as this Mac. Remembered.
    @Published var themeMode: Theme.Mode = Theme.mode { didSet { Theme.mode = themeMode } }
    @Published var lockOpen = false

    /// After the countdown: the code on the dials (when the lock has one).
    @Published var askingCode = false
    @Published var openNote: String?
    /// The unsealed phrase, only while the lock is open. Wiped (let go) as
    /// soon as the release is signed, the sheet closes, or the app locks.
    private(set) var opened: StoredWallet?

    /// The time lock prompt: ask ahead, or see how long is left.
    @Published var timeLockShown = false
    /// Bumped when the time lock changes, so the home screen redraws.
    @Published var timeLockChanged = 0

    func askToOpen() {
        sheet = nil
        openNote = nil
        switch TimeLock.phase {
        case .off, .ready:
            // Don't ask: straight to the code and Touch ID.
            if Keys.wait == 0 { countdownDone() } else { asking = true }
        case .notAsked, .waiting: timeLockShown = true
        }
    }
    func keepLocked() { asking = false; askingCode = false; timeLockShown = false; breakingGlass = false }
    func startTimeLockWait() { TimeLock.askToOpen(); timeLockShown = false; timeLockChanged += 1 }
    func cancelTimeLockRequest() { TimeLock.cancelRequest(); timeLockShown = false; timeLockChanged += 1 }

    /// Break the glass: straight to the code and Touch ID, past the time
    /// lock. Recorded only once the lock really opens.
    private var breakingGlass = false
    func breakGlass() {
        timeLockShown = false
        breakingGlass = true
        countdownDone()
    }
    func seenBrokenGlass() { TimeLock.seenBroken(); timeLockChanged += 1 }

    /// The countdown is done: the code, then Touch ID, then the lock opens.
    func countdownDone() {
        asking = false
        if WalletVault.needsSecret { askingCode = true; return }
        Task { @MainActor in
            if let message = await unsealToOpen(code: nil) { openNote = message; breakingGlass = false } else { openLock() }
        }
    }

    /// Unseals for this opening. Returns what to show, or nil when open.
    func unsealToOpen(code: String?) async -> String? {
        do {
            opened = try await WalletVault.unseal(reason: "open the lock", code: code, fresh: Keys.askOpeningLock)
            return nil
        } catch WalletVault.Failure.cancelled {
            return "Not confirmed, so the lock stayed closed."
        } catch {
            return String(describing: error)
        }
    }

    func openLock() {
        askingCode = false
        if breakingGlass { TimeLock.recordBroken(); breakingGlass = false; timeLockChanged += 1 }
        lockOpen = true
        released = false
        // The open lock waits on home; it closes by itself after 2 minutes
        // unless Release is being filled in.
        let token = UUID()
        openToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.openLimit * 1_000_000_000))
            if lockOpen && openToken == token && sheet != .send { closeLock() }
        }
    }

    private var openToken: UUID?
    /// Set once a release was signed; closing Release then closes the lock.
    var released = false

    /// Hands the phrase over for signing, once.
    func takeOpened() -> StoredWallet? { defer { opened = nil }; return opened }

    /// After a release, the lock closes again once Release is gone. Closing
    /// Release without releasing leaves the lock open (for up to 2 minutes).
    func sheetClosed() { if released { released = false; closeLock() } }
    var hasWallet: Bool { if case .home = screen { return !locked } else { return false } }

    // MARK: Auto-lock

    /// The whole app behind Touch ID or the Mac password: at launch, when
    /// the Mac sleeps or its screen locks, and after 5 minutes away.
    @Published var locked = false
    static let idleLimit: TimeInterval = 5 * 60
    private var inactiveSince: Date?

    /// Locks Lock it. By itself (launch, sleep, away) only when the owner
    /// wants to be asked when opening Zecky; the padlock button always.
    func lockNow(manual: Bool = false) {
        guard WalletVault.exists, !locked else { return }
        guard manual || Keys.askOpeningZecky else { closeLock(); WalletVault.endSession(); return }
        WalletVault.endSession()
        sheet = nil
        opened = nil
        askingCode = false
        timeLockShown = false
        asking = false
        lockOpen = false
        locked = true
    }

    func unlock() async {
        if !OwnerCheck.available { screen = .noMacPassword(hasWallet: true); locked = false; return }
        do {
            try await WalletVault.beginSession(reason: "unlock Zecky Lock it")
            locked = false
        } catch {}
    }

    /// With a code on the lock, unlocking proves the code: the seal is
    /// opened and let go straight away. Returns what to show, or nil.
    func unlock(code: String) async -> String? {
        do {
            if !WalletVault.usesPassword { try await WalletVault.beginSession(reason: "unlock Zecky Lock it") }
            _ = try await WalletVault.unseal(reason: "unlock Zecky Lock it", code: code, fresh: false)
            return nil
        } catch WalletVault.Failure.cancelled {
            return "Not confirmed, so it stayed locked."
        } catch {
            return String(describing: error)
        }
    }

    func wentInactive() { inactiveSince = Date() }

    func cameBack() {
        if let since = inactiveSince, Date().timeIntervalSince(since) > Self.idleLimit { lockNow() }
        inactiveSince = nil
    }

    // MARK: The open lock closes by itself

    /// While a release is being signed and handed over, nothing closes it.
    var signing = false
    static let openLimit: TimeInterval = 2 * 60

    /// Closes Release and the open lock, and lets go of the unsealed phrase.
    func closeLock() {
        guard !signing else { return }
        openToken = nil
        if sheet == .send { sheet = nil }
        opened = nil
        asking = false
        askingCode = false
        lockOpen = false
    }

    /// Hidden (Command-H) or minimised: the open lock closes. Switching to
    /// another app for a moment, to copy an address, does not.
    func wentAway() { if lockOpen || asking || askingCode { closeLock() } }

    /// No keyboard or mouse for 5 minutes while Lock it is in front.
    func checkIdle() {
        if lockOpen, let since = inactiveSince, Date().timeIntervalSince(since) > Self.openLimit { closeLock() }
        guard let any = CGEventType(rawValue: ~0) else { return }
        if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any) > Self.idleLimit { lockNow() }
    }
    @Published var busy = false
    @Published var message: String?
    let engine = WalletEngine()
    let prices = PriceFeed()

    func launch() {
        switch Mnemonic.words {
        case .failure(let failure): screen = .problem(failure.description); return
        case .success: break
        }
        guard WalletVault.exists else {
            screen = OwnerCheck.available || lockItPassword != nil ? .welcome : .noMacPassword(hasWallet: false)
            return
        }
        if !WalletVault.usesPassword && !OwnerCheck.available { screen = .noMacPassword(hasWallet: true); return }
        if WalletVault.legacyExists { screen = .unseal(.sealOlder); return }
        if WalletVault.phraseUnconfirmed { screen = .unseal(.finishBackup); return }
        lockNow()
        openHome()
    }

    /// On a Mac without a login password: the Lock it password the owner
    /// chose, held only until the new wallet is sealed with it.
    @Published var lockItPassword: String?

    func useLockItPassword(_ password: String) {
        lockItPassword = password
        screen = .welcome
    }

    /// Opens the seal for the step that needs the phrase. Returns what to
    /// show, or nil when it went on.
    @discardableResult
    func unseal(_ purpose: Unseal, code: String? = nil) async -> String? {
        message = nil
        busy = true
        defer { busy = false }
        do {
            switch purpose {
            case .sealOlder:
                try await WalletVault.sealOlderWallet()
                launch()
            case .finishBackup:
                screen = .backup(try await WalletVault.unseal(reason: "finish your backup", code: code))
            case .finishStart:
                await startEngine(try await WalletVault.unseal(reason: "finish opening your wallet", code: code))
            }
            return nil
        } catch {
            message = String(describing: error)
            return message
        }
    }

    /// New wallet: fresh 24 words, birthday = the current chain height.
    func create() async {
        busy = true; message = nil
        defer { busy = false }
        do {
            let birthday = try await ChainTip.latest()
            let phrase = try Mnemonic.phrase(from: Entropy.secure(32))
            let wallet = StoredWallet(phrase: phrase, birthday: birthday)
            try WalletVault.save(wallet, password: lockItPassword)
            lockItPassword = nil
            WalletVault.phraseUnconfirmed = true
            screen = .backup(wallet)
        } catch let failure as Entropy.Failure {
            message = failure.description
        } catch {
            message = "No wallet was created. Check the internet connection and try again. (\(error))"
        }
    }

    func restore(phrase: String, birthday: Int) {
        do {
            try Mnemonic.validate(phrase)
            let wallet = StoredWallet(phrase: Mnemonic.normalize(phrase), birthday: birthday)
            try WalletVault.save(wallet, password: lockItPassword)
            lockItPassword = nil
            WalletVault.phraseUnconfirmed = false
            openHome(with: wallet)
        } catch let failure as Mnemonic.Failure {
            message = failure.description
        } catch {
            message = "The wallet could not be saved: \(error)"
        }
    }

    func confirmed(_ wallet: StoredWallet) {
        WalletVault.phraseUnconfirmed = false
        openHome(with: wallet)
    }

    /// Erase wallet: the engine's data, the phrase and every other Keychain
    /// item, and every setting. Back to the welcome screen.
    func erase() async throws {
        try await engine.erase()
        try WalletVault.eraseAll()
        TimeLock.erase()
        LockLog.erase()
        Keys.erase()
        Contacts.erase()
        AddressBook.clear()
        Server.reset()
        Amount.resetChoices()
        prices.reset()
        themeMode = .dark
        unit = .zec
        amountsHidden = false
        sheet = nil
        asking = false
        lockOpen = false
        locked = false
        screen = .welcome
    }

    /// The home screen. Normally the wallet starts without the phrase; a
    /// phrase that is already in memory (just created or restored) is used
    /// once to create the account and then let go.
    func openHome(with wallet: StoredWallet? = nil) {
        screen = .home
        Task { await startEngine(wallet) }
    }

    private func startEngine(_ wallet: StoredWallet?) async {
        guard let birthday = wallet?.birthday ?? WalletVault.birthday else {
            screen = .problem("The wallet's birthday could not be read. Restore with your 24 words.")
            return
        }
        var seed: [UInt8] = []
        if let wallet { seed = (try? Mnemonic.seed(from: wallet.phrase)) ?? [] }
        defer { Wipe.bytes(&seed) }
        if await engine.start(birthday: birthday, seed: seed.isEmpty ? nil : seed) {
            screen = .home
        } else {
            screen = .unseal(.finishStart)
        }
    }
}
