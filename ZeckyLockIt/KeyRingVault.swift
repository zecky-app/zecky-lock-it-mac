import CryptoKit
import Foundation
import ZcashLightClientKit

/// Extra wallets on this Mac, behind the same main lock.
///
/// Each extra wallet's words are encrypted with a key derived from the main
/// wallet's words. That key is never stored: it only exists while the main
/// lock is open (after Touch ID, the code, a security key and the time lock,
/// whichever the owner chose). So every wallet on the key ring is exactly as
/// well protected as the main lock, and adding one needs no new seal.
///
/// The encrypted entries sit in the Keychain, this device only, never synced.
enum KeyRingVault {
    struct Entry: Codable, Equatable {
        var id: String        // the account's UUID, hex
        var name: String
        var birthday: Int
        var box: Data         // AES-GCM(words)
    }

    enum Failure: Error, CustomStringConvertible {
        case notFound, damaged
        var description: String {
            switch self {
            case .notFound: return "This wallet's words are not on this Mac."
            case .damaged: return "This wallet's words could not be opened."
            }
        }
    }

    private static let service = "app.zecky.lockit.mac.keyring"
    private static let info = Data("zecky-lockit-keyring-v1".utf8)

    static func hex(_ id: AccountUUID) -> String {
        id.id.map { String(format: "%02x", $0) }.joined()
    }

    static var entries: [Entry] {
        guard let data = (try? KeyStore.read(service: service)) ?? nil,
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    static func contains(_ id: AccountUUID) -> Bool {
        entries.contains { $0.id == hex(id) }
    }

    private static func store(_ list: [Entry]) throws {
        if list.isEmpty { try? KeyStore.delete(service: service); return }
        try KeyStore.save(try JSONEncoder().encode(list), service: service)
    }

    private static func key(mainPhrase: String) throws -> SymmetricKey {
        var seed = try Mnemonic.seed(from: mainPhrase)
        defer { Wipe.bytes(&seed) }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: seed),
                                      salt: Data("zecky".utf8), info: info, outputByteCount: 32)
    }

    static func add(id: AccountUUID, name: String, phrase: String, birthday: Int, mainPhrase: String) throws {
        let sealed = try AES.GCM.seal(Data(phrase.utf8), using: key(mainPhrase: mainPhrase))
        guard let box = sealed.combined else { throw Failure.damaged }
        var list = entries.filter { $0.id != hex(id) }
        list.append(Entry(id: hex(id), name: name, birthday: birthday, box: box))
        try store(list)
    }

    /// The words of an extra wallet, opened with the main wallet's words.
    static func open(id: AccountUUID, mainPhrase: String) throws -> StoredWallet {
        guard let entry = entries.first(where: { $0.id == hex(id) }) else { throw Failure.notFound }
        guard let box = try? AES.GCM.SealedBox(combined: entry.box),
              let plain = try? AES.GCM.open(box, using: key(mainPhrase: mainPhrase)),
              let phrase = String(data: plain, encoding: .utf8) else { throw Failure.damaged }
        return StoredWallet(phrase: phrase, birthday: entry.birthday)
    }

    static func remove(id: AccountUUID) {
        try? store(entries.filter { $0.id != hex(id) })
    }

    static func erase() {
        try? KeyStore.delete(service: service)
    }
}

/// Names the owner gives wallets on the key ring. The engine keeps the name
/// given when a wallet was added; a rename is kept here. Not secret.
enum WalletNames {
    private static let key = "keyring.names"

    private static var all: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func name(for account: Account, fallback: String) -> String {
        all[KeyRingVault.hex(account.id)] ?? account.name ?? fallback
    }

    static func rename(_ id: AccountUUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = all
        names[KeyRingVault.hex(id)] = trimmed.isEmpty ? nil : trimmed
        all = names
    }

    static func forget(_ id: AccountUUID) {
        var names = all
        names[KeyRingVault.hex(id)] = nil
        all = names
    }

    static func erase() { UserDefaults.standard.removeObject(forKey: key) }
}
