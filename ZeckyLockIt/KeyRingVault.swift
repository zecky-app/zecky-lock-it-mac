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
        try? KeyStore.delete(service: stagingService)
    }

    // MARK: Handing the lock to another wallet

    // When the wallet that holds the lock is erased, the lock passes to
    // another Mac wallet: its words become the sealed ones, and every other
    // entry is encrypted again with a key from those words. The new entries
    // are made and checked first and kept aside (staged) with a tag of the
    // new lock; only after the new seal is in place do they replace the old
    // ones. If Lock it stops half-way, the next opening finishes or undoes it
    // (finishInterruptedHandover), so no wallet's words are ever lost.

    private static let stagingService = "app.zecky.lockit.mac.keyring-staging"

    private struct Staged: Codable {
        var lockTag: Data
        var entries: [Entry]
    }

    /// Identifies the lock words a staged list belongs to, without revealing them.
    static func lockTag(mainPhrase: String) throws -> Data {
        let k = try key(mainPhrase: mainPhrase)
        return Data(HMAC<SHA256>.authenticationCode(for: Data("zecky-keyring-lock-tag".utf8), using: k))
    }

    /// `entries` without `dropping`, each opened with the old lock words and
    /// sealed again with the new ones, then checked to open to the same words.
    static func rekeyed(_ entries: [Entry], dropping: Set<String>, oldMain: String, newMain: String) throws -> [Entry] {
        let oldKey = try key(mainPhrase: oldMain)
        let newKey = try key(mainPhrase: newMain)
        return try entries.filter { !dropping.contains($0.id) }.map { entry in
            guard let box = try? AES.GCM.SealedBox(combined: entry.box),
                  let plain = try? AES.GCM.open(box, using: oldKey) else { throw Failure.damaged }
            guard let combined = try AES.GCM.seal(plain, using: newKey).combined,
                  let check = try? AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: newKey),
                  check == plain else { throw Failure.damaged }
            return Entry(id: entry.id, name: entry.name, birthday: entry.birthday, box: combined)
        }
    }

    /// Step 1 of a handover: the new entries, made, checked and kept aside.
    static func stageHandover(dropping: Set<String>, oldMain: String, newMain: String) throws {
        let staged = Staged(lockTag: try lockTag(mainPhrase: newMain),
                            entries: try rekeyed(entries, dropping: dropping, oldMain: oldMain, newMain: newMain))
        try KeyStore.save(try JSONEncoder().encode(staged), service: stagingService)
    }

    /// Step 3, after the new seal is in place: the staged entries become the key ring.
    static func commitHandover(newMain: String) throws {
        guard let data = (try? KeyStore.read(service: stagingService)) ?? nil,
              let staged = try? JSONDecoder().decode(Staged.self, from: data),
              staged.lockTag == (try lockTag(mainPhrase: newMain)) else { throw Failure.damaged }
        try store(staged.entries)
        try? KeyStore.delete(service: stagingService)
    }

    /// Undo step 1 when the new seal could not be made.
    static func discardHandover() { try? KeyStore.delete(service: stagingService) }

    /// Called with the lock words each time the lock opens. A staged list
    /// left by an interrupted handover is used when it belongs to these words
    /// (the new seal was already in place), and dropped otherwise (the old
    /// seal still holds, with the old entries).
    static func finishInterruptedHandover(mainPhrase: String) {
        guard let data = (try? KeyStore.read(service: stagingService)) ?? nil else { return }
        if let staged = try? JSONDecoder().decode(Staged.self, from: data),
           staged.lockTag == (try? lockTag(mainPhrase: mainPhrase)) {
            try? store(staged.entries)
        }
        try? KeyStore.delete(service: stagingService)
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

    /// The name on the key ring. The wallet holding the lock is "This Mac"
    /// until renamed; a wallet the lock passed to keeps its own name.
    static func display(_ account: Account, lead: Bool) -> String {
        if let custom = all[KeyRingVault.hex(account.id)] { return custom }
        if lead && account.keySource != WalletEngine.macKeySource { return "This Mac" }
        return account.name ?? (SealItFlow.isSealIt(account) ? "Seal it" : "Wallet")
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
