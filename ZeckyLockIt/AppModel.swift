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
        case problem(String)
    }

    enum Unseal: Equatable { case sealOlder, finishBackup, finishStart }

    @Published var screen: Screen = .loading
    /// The sheet over the home screen, also opened from the menu bar.
    enum Sheet: Identifiable { case receive, send, settings, activity; var id: Self { self } }
    @Published var sheet: Sheet?
    /// The lock on the home screen: asking first, then open while releasing.
    @Published var asking = false
    /// ZEC or zats, and amounts hidden for bystanders. Remembered.
    @Published var unit: Amount.Unit = Amount.unit { didSet { Amount.unit = unit } }
    @Published var amountsHidden: Bool = Amount.hidden { didSet { Amount.hidden = amountsHidden } }
    /// Dark (default), light, or the same as this Mac. Remembered.
    @Published var themeMode: Theme.Mode = Theme.mode { didSet { Theme.mode = themeMode } }
    @Published var lockOpen = false

    func askToOpen() { sheet = nil; asking = true }
    func keepLocked() { asking = false }
    func openLock() {
        asking = false
        lockOpen = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            if lockOpen { sheet = .send }
        }
    }
    /// The lock closes again by itself once the release sheet is gone.
    func sheetClosed() { if lockOpen { lockOpen = false } }
    var hasWallet: Bool { if case .home = screen { return !locked } else { return false } }

    // MARK: Auto-lock

    /// The whole app behind Touch ID or the Mac password: at launch, when
    /// the Mac sleeps or its screen locks, and after 5 minutes away.
    @Published var locked = false
    static let idleLimit: TimeInterval = 5 * 60
    private var inactiveSince: Date?

    func lockNow() {
        guard WalletVault.exists, !locked else { return }
        sheet = nil
        asking = false
        lockOpen = false
        locked = true
    }

    func unlock() async {
        if await OwnerCheck.confirm(reason: "unlock Zecky Lock it") { locked = false }
    }

    func wentInactive() { inactiveSince = Date() }

    func cameBack() {
        if let since = inactiveSince, Date().timeIntervalSince(since) > Self.idleLimit { lockNow() }
        inactiveSince = nil
    }

    /// No keyboard or mouse for 5 minutes while Lock it is in front.
    func checkIdle() {
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
        guard WalletVault.exists else { screen = .welcome; return }
        if WalletVault.legacyExists { screen = .unseal(.sealOlder); return }
        if WalletVault.phraseUnconfirmed { screen = .unseal(.finishBackup); return }
        lockNow()
        openHome()
    }

    /// Opens the seal for the step that needs the phrase.
    func unseal(_ purpose: Unseal) async {
        message = nil
        busy = true
        defer { busy = false }
        do {
            switch purpose {
            case .sealOlder:
                try await WalletVault.sealOlderWallet()
                launch()
            case .finishBackup:
                screen = .backup(try await WalletVault.unseal(reason: "finish your backup"))
            case .finishStart:
                await startEngine(try await WalletVault.unseal(reason: "finish opening your wallet"))
            }
        } catch {
            message = String(describing: error)
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
            try WalletVault.save(wallet)
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
            try WalletVault.save(wallet)
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
