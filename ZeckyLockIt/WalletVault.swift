import Foundation

/// The wallet's secret part: phrase and birthday, in the Keychain only.
struct StoredWallet: Codable, Equatable {
    var phrase: String
    var birthday: Int
}

enum WalletVault {
    private static let checkService = "app.zecky.lockit.mac.phrase-unconfirmed"

    static func save(_ wallet: StoredWallet) throws {
        try KeyStore.save(try JSONEncoder().encode(wallet), service: KeyStore.phraseService)
    }

    static func load() throws -> StoredWallet? {
        guard let data = try KeyStore.read(service: KeyStore.phraseService) else { return nil }
        return try JSONDecoder().decode(StoredWallet.self, from: data)
    }

    /// True until the owner has shown they wrote the words down.
    static var phraseUnconfirmed: Bool {
        get { ((try? KeyStore.read(service: checkService)) ?? nil) != nil }
        set {
            if newValue { try? KeyStore.save(Data("unconfirmed".utf8), service: checkService) }
            else { try? KeyStore.delete(service: checkService) }
        }
    }
}
