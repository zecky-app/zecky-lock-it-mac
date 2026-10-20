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
    @Published var busy = false
    @Published var message: String?
    let engine = WalletEngine()

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
        screen = .welcome
    }

    func open(_ wallet: StoredWallet) {
        screen = .home(wallet)
        Task { await engine.start(wallet) }
    }
}
