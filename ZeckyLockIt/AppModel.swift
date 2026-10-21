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
        case home(StoredWallet)
        case problem(String)
    }

    @Published var screen: Screen = .loading
    /// The sheet over the home screen, also opened from the menu bar.
    enum Sheet: Identifiable { case receive, send, settings, activity; var id: Self { self } }
    @Published var sheet: Sheet?
    /// The lock on the home screen: asking first, then open while releasing.
    @Published var asking = false
    /// ZEC or zats, and amounts hidden for bystanders. Remembered.
    @Published var unit: Amount.Unit = Amount.unit { didSet { Amount.unit = unit } }
    @Published var amountsHidden: Bool = Amount.hidden { didSet { Amount.hidden = amountsHidden } }
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
    var hasWallet: Bool { if case .home = screen { return true } else { return false } }
    @Published var busy = false
    @Published var message: String?
    let engine = WalletEngine()
    let prices = PriceFeed()

    func launch() {
        do {
            switch Mnemonic.words {
            case .failure(let failure): screen = .problem(failure.description); return
            case .success: break
            }
            if let wallet = try WalletVault.load() {
                if WalletVault.phraseUnconfirmed { screen = .backup(wallet) } else { open(wallet) }
            } else {
                screen = .welcome
            }
        } catch {
            screen = .problem("The Keychain could not be read: \(error)")
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
            open(wallet)
        } catch let failure as Mnemonic.Failure {
            message = failure.description
        } catch {
            message = "The wallet could not be saved: \(error)"
        }
    }

    func confirmed(_ wallet: StoredWallet) {
        WalletVault.phraseUnconfirmed = false
        open(wallet)
    }

    /// Erase wallet: the engine's data, the phrase and every other Keychain
    /// item, and every setting. Back to the welcome screen.
    func erase() async throws {
        try await engine.erase()
        try KeyStore.delete(service: KeyStore.phraseService)
        WalletVault.phraseUnconfirmed = false
        AddressBook.clear()
        Server.reset()
        Amount.resetChoices()
        prices.reset()
        unit = .zec
        amountsHidden = false
        sheet = nil
        asking = false
        lockOpen = false
        screen = .welcome
    }

    func open(_ wallet: StoredWallet) {
        screen = .home(wallet)
        Task { await engine.start(wallet) }
    }
}
